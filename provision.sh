#!/bin/bash
set -x
# Exit on error, undefined variables, and pipe failures
set -euo pipefail
DEPLOY_NAME="${USER}-deploy"
# Get current user for prefixing
USER=${USER:-$(whoami)}
PROJECTDIR=$(find ~/ -maxdepth 1 | grep cdt | head -n1)
if [ -z "$PROJECTDIR" ]; then
    echo "Error: No CDT project directory found"
    exit 1
fi
PROJECT=$(basename "$PROJECTDIR")

# Set Ansible environment variables for incus connection
export ANSIBLE_INCUS_REMOTE=gcicompute02
export ANSIBLE_INCUS_PROJECT="$PROJECT"
NETWORK_NAME="${USER}-windows-net"
DC_NAME="${USER}-dc01"
MEMBER_NAME="${USER}-member01"

# Set incus remote and project
incus remote switch gcicompute02
incus project switch ${PROJECT}

echo "Cleaning up existing resources..."
incus stop --force ${DC_NAME} 2>/dev/null || true
incus stop --force ${MEMBER_NAME} 2>/dev/null || true
incus delete ${DC_NAME} 2>/dev/null || true
incus delete ${MEMBER_NAME} 2>/dev/null || true
incus network delete ${NETWORK_NAME} 2>/dev/null || true

echo "Creating network..."
incus network create ${NETWORK_NAME} \
    ipv4.address=192.168.56.1/24 \
    ipv4.nat=true \
    ipv6.address=none \
    ipv6.nat=false 

echo "Creating DC VM..."
incus launch oszoo:winsrv/2019/ansible-cloud \
    ${DC_NAME} \
    --vm \
    --config limits.cpu=8 \
    --config limits.memory=16GiB \
    --network "${NETWORK_NAME}" \
    --device "eth0,ipv4.address=192.168.56.21" \
    --device "root,size=320GiB"

echo "Creating Member VM..."
incus launch oszoo:winsrv/2019/ansible-cloud \
    ${MEMBER_NAME} \
    --vm \
    --config limits.cpu=8 \
    --config limits.memory=16GiB \
    --network "${NETWORK_NAME}" \
    --device "eth0,ipv4.address=192.168.56.22" \
    --device "root,size=320GiB"

echo "Creating deployment container..."
incus stop --force ${DEPLOY_NAME} 2>/dev/null || true
incus delete ${DEPLOY_NAME} 2>/dev/null || true

incus launch images:ubuntu/noble ${DEPLOY_NAME} \
    --network "${NETWORK_NAME}" \
    --device "eth0,ipv4.address=192.168.56.10" -t c4-m8

echo "Waiting for deployment container to be ready..."
sleep 10

echo "Creating temporary Ansible playbook for deployment setup..."
cat > deploy_setup.yml << EOF
---
- hosts: deployment
  connection: incus
  gather_facts: false
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
        state: present
        update_cache: yes

    - name: Install pywinrm
      pip:
        name: pywinrm
        state: present
EOF
incus console --type=vga ${DC_NAME} &
incus console --type=vga ${MEMBER_NAME} &
echo "Creating temporary inventory for deployment..."
cat > deploy_inventory.ini << EOF
[deployment]
${DEPLOY_NAME} ansible_connection=community.general.incus ansible_incus_remote=gcicompute02 ansible_incus_project=${PROJECT}
EOF

echo "Configuring deployment container..."
export DEBIAN_FRONTEND=noninteractive
if ! ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i deploy_inventory.ini deploy_setup.yml; then
    echo "Failed to configure deployment container"
    rm -f deploy_setup.yml deploy_inventory.ini
    incus stop --force ${DEPLOY_NAME}
    incus delete ${DEPLOY_NAME}
    exit 1
fi

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

echo "Waiting for Windows VMs to be ready..."
max_attempts=90
attempt=1

while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt of $max_attempts..."
    
    # Copy inventory to deployment container and run health check
    incus file push inventory.tmp ${DEPLOY_NAME}/root/inventory
    if incus exec ${DEPLOY_NAME} -- ansible windows -i /root/inventory -m win_ping 2>/dev/null; then
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

# Cleanup
rm -f inventory.tmp deploy_setup.yml deploy_inventory.ini
incus stop --force ${DEPLOY_NAME}
incus delete ${DEPLOY_NAME}

echo "Setup complete! Default credentials: ansible/ansible"
echo "DC VM: ${DC_NAME} (192.168.56.21)"
echo "Member VM: ${MEMBER_NAME} (192.168.56.22)"
