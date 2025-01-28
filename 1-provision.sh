#!/bin/bash
# Set strict bash error handling:
# -e: Exit immediately if a command exits with non-zero status
# -u: Exit when using undefined variables
# -o pipefail: Return value of a pipeline is the value of the last (rightmost) command to exit with non-zero status
set -euo pipefail

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
PROJECTDIR=$(find ~/ -maxdepth 1 | grep cdt | head -n1)
if [ -z "$PROJECTDIR" ]; then
    echo "Error: No CDT project directory found"
    exit 1
fi
# Extract just the project directory name
PROJECT=$(basename "$PROJECTDIR")

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
incus remote switch gcicompute02
incus project switch ${PROJECT}

# Clean up any existing resources from previous runs
# The '|| true' ensures the script continues even if resources don't exist
echo "Cleaning up existing resources..."
incus stop --force ${DC_NAME} 2>/dev/null || true
incus stop --force ${MEMBER_NAME} 2>/dev/null || true
incus delete ${DC_NAME} 2>/dev/null || true
incus delete ${MEMBER_NAME} 2>/dev/null || true
incus stop --force ${DEPLOY_NAME} 2>/dev/null || true
incus delete ${DEPLOY_NAME} 2>/dev/null || true
incus network delete ${NETWORK_NAME} 2>/dev/null || true


# Create a private network for the Windows VMs
# - Sets up a 192.168.56.0/24 network
# - Enables NAT for IPv4 (allows VMs to access internet)
# - Disables IPv6 for simplicity
echo "Creating network..."
incus network create ${NETWORK_NAME} \
    ipv4.address=192.168.56.1/24 \
    ipv4.nat=true \
    ipv6.address=none \
    ipv6.nat=false 

# Create the Domain Controller VM
# - Uses Windows Server 2019 image pre-configured for Ansible
# - Allocates 8 CPUs and 16GB RAM
# - Assigns static IP 192.168.56.21
# - Provisions 320GB root disk
echo "Creating DC VM..."
incus launch oszoo:winsrv/2019/ansible-cloud \
    ${DC_NAME} \
    --vm \
    --config limits.cpu=8 \
    --config limits.memory=16GiB \
    --network "${NETWORK_NAME}" \
    --device "eth0,ipv4.address=192.168.56.21" \
    --device "root,size=320GiB"

# Create the Member Server VM
# - Uses same Windows Server 2019 image
# - Same resources as DC for consistency
# - Assigns static IP 192.168.56.22
echo "Creating Member VM..."
incus launch oszoo:winsrv/2019/ansible-cloud \
    ${MEMBER_NAME} \
    --vm \
    --config limits.cpu=8 \
    --config limits.memory=16GiB \
    --network "${NETWORK_NAME}" \
    --device "eth0,ipv4.address=192.168.56.22" \
    --device "root,size=320GiB"

# Create Ubuntu container for Ansible deployment
echo "Creating deployment container..."

# Launch Ubuntu Noble (24.04) container
# - Connects to same network as Windows VMs
# - Assigns static IP 192.168.56.10
# - Uses c4-m8 template (4 CPUs, 8GB RAM)
incus launch images:ubuntu/noble ${DEPLOY_NAME} \
    --network "${NETWORK_NAME}" \
    --device "eth0,ipv4.address=192.168.56.10" -t c4-m8

echo "Waiting for deployment container to be ready..."
sleep 10

# Create an Ansible playbook to configure the deployment container
# This playbook will:
# - Wait for container to be ready
# - Add Ansible PPA repository
# - Install Ansible and required dependencies
echo "Creating temporary Ansible playbook for deployment setup..."
cat > deploy_setup.yml << EOF
---
- hosts: deployment
  connection: incus
  gather_facts: true
  tasks:
    - name: Wait for container to be ready
      wait_for_connection:
        timeout: 30

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
# This allows monitoring the boot process
incus console --type=vga ${DC_NAME} &
incus console --type=vga ${MEMBER_NAME} &

# Create Ansible inventory file for configuring deployment container
echo "Creating temporary inventory for deployment..."
cat > deploy_inventory.ini << EOF
[deployment]
${DEPLOY_NAME} ansible_connection=community.general.incus ansible_incus_remote=gcicompute02 ansible_incus_project=${PROJECT}
EOF

# Configure the deployment container using Ansible
# - Sets non-interactive frontend to avoid prompts
# - Disables host key checking for first connection
# - Cleans up on failure
echo "Configuring deployment container..."
export DEBIAN_FRONTEND=noninteractive
if ! ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -v -i deploy_inventory.ini deploy_setup.yml; then
    echo "Failed to configure deployment container"
    rm -f deploy_setup.yml deploy_inventory.ini
    incus stop --force ${DEPLOY_NAME}
    incus delete ${DEPLOY_NAME}
    exit 1
fi

# Create Ansible inventory for Windows VMs
# - Defines Windows group with both VMs
# - Sets WinRM connection parameters
# - Uses default ansible/ansible credentials
echo "Creating temporary inventory..."
cat > inventory.tmp << EOF
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

# Wait for Windows VMs to become available
# - Tries every 20 seconds for up to 30 minutes (90 attempts)
# - Uses Ansible win_ping module to verify connectivity
echo "Waiting for Windows VMs to be ready..."
max_attempts=90
attempt=1

while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt of $max_attempts..."
    
    # Copy inventory to deployment container and run health check
    incus file push inventory.tmp ${DEPLOY_NAME}/root/inventory
    if incus exec ${DEPLOY_NAME} -- ansible -v windows -i /root/inventory -m win_ping 2>/dev/null; then
        echo "All Windows VMs are ready!"
        break
    fi
    
    sleep 20
    attempt=$((attempt + 1))
done

if [ $attempt -gt $max_attempts ]; then
    echo "Timeout waiting for Windows VMs to be ready"
    exit 1
fi

# Clean up temporary files
rm -f inventory.tmp deploy_setup.yml deploy_inventory.ini

# Open VGA consoles for both Windows VMs in background
# This allows monitoring the boot process
incus console --type=vga ${DC_NAME} &
incus console --type=vga ${MEMBER_NAME} &

# Display final setup information
echo "Setup complete! Default credentials: ansible/ansible"
echo "DC VM: ${DC_NAME} (192.168.56.21)"
echo "Member VM: ${MEMBER_NAME} (192.168.56.22)"
echo "Deployment container: ${DEPLOY_NAME}"
