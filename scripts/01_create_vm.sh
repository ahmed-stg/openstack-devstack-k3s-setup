#!/bin/bash
# 01_create_vm.sh
# Run from anywhere: paths below are relative to the repo root.
cd "$(dirname "$0")/.." || exit 1

# --- CONFIGURATION ---
SSH_KEY_PUB="$HOME/.ssh/id_ed25519.pub"
VM_NAME="BaseDevStack"
VM_RAM=16284
VM_VCPUS=6
DISK_SIZE="80G"
BASE_IMAGE="${BASE_IMAGE:-images/noble-server-cloudimg-amd64.img}"
POOL_PATH="/var/lib/libvirt/images"
VM_DISK="$POOL_PATH/$VM_NAME.qcow2"
CLOUD_INIT_ISO="$POOL_PATH/$VM_NAME-cidata.iso"

# --- PRE-FLIGHT CHECKS ---
if sudo virsh list --all | grep -q "$VM_NAME"; then
    echo "Resetting existing VM..."
    sudo virsh destroy "$VM_NAME" 2>/dev/null
    sudo virsh undefine "$VM_NAME" --remove-all-storage
fi

# --- PREPARE DISK ---
sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$VM_DISK" "$DISK_SIZE"

# --- CLOUD-INIT GENERATION ---
cat <<EOF > user-data
#cloud-config
ssh_authorized_keys:
  - $(cat "$SSH_KEY_PUB")
password: nomoresecret
chpasswd: { expire: False }
ssh_pwauth: True
package_update: true
packages:
  - qemu-guest-agent
  - bridge-utils
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

touch meta-data
genisoimage -output "cidata.iso" -volid cidata -joliet -rock user-data meta-data
sudo mv "cidata.iso" "$CLOUD_INIT_ISO"
rm user-data meta-data

# --- DEPLOYMENT ---
# Note: Adding TWO network interfaces
sudo virt-install \
    --name "$VM_NAME" \
    --memory "$VM_RAM" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --os-variant ubuntu24.04 \
    --disk path="$VM_DISK",format=qcow2 \
    --disk path="$CLOUD_INIT_ISO",device=cdrom \
    --import \
    --network network=default,model=virtio \
    --network network=default,model=virtio \
    --graphics none \
    --noautoconsole

# --- IP POLLING ---
echo "Waiting for IP..."
MAX_RETRIES=30
for ((i=1; i<=MAX_RETRIES; i++)); do
    IP_ADDR=$(sudo virsh domifaddr "$VM_NAME" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
    if [ ! -z "$IP_ADDR" ]; then
        echo "export VM_IP=$IP_ADDR" > ./devstack_env
        echo "SUCCESS: VM is up at $IP_ADDR"
        exit 0
    fi
    sleep 5
done