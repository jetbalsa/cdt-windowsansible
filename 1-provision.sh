#!/bin/bash
# Set strict bash error handling:
# -e: Exit immediately if a command exits with non-zero status
# -u: Exit when using undefined variables
# -o pipefail: Return value of a pipeline is the value of the last (rightmost) command to exit with non-zero status
set -euo pipefail

# Color output functions
print_command() {
    echo "$(tput setaf 6)>>> $1$(tput sgr0)"
    eval "$1"
}

print_message() {
    echo "$(tput setaf 2)$1$(tput sgr0)"
}

# SCRIPT OVERVIEW:
# This script sets up a Windows Server environment using Incus (Linux container hypervisor)
# It creates:
# 1. A private network for the VMs
# 2. A Windows Server 2019 Domain Controller (DC)
# 3. A Windows Server 2019 Member server
# 4. An Ubuntu container for Ansible deployment

# Set deployment container name using current username
DEPLOY_NAME="${USER}-deploy"

# Get current username, fallback to whoami if USER env var is not set
USER=${USER:-$(whoami)}

# Find the CDT project directory
# Searches in home directory for a directory containing 'cdt'
print_command "PROJECTDIR=\$(find ~/ -maxdepth 1 | grep cdt | head -n1)"
if [ -z "$PROJECTDIR" ]; then
    print_message "Error: No CDT project directory found"
    exit 1
fi
# Extract just the project directory name
print_command "PROJECT=\$(basename \"\$PROJECTDIR\")"

# Configure Ansible environment variables for Incus connection
# These tell Ansible which Incus remote and project to use
export ANSIBLE_INCUS_REMOTE=gcicompute02
export ANSIBLE_INCUS_PROJECT="$PROJECT"

# Define resource names with user-specific prefixes to avoid conflicts
NETWORK_NAME="${USER}-windows-net"     # Private network for VMs
DC_NAME="${USER}-dc01"                 # Domain Controller VM name
MEMBER_NAME="${USER}-member01"         # Member Server VM name

# Switch to the specified Incus remote and project
# This ensures we're working in the correct environment
print_command "incus remote switch gcicompute02"
print_command "incus project switch ${PROJECT}"

# Clean up any existing resources from previous runs
print_message "Cleaning up existing resources..."
print_command "incus stop --force ${DC_NAME} 2>/dev/null || true"
print_command "incus stop --force ${MEMBER_NAME} 2>/dev/null || true"
print_command "incus delete ${DC_NAME} 2>/dev/null || true"
print_command "incus delete ${MEMBER_NAME} 2>/dev/null || true"
print_command "incus stop --force ${DEPLOY_NAME} 2>/dev/null || true"
print_command "incus delete ${DEPLOY_NAME} 2>/dev/null || true"
print_command "incus network delete ${NETWORK_NAME} 2>/dev/null || true"

# Create a private network for the Windows VMs
print_message "Creating network..."
print_command "incus network create ${NETWORK_NAME} \\
    ipv4.address=192.168.56.1/24 \\
    ipv4.nat=true \\
    ipv6.address=none \\
    ipv6.nat=false"

# Create the Domain Controller VM
print_message "Creating DC VM..."
print_command "incus launch oszoo:winsrv/2019/ansible-cloud \\
    ${DC_NAME} \\
    --vm \\
    --config limits.cpu=8 \\
    --config limits.memory=16GiB \\
    --network \"${NETWORK_NAME}\" \\
    --device \"eth0,ipv4.address=192.168.56.21\" \\
    --device \"root,size=320GiB\""

# Create the Member Server VM
print_message "Creating Member VM..."
print_command "incus launch oszoo:winsrv/2019/ansible-cloud \\
    ${MEMBER_NAME} \\
    --vm \\
    --config limits.cpu=8 \\
    --config limits.memory=16GiB \\
    --network \"${NETWORK_NAME}\" \\
    --device \"eth0,ipv4.address=192.168.56.22\" \\
    --device \"root,size=320GiB\""

# Create Ubuntu container for Ansible deployment
print_message "Creating deployment container..."

# Launch Ubuntu Noble (24.04) container
print_command "incus launch images:ubuntu/noble ${DEPLOY_NAME} \\
    --network \"${NETWORK_NAME}\" \\
    --device \"eth0,ipv4.address=192.168.56.10\" -t c4-m8"

print_message "Waiting for deployment container to be ready..."
print_command "sleep 10"

