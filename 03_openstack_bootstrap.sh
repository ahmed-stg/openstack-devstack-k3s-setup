#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env VM_IP

log_section "03_openstack_bootstrap.sh"
log "Bootstrapping OpenStack environment for K3s."

wait_for_ssh "$VM_IP" "$VM_SSH_KEY"

# Ensure the Ubuntu image is available in DevStack
if [[ -f "$IMAGE_PATH" ]]; then
    log "Checking if image '$IMAGE_NAME' already exists in OpenStack."
    if ! vm_openstack admin "openstack image show '$IMAGE_NAME' >/dev/null 2>&1"; then
        log "Uploading $IMAGE_NAME to DevStack VM..."
        scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$IMAGE_PATH" "${SSH_USER}@${VM_IP}:/home/${SSH_USER}/ubuntu-noble.img"
        vm_openstack admin "openstack image create '$IMAGE_NAME' --file ~/ubuntu-noble.img --disk-format qcow2 --container-format bare --public"
        vm_ssh "rm -f ~/ubuntu-noble.img"
    else
        log "Image '$IMAGE_NAME' already exists."
    fi
fi

# Core OpenStack Setup (Idempotent)
log "Running core OpenStack setup (Project, User, Network)..."
vm_openstack admin <<EOF
set -euo pipefail

# 1. Project and User
openstack project show "$PROJECT_NAME" >/dev/null 2>&1 || \
    openstack project create --description "$PROJECT_DESC" "$PROJECT_NAME"

openstack user show "$PROJECT_USER" >/dev/null 2>&1 || \
    openstack user create --project "$PROJECT_NAME" --password "$PROJECT_PASSWORD" "$PROJECT_USER"

openstack role add --project "$PROJECT_NAME" --user "$PROJECT_USER" "$PROJECT_ROLE" >/dev/null 2>&1 || true

# 2. Quotas
openstack quota set --ram 32768 --cores 20 --instances 20 --floating-ips 20 "$PROJECT_NAME"

# 3. Networking
PUBLIC_NET_NAME=\$(openstack network list --external -f value -c Name | head -n1)

openstack router show "$K3S_ROUTER_NAME" >/dev/null 2>&1 || openstack router create "$K3S_ROUTER_NAME"
openstack router set --external-gateway "\$PUBLIC_NET_NAME" "$K3S_ROUTER_NAME"

# Cluster Network
openstack network show "$K3S_CLUSTER_NET_NAME" >/dev/null 2>&1 || \
    openstack network create --project "$PROJECT_NAME" "$K3S_CLUSTER_NET_NAME"

openstack subnet show "$K3S_CLUSTER_SUBNET_NAME" >/dev/null 2>&1 || \
    openstack subnet create \
      --project "$PROJECT_NAME" \
      --network "$K3S_CLUSTER_NET_NAME" \
      --subnet-range "$K3S_CLUSTER_CIDR" \
      --gateway "$K3S_CLUSTER_GW" \
      --dns-nameserver 1.1.1.1 \
      "$K3S_CLUSTER_SUBNET_NAME"

# Services Network
openstack network show "$K3S_SERVICES_NET_NAME" >/dev/null 2>&1 || \
    openstack network create --project "$PROJECT_NAME" "$K3S_SERVICES_NET_NAME"

openstack subnet show "$K3S_SERVICES_SUBNET_NAME" >/dev/null 2>&1 || \
    openstack subnet create \
      --project "$PROJECT_NAME" \
      --network "$K3S_SERVICES_NET_NAME" \
      --subnet-range "$K3S_SERVICES_CIDR" \
      --gateway "$K3S_SERVICES_GW" \
      --dns-nameserver 1.1.1.1 \
      "$K3S_SERVICES_SUBNET_NAME"

openstack router add subnet "$K3S_ROUTER_NAME" "$K3S_CLUSTER_SUBNET_NAME" >/dev/null 2>&1 || true
openstack router add subnet "$K3S_ROUTER_NAME" "$K3S_SERVICES_SUBNET_NAME" >/dev/null 2>&1 || true
EOF

# Generate User OpenRC
log "Generating User OpenRC locally and on VM."
cat > "$ROOT_DIR/k3s-user-openrc.sh" <<ORC
export OS_AUTH_URL=http://$VM_IP/identity/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=$PROJECT_NAME
export OS_USERNAME=$PROJECT_USER
export OS_PASSWORD=$PROJECT_PASSWORD
ORC
chmod 600 "$ROOT_DIR/k3s-user-openrc.sh"
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$ROOT_DIR/k3s-user-openrc.sh" "${SSH_USER}@${VM_IP}:~/k3s-user-openrc.sh"

# Create a "System" Application Credential for the Auth Proxy (Idempotent)
log "Ensuring System Application Credential for Auth Proxy."
APP_CRED_EXISTS=$(vm_openstack tenant <<EOF
openstack application credential show auth-proxy-system >/dev/null 2>&1 && echo yes || echo no
EOF
)

if [[ "$APP_CRED_EXISTS" == "yes" ]]; then
    log "Application credential 'auth-proxy-system' already exists."
    # If we don't have the secret locally, we must recreate it.
    if ! grep -q "AUTH_PROXY_APP_CRED_SECRET" "$DEVSTACK_ENV_FILE" 2>/dev/null; then
        log "Secret not found in devstack_env, recreating..."
        vm_openstack tenant "openstack application credential delete auth-proxy-system"
        APP_CRED_EXISTS="no"
    fi
fi

if [[ "$APP_CRED_EXISTS" == "no" ]]; then
    log "Creating new Application Credential 'auth-proxy-system'."
    APP_CRED_JSON=$(vm_openstack tenant <<EOF
openstack application credential create auth-proxy-system --description "Used by Auth Proxy" -f json
EOF
)
    # Extract ID and Secret (OpenStack CLI often returns Capitalized keys in JSON)
    AUTH_PROXY_APP_CRED_ID=$(echo "$APP_CRED_JSON" | grep -oP '"ID": "\K[^"]+' | head -n1 || true)
    AUTH_PROXY_APP_CRED_SECRET=$(echo "$APP_CRED_JSON" | grep -oP '"Secret": "\K[^"]+' | head -n1 || true)
    
    if [[ -z "$AUTH_PROXY_APP_CRED_ID" || -z "$AUTH_PROXY_APP_CRED_SECRET" ]]; then
        # Try lowercase just in case
        AUTH_PROXY_APP_CRED_ID=$(echo "$APP_CRED_JSON" | grep -oP '"id": "\K[^"]+' | head -n1 || true)
        AUTH_PROXY_APP_CRED_SECRET=$(echo "$APP_CRED_JSON" | grep -oP '"secret": "\K[^"]+' | head -n1 || true)
    fi

    [[ -n "$AUTH_PROXY_APP_CRED_ID" ]] || fail "Failed to extract Application Credential ID"
    [[ -n "$AUTH_PROXY_APP_CRED_SECRET" ]] || fail "Failed to extract Application Credential Secret"

    persist_env AUTH_PROXY_APP_CRED_ID "$AUTH_PROXY_APP_CRED_ID"
    persist_env AUTH_PROXY_APP_CRED_SECRET "$AUTH_PROXY_APP_CRED_SECRET"
fi

persist_env PROJECT_NAME "$PROJECT_NAME"
persist_env IMAGE_NAME "$IMAGE_NAME"

log "OpenStack Bootstrap Complete."
