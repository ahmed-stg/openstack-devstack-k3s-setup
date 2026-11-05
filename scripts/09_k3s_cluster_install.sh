#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
load_env
require_env VM_IP MASTER_FIP MASTER_INTERNAL_IP REGISTRY_INTERNAL_IP K3S_BINARY_PATH
require_env AUTH_PROXY_APP_CRED_ID AUTH_PROXY_APP_CRED_SECRET

log_section "09_k3s_cluster_install.sh"

# Registry Config for K3s
tmp_registries_yaml="$(mktemp)"
cat > "$tmp_registries_yaml" <<EOF
mirrors:
  # The registry host itself needs an explicit http endpoint. Without this entry
  # k3s generates certs.d/<ip>:5000/hosts.toml with an https-only "server" line,
  # because the "*" wildcard is not used for a directly-referenced host. Adding
  # the mirror makes k3s emit an http fallback, which is what the plain-HTTP
  # Nginx listens on. (Found the hard way: ImagePullBackOff, "server gave HTTP
  # response to HTTPS client".)
  "$REGISTRY_INTERNAL_IP:5000":
    endpoint:
      - "http://$REGISTRY_INTERNAL_IP:5000"
  docker.io:
    endpoint:
      - "http://$REGISTRY_INTERNAL_IP:5000"
  "registry.k8s.io":
    endpoint:
      - "http://$REGISTRY_INTERNAL_IP:5000"
  "quay.io":
    endpoint:
      - "http://$REGISTRY_INTERNAL_IP:5000"
  "*":
    endpoint:
      - "http://$REGISTRY_INTERNAL_IP:5000"
# Nginx enforces auth for every client, including the cluster nodes (there is no
# IP allow-list). Containerd performs the registry v2 token flow with these
# credentials: 401 -> /auth/token (Basic) -> Bearer for the actual pull.
# The credential is an unrestricted Keystone application credential created by
# 03; it is the same one stored in the K8s imagePullSecret.
configs:
  "$REGISTRY_INTERNAL_IP:5000":
    auth:
      username: "$AUTH_PROXY_APP_CRED_ID"
      password: "$AUTH_PROXY_APP_CRED_SECRET"
EOF

K3S_CLUSTER_TOKEN="${K3S_CLUSTER_TOKEN:-$(openssl rand -hex 16)}"
persist_env K3S_CLUSTER_TOKEN "$K3S_CLUSTER_TOKEN"

# 1. Create Worker VM in OpenStack
log "Creating Worker VM (flavor ds1G — fits on limited disk)."
vm_openstack tenant <<EOF
set -euo pipefail
WORKER_SG="k3s-worker-sg"
openstack security group show "\$WORKER_SG" >/dev/null 2>&1 || openstack security group create "\$WORKER_SG"
# Ingress: cluster network (all protocols), host access (SSH).
# Neutron only accepts 'any' here, never 'all' (400 "Security group rule
# protocol all not supported"). The failure must not be swallowed: without
# this rule VXLAN (8472/udp) and kubelet (10250/tcp) are dropped between the
# nodes, which shows up much later as a pod on the worker timing out.
ensure_rule() {
    local sg="\$1"; shift
    local err
    if ! err=\$(openstack security group rule create "\$@" "\$sg" 2>&1 >/dev/null); then
        case "\$err" in
            *"already exists"*|*Conflict*) : ;;
            *) echo "ERROR: security group rule on \$sg failed: \$err" >&2; exit 1 ;;
        esac
    fi
}
ensure_rule "\$WORKER_SG" --remote-ip "$K3S_CLUSTER_CIDR" --protocol any --description "k3s cluster traffic"
ensure_rule "\$WORKER_SG" --remote-ip "$HOST_ACCESS_CIDR" --protocol tcp --dst-port 22 --description "ssh from host"

for i in \$(seq 1 "$WORKER_COUNT"); do
    name="k3s-worker-\$(printf "%02d" \$i)"
    openstack server show "\$name" >/dev/null 2>&1 || \
        openstack server create --flavor ds1G --image "$IMAGE_NAME" \
          --network "$K3S_CLUSTER_NET_NAME" --security-group "\$WORKER_SG" \
          --key-name "$KEYPAIR_NAME" "\$name"
done
EOF