# Create an Ansible playbook to configure the deployment container
print_message "Creating temporary Ansible playbook for deployment setup..."
cat > deploy_setup.yml << 'EOF'
---
- hosts: deployment
  connection: incus
  gather_facts: true
  tasks:
    - name: Wait for container to be ready
      wait_for_connection:
        timeout: 30

    - name: Add inventory hostnames to /etc/hosts
      lineinfile:
        path: /etc/hosts
        line: "{{ item }}"
        state: present
      loop:
        - "192.168.56.21 dc01.example.local"
        - "192.168.56.22 client01.example.local"

    - name: Add Ansible PPA
      shell: |
        apt-get update
        apt-get install -y software-properties-common
        add-apt-repository --yes --update ppa:ansible/ansible

    - name: Install Ansible and dependencies
      apt:
        name: 
          - ansible
          - python3-pip
          - python3-requests
          - nano
        state: present
        update_cache: yes
EOF


# Open VGA consoles for both Windows VMs in background
print_command "incus console --type=vga ${DC_NAME} &"
print_command "incus console --type=vga ${MEMBER_NAME} &"

# Create Ansible inventory file for configuring deployment container
print_message "Creating temporary inventory for deployment..."
print_command "cat > deploy_inventory.ini << 'EOF'
[deployment]
${DEPLOY_NAME} ansible_connection=community.general.incus ansible_incus_remote=gcicompute02 ansible_incus_project=${PROJECT}
EOF
"

# Configure the deployment container using Ansible
print_message "Configuring deployment container..."
export DEBIAN_FRONTEND=noninteractive
if ! ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -v -i deploy_inventory.ini deploy_setup.yml; then
    print_message "Failed to configure deployment container"
    print_command "rm -f deploy_setup.yml deploy_inventory.ini"
    print_command "incus stop --force ${DEPLOY_NAME}"
    print_command "incus delete ${DEPLOY_NAME}"
    exit 1
fi

# Create Ansible inventory for Windows VMs
print_message "Creating temporary inventory..."
print_command "cat > inventory.tmp << 'EOF'
[windows]
dc ansible_host=192.168.56.21
member ansible_host=192.168.56.22

[windows:vars]
ansible_user=ansible
ansible_password=ansible
ansible_connection=winrm
ansible_winrm_server_cert_validation=ignore
ansible_winrm_transport=ntlm
EOF
"

# Create Ansible playbook for checking Windows availability
print_message "Creating Windows availability check playbook..."
cat > windows_check.yml << 'EOF'
---
- hosts: windows
  gather_facts: false
  tasks:
    - name: Wait for Windows hosts to become available
      win_ping:
      register: ping_result
      until: ping_result is success
      retries: 90
      delay: 20
      ignore_unreachable: yes
      ignore_errors: yes

    - name: Check final connection status
      win_ping:
      register: final_check

EOF

# Wait for Windows VMs to become available
print_message "Waiting for Windows VMs to be ready..."

# Copy inventory and check playbook to deployment container
print_command "incus file push inventory.tmp ${DEPLOY_NAME}/root/inventory"
print_command "incus file push windows_check.yml ${DEPLOY_NAME}/root/windows_check.yml"

# Run the availability check with increased verbosity
if print_command "incus exec ${DEPLOY_NAME} -- ansible-playbook -vv -i /root/inventory /root/windows_check.yml"; then
    print_message "All Windows VMs are ready!"
else
    print_message "Timeout waiting for Windows VMs to be ready"
    exit 1
fi

# Clean up temporary files
print_command "rm -f inventory.tmp deploy_setup.yml deploy_inventory.ini windows_check.yml"

# Copy CDT Ansible playbook to deployment container
print_command "incus file push -r ../cdt-windowsansible ${DEPLOY_NAME}/root/"

# Open VGA consoles for both Windows VMs in background
print_command "incus console --type=vga ${DC_NAME} 2> /dev/null &"
print_command "incus console --type=vga ${MEMBER_NAME} 2> /dev/null &"

# Display final setup information
print_message "Setup complete! Default credentials: ansible/ansible"
print_message "DC VM: ${DC_NAME} (192.168.56.21)"
print_message "Member VM: ${MEMBER_NAME} (192.168.56.22)"
print_message "Deployment container: ${DEPLOY_NAME}"
print_message "============================================================"
print_message "To access the deployment container, run: incus shell ${DEPLOY_NAME}"
print_message "To start deployment of the ansible playboot, run: "
print_message "incus exec ${DEPLOY_NAME} -- ansible-playbook -i /root/cdt-windowsansible/inventory/hosts /root/cdt-windowsansible/site.yml"
