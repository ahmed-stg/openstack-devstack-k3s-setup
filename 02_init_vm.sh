#!/bin/bash
# 02_init_vm.sh

# Load the IP from the first script
if [ -f "./devstack_env" ]; then
    source ./devstack_env
fi

if [ -z "$VM_IP" ]; then
    echo "Error: VM_IP not found. Run script 01 first or export VM_IP."
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
LOCAL_CONF_PATH="./local.conf"

if [ ! -f "$LOCAL_CONF_PATH" ]; then
    echo "Error: $LOCAL_CONF_PATH not found in current directory!"
    exit 1
fi

echo "Initializing VM at $VM_IP..."

# 1. Fix DNS, Disable Resolver, Prep Interfaces, and Clone DevStack
ssh $SSH_OPTS ubuntu@$VM_IP << 'EOF'
    echo "--- Permanent DNS Fix ---"
    sudo systemctl disable --now systemd-resolved
    sudo rm -f /etc/resolv.conf
    echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
    
    echo "--- Preparing Network Interfaces ---"
    # Ensure second interface is UP but has no IP
    sudo ip link set enp2s0 up
    sudo ip addr flush dev enp2s0
    
    echo "--- Installing Prereqs ---"
    sudo apt update && sudo apt install -y git
    
    if [ ! -d "~/devstack" ]; then
        git clone https://opendev.org/openstack/devstack ~/devstack
    fi
EOF

# 2. Transfer the local.conf you have in your host folder
echo "--- Transferring local.conf ---"
scp $SSH_OPTS "$LOCAL_CONF_PATH" ubuntu@$VM_IP:/home/ubuntu/devstack/local.conf

# 3. Final Verification
ssh $SSH_OPTS ubuntu@$VM_IP << 'EOF'
    echo "--- Final Pre-Stack Checks ---"
    # Ensure the HOST_IP in local.conf matches our current management IP
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    sed -i "s/^HOST_IP=.*/HOST_IP=$CURRENT_IP/" ~/devstack/local.conf
    
    echo "System ready for DevStack."
EOF

echo "------------------------------------------------"
echo "VM is ready! Run these commands to finish:"
echo "1. ssh ubuntu@$VM_IP"
echo "2. cd ~/devstack"
echo "3. ./stack.sh"
echo "------------------------------------------------"