# Resolve Worker IPs and assign Floating IPs
worker_ips=()
worker_fips=()
for i in $(seq 1 "$WORKER_COUNT"); do
    name="k3s-worker-$(printf "%02d" $i)"
    wait_for_server_status "$name" ACTIVE

    # Floating IP (needed for SSH access from host)
    WORKER_FIP=$(vm_openstack tenant "openstack server show $name -f value -c addresses" | grep -oE '192\.168\.122\.[0-9]+' | head -n1 || true)
    if [[ -z "$WORKER_FIP" ]]; then
        log "Allocating new Floating IP for $name."
        WORKER_FIP=$(vm_openstack tenant "openstack floating ip create $PUBLIC_NET_NAME -f value -c floating_ip_address")
        vm_openstack tenant "openstack server add floating ip $name $WORKER_FIP"
    fi
    worker_fips+=("$WORKER_FIP")
    wait_for_ssh "$WORKER_FIP" "$VM_SSH_KEY"

    # Get the ACTUAL IP the VM has (not what OpenStack reports — DHCP may differ)
    ACTUAL_IP=$(ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${WORKER_FIP}" \
        "ip -4 -o addr show scope global | awk '\$2 != \"lo\" {print \$4; exit}' | cut -d/ -f1" 2>/dev/null || true)
    if [[ -n "$ACTUAL_IP" ]]; then
        worker_ips+=("$ACTUAL_IP")
        log "Worker $name actual IP: $ACTUAL_IP (FIP: $WORKER_FIP)"
    else
        # Fallback to OpenStack-reported IP
        ip=$(wait_for_fixed_ip_for_net "$name" "$K3S_CLUSTER_NET_NAME")
        worker_ips+=("$ip")
        log "Worker $name OpenStack IP: $ip (FIP: $WORKER_FIP)"
    fi
done
persist_env WORKER_IPS "$(IFS=,; echo "${worker_ips[*]}")"
persist_env WORKER_FIP "${worker_fips[0]}"

# 2. Install K3s on Master
log "Installing K3s on Master."
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$K3S_BINARY_PATH" "${SSH_USER}@${MASTER_FIP}:~/k3s"
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$tmp_registries_yaml" "${SSH_USER}@${MASTER_FIP}:~/registries.yaml"

# shellcheck disable=SC2087  # heredoc expands locally on purpose (values are injected into the remote script)
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" <<EOF
set -euo pipefail
sudo install -m 0755 ~/k3s /usr/local/bin/k3s
sudo mkdir -p /etc/rancher/k3s
sudo mv ~/registries.yaml /etc/rancher/k3s/registries.yaml

sudo tee /etc/systemd/system/k3s.service >/dev/null <<SERVICE
[Unit]
Description=K3s Server
After=network-online.target
[Service]
Type=exec
ExecStart=/usr/local/bin/k3s server --node-ip=$MASTER_INTERNAL_IP --advertise-address=$MASTER_INTERNAL_IP --tls-san=$MASTER_FIP --token=$K3S_CLUSTER_TOKEN --disable traefik --write-kubeconfig-mode=0644
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now k3s
EOF

# Wait for the K3s API to answer. A kubeconfig file on disk only proves that
# the unit started, not that the apiserver is serving.
log "Waiting for the K3s API to answer..."
K3S_READY=false
for i in $(seq 1 60); do
    if ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" \
        "sudo k3s kubectl get --raw /readyz" >/dev/null 2>&1; then
        log "K3s API is ready (attempt $i)."
        K3S_READY=true
        break
    fi
    log "Waiting for K3s API... (attempt $i/60)"
    sleep 5
done
if [[ "$K3S_READY" != "true" ]]; then
    fail "K3s API did not answer after 5 minutes. Check 'systemctl status k3s' on master."
fi

# 3. Install K3s Agent on Workers
for i in $(seq 1 "$WORKER_COUNT"); do
    ip="${worker_ips[$((i-1))]}"
    fip="${worker_fips[$((i-1))]}"
    log "Installing K3s Agent on Worker $ip (FIP: $fip)."
    scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$K3S_BINARY_PATH" "${SSH_USER}@${fip}:~/k3s"
    scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$tmp_registries_yaml" "${SSH_USER}@${fip}:~/registries.yaml"
    
# shellcheck disable=SC2087  # heredoc expands locally on purpose (values are injected into the remote script)
    ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${fip}" <<EOF
set -euo pipefail
sudo install -m 0755 ~/k3s /usr/local/bin/k3s
sudo mkdir -p /etc/rancher/k3s
sudo mv ~/registries.yaml /etc/rancher/k3s/registries.yaml

sudo tee /etc/systemd/system/k3s-agent.service >/dev/null <<SERVICE
[Unit]
Description=K3s Agent
After=network-online.target
[Service]
Type=exec
ExecStart=/usr/local/bin/k3s agent --server=https://$MASTER_INTERNAL_IP:6443 --token=$K3S_CLUSTER_TOKEN --node-ip=$ip
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now k3s-agent
EOF
done

# 4. Wait until every node reports Ready. A half-joined worker makes 11/12
# fail in ways that look unrelated (image pull timeouts, NodePort resets).
NODES_EXPECTED=$((WORKER_COUNT + 1))
log "Waiting for all $NODES_EXPECTED K3s nodes to become Ready..."
NODES_READY=false
for i in $(seq 1 60); do
    ready="$(ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" \
        "sudo k3s kubectl get nodes --no-headers 2>/dev/null | awk '\$2==\"Ready\"' | wc -l" 2>/dev/null || echo 0)"
    ready="$(printf '%s' "$ready" | tr -cd '0-9')"
    ready="${ready:-0}"
    log "Nodes Ready: $ready/$NODES_EXPECTED (attempt $i/60)"
    if (( ready >= NODES_EXPECTED )); then
        NODES_READY=true
        break
    fi
    sleep 5
done
if [[ "$NODES_READY" != "true" ]]; then
    ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" \
        "sudo k3s kubectl get nodes -o wide" || true
    fail "only $ready/$NODES_EXPECTED K3s nodes became Ready after 5 minutes (check the SG rules and the agent logs)."
fi

# Fetch Kubeconfig
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_PATH"
sed -i "s#https://127.0.0.1:6443#https://$MASTER_FIP:6443#" "$KUBECONFIG_PATH"
persist_env KUBECONFIG_PATH "$KUBECONFIG_PATH"

log "K3s Cluster is up. Workers: ${#worker_ips[@]}"
