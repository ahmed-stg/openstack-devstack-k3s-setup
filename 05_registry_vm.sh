#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env VM_IP K3S_SERVICES_NET_NAME K3S_CLUSTER_CIDR K3S_SERVICES_CIDR PUBLIC_NET_NAME HOST_ACCESS_CIDR

REGISTRY_SG="${REGISTRY_SG:-registry-sg}"

log_section "05_registry_vm.sh"
log "Creating Registry VM and Cinder Volume (also hosts Auth Proxy)."

vm_openstack tenant <<EOF
set -euo pipefail

# 1. Security Group
openstack security group show "$REGISTRY_SG" >/dev/null 2>&1 || openstack security group create "$REGISTRY_SG"
openstack security group rule create --remote-ip "$K3S_CLUSTER_CIDR" --protocol tcp --dst-port 22 "$REGISTRY_SG" >/dev/null 2>&1 || true
openstack security group rule create --remote-ip "$K3S_CLUSTER_CIDR" --protocol tcp --dst-port 5000 "$REGISTRY_SG" >/dev/null 2>&1 || true
openstack security group rule create --remote-ip "$K3S_SERVICES_CIDR" --protocol tcp --dst-port 22 "$REGISTRY_SG" >/dev/null 2>&1 || true
openstack security group rule create --remote-ip "$K3S_SERVICES_CIDR" --protocol tcp --dst-port 5000 "$REGISTRY_SG" >/dev/null 2>&1 || true
# Auth Proxy merged into this VM — allow external access
openstack security group rule create --remote-ip "$HOST_ACCESS_CIDR" --protocol tcp --dst-port 22 "$REGISTRY_SG" >/dev/null 2>&1 || true
openstack security group rule create --remote-ip 0.0.0.0/0 --protocol tcp --dst-port 5000 "$REGISTRY_SG" >/dev/null 2>&1 || true

# 2. Volume
openstack volume show "$REGISTRY_VOLUME_NAME" >/dev/null 2>&1 || \
    openstack volume create --size "$REGISTRY_VOLUME_SIZE" "$REGISTRY_VOLUME_NAME"

# 3. Server
openstack server show "$REGISTRY_NAME" >/dev/null 2>&1 || \
    openstack server create \
      --flavor "$REGISTRY_FLAVOR" \
      --image "$IMAGE_NAME" \
      --network "$K3S_SERVICES_NET_NAME" \
      --security-group "$REGISTRY_SG" \
      --key-name "$KEYPAIR_NAME" \
      "$REGISTRY_NAME"
EOF

wait_for_server_status "$REGISTRY_NAME" ACTIVE

# Attach Volume
# `-c attachments` only carries server UUIDs, so grepping the VM name never
# matched and a re-run tried to attach an in-use volume again (400).
if [[ "$(vm_openstack tenant "openstack volume show $REGISTRY_VOLUME_NAME -f value -c status" | tr -d '\r')" != "in-use" ]]; then
    log "Attaching volume to $REGISTRY_NAME."
    vm_openstack tenant "openstack server add volume $REGISTRY_NAME $REGISTRY_VOLUME_NAME"
fi

REGISTRY_INTERNAL_IP="$(wait_for_fixed_ip_for_net "$REGISTRY_NAME" "$K3S_SERVICES_NET_NAME")"

# Floating IP Assignment (needed for Auth Proxy external access)
REGISTRY_FIP=$(vm_openstack tenant "openstack server show $REGISTRY_NAME -f value -c addresses" | grep -oE '192\.168\.122\.[0-9]+' | head -n1 || true)
if [[ -z "$REGISTRY_FIP" ]]; then
    log "Allocating new Floating IP for $REGISTRY_NAME."
    REGISTRY_FIP=$(vm_openstack tenant "openstack floating ip create $PUBLIC_NET_NAME -f value -c floating_ip_address")
    vm_openstack tenant "openstack server add floating ip $REGISTRY_NAME $REGISTRY_FIP"
fi

wait_for_ssh "$REGISTRY_FIP" "$VM_SSH_KEY"

# Get the ACTUAL IP the VM has (not what OpenStack reports — DHCP may differ)
ACTUAL_IP=$(ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${REGISTRY_FIP}" \
    "ip -4 -o addr show scope global | awk '\$2 != \"lo\" {print \$4; exit}' | cut -d/ -f1" 2>/dev/null || true)
if [[ -n "$ACTUAL_IP" ]]; then
    log "Registry actual IP: $ACTUAL_IP (OpenStack reported: $REGISTRY_INTERNAL_IP)"
    REGISTRY_INTERNAL_IP="$ACTUAL_IP"
fi

persist_env REGISTRY_NAME "$REGISTRY_NAME"
persist_env REGISTRY_INTERNAL_IP "$REGISTRY_INTERNAL_IP"
persist_env REGISTRY_FIP "$REGISTRY_FIP"

log "Registry VM is ready at $REGISTRY_FIP (Internal: $REGISTRY_INTERNAL_IP)."
