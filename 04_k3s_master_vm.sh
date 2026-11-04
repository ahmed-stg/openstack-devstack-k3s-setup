#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env VM_IP K3S_CLUSTER_NET_NAME PUBLIC_NET_NAME
require_file "$SSH_PUB_KEY"

MASTER_SG="${MASTER_SG:-k3s-master-sg}"

log_section "04_k3s_master_vm.sh"
log "Creating K3s Master VM (Access Anchor)."

scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$SSH_PUB_KEY" "${SSH_USER}@${VM_IP}:/home/${SSH_USER}/host_instance_key.pub"

vm_openstack tenant <<EOF
set -euo pipefail

# 1. Keypair
openstack keypair show "$KEYPAIR_NAME" >/dev/null 2>&1 || \
    openstack keypair create --public-key ~/host_instance_key.pub "$KEYPAIR_NAME"

# 2. Security Group
openstack security group show "$MASTER_SG" >/dev/null 2>&1 || openstack security group create "$MASTER_SG"

# Rules
openstack security group rule create --remote-ip "$HOST_ACCESS_CIDR" --protocol tcp --dst-port 22 "$MASTER_SG" >/dev/null 2>&1 || true
openstack security group rule create --remote-ip "$HOST_ACCESS_CIDR" --protocol tcp --dst-port 6443 "$MASTER_SG" >/dev/null 2>&1 || true
openstack security group rule create --remote-ip "$K3S_CLUSTER_CIDR" --protocol tcp "$MASTER_SG" >/dev/null 2>&1 || true
openstack security group rule create --remote-ip "$K3S_CLUSTER_CIDR" --protocol udp "$MASTER_SG" >/dev/null 2>&1 || true
openstack security group rule create --remote-ip "$K3S_CLUSTER_CIDR" --protocol icmp "$MASTER_SG" >/dev/null 2>&1 || true

# 3. Server
openstack server show "$MASTER_NAME" >/dev/null 2>&1 || \
    openstack server create \
      --flavor "$MASTER_FLAVOR" \
      --image "$IMAGE_NAME" \
      --network "$K3S_CLUSTER_NET_NAME" \
      --security-group "$MASTER_SG" \
      --key-name "$KEYPAIR_NAME" \
      "$MASTER_NAME"
EOF

log "Waiting for $MASTER_NAME to be ACTIVE."
wait_for_server_status "$MASTER_NAME" ACTIVE

# Floating IP Assignment
MASTER_FIP=$(vm_openstack tenant "openstack server show $MASTER_NAME -f value -c addresses" | grep -oE '192\.168\.122\.[0-9]+' | head -n1 || true)
if [[ -z "$MASTER_FIP" ]]; then
    log "Allocating new Floating IP for $MASTER_NAME."
    MASTER_FIP=$(vm_openstack tenant "openstack floating ip create $PUBLIC_NET_NAME -f value -c floating_ip_address")
    vm_openstack tenant "openstack server add floating ip $MASTER_NAME $MASTER_FIP"
fi

MASTER_INTERNAL_IP=$(wait_for_fixed_ip_for_net "$MASTER_NAME" "$K3S_CLUSTER_NET_NAME")

# Ensure host-to-FIP routing (MUST happen before wait_for_ssh — FIP is unreachable without it)
log "Ensuring host route to floating range via DevStack VM."
if ! sudo -n ip route replace "$FLOATING_RANGE" via "$VM_IP" 2>/dev/null; then
    if [[ -t 0 ]]; then
        sudo ip route replace "$FLOATING_RANGE" via "$VM_IP"
    else
        fail "cannot add host route $FLOATING_RANGE via $VM_IP without root. Allow 'ip' for passwordless sudo — note sudo resolves it through secure_path, usually /usr/sbin/ip, not only /usr/bin/ip."
    fi
fi

log "Ensuring DevStack VM forwards floating range through br-ex."
# Copy configuration script
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$SCRIPT_DIR/configure_br_ex.sh" "${SSH_USER}@${VM_IP}:~/configure_br_ex.sh"

# Execute inside the VM as admin
vm_ssh "bash -lc 'source /home/ubuntu/devstack/openrc admin admin && bash ~/configure_br_ex.sh'"

# Now the FIP is reachable — wait for SSH and detect actual IP
wait_for_ssh "$MASTER_FIP" "$VM_SSH_KEY"
ACTUAL_IP=$(ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" \
    "ip -4 -o addr show scope global | awk '\$2 != \"lo\" {print \$4; exit}' | cut -d/ -f1" 2>/dev/null || true)
if [[ -n "$ACTUAL_IP" ]]; then
    log "Master actual IP: $ACTUAL_IP (OpenStack reported: $MASTER_INTERNAL_IP)"
    MASTER_INTERNAL_IP="$ACTUAL_IP"
fi

persist_env MASTER_NAME "$MASTER_NAME"
persist_env MASTER_FIP "$MASTER_FIP"
persist_env MASTER_INTERNAL_IP "$MASTER_INTERNAL_IP"
persist_env MASTER_SG "$MASTER_SG"
persist_env KEYPAIR_NAME "$KEYPAIR_NAME"


log "K3s Master VM is ready at $MASTER_FIP (Internal: $MASTER_INTERNAL_IP)."
