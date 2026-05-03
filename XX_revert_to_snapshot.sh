#!/bin/bash
# XX_revert_to_snapshot.sh

VM_NAME="BaseDevStack"

# 1. Force stop the VM
sudo virsh destroy $VM_NAME

# 2. Revert to your "PostStack_Ready" snapshot
sudo virsh snapshot-revert --domain $VM_NAME --snapshotname "PostStack_Ready"

# 3. Start it back up
sudo virsh start $VM_NAME