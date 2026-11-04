#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env REGISTRY_FIP REGISTRY_INTERNAL_IP K3S_IMAGES_PATH ZOT_BINARY_PATH

log_section "06_zot_install.sh"

# 1. Ensure Binaries are available on host
if [[ ! -f "$ZOT_BINARY_PATH" ]]; then
    log "Downloading Zot binary on host..."
    curl -L "https://github.com/project-zot/zot/releases/download/v2.1.16/zot-linux-amd64" -o "$ZOT_BINARY_PATH"
    chmod +x "$ZOT_BINARY_PATH"
fi

SKOPEO_BINARY_PATH="$ROOT_DIR/skopeo"
if [[ ! -f "$SKOPEO_BINARY_PATH" ]]; then
    log "Downloading Skopeo binary on host..."
    # Using a reliable static build of skopeo
    curl -L "https://github.com/lework/skopeo-binary/releases/download/v1.13.3/skopeo-linux-amd64" -o "$SKOPEO_BINARY_PATH"
    chmod +x "$SKOPEO_BINARY_PATH"
fi

# 2. Install Zot on Registry VM (direct SSH — it has a floating IP now)
log "Installing Zot on Registry VM ($REGISTRY_FIP)."
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$ZOT_BINARY_PATH" "${SSH_USER}@${REGISTRY_FIP}:~/zot"

ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${REGISTRY_FIP}" <<'EOF'
set -euo pipefail
# Setup User and Disk
if ! id -u zot >/dev/null 2>&1; then
    sudo adduser --system --group --no-create-home --disabled-password zot
fi

REGISTRY_DISK="$(lsblk -nrpo NAME,TYPE,MOUNTPOINT | awk '$2 == "disk" && $3 == "" && $1 ~ /vd[b-z]$/ { print $1; exit }')"
if [[ -n "$REGISTRY_DISK" ]]; then
    if ! sudo blkid "$REGISTRY_DISK" >/dev/null 2>&1; then sudo mkfs.ext4 -F "$REGISTRY_DISK"; fi
    UUID_VALUE="$(sudo blkid -s UUID -o value "$REGISTRY_DISK")"
    sudo mkdir -p /mnt/registry
    grep -q "$UUID_VALUE" /etc/fstab || echo "UUID=$UUID_VALUE /mnt/registry ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
    mountpoint -q /mnt/registry || sudo mount /mnt/registry
    sudo chown zot:zot /mnt/registry
else
    sudo mkdir -p /mnt/registry
    sudo chown zot:zot /mnt/registry
fi

sudo install -m 0755 ~/zot /usr/local/bin/zot
sudo mkdir -p /etc/zot /var/log/zot /mnt/registry/data
sudo chown -R zot:zot /etc/zot /var/log/zot /mnt/registry/data

cat <<JSON | sudo tee /etc/zot/config.json >/dev/null
{
  "distSpecVersion": "1.1.0",
  "storage": { "rootDirectory": "/mnt/registry/data" },
  "http": { "address": "0.0.0.0", "port": "5000" },
  "log": { "level": "info", "output": "/var/log/zot/zot.log" },
  "extensions": { "search": { "enable": true }, "ui": { "enable": true } }
}
JSON

sudo tee /etc/systemd/system/zot.service >/dev/null <<SERVICE
[Unit]
Description=Zot OCI Registry
After=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/zot serve /etc/zot/config.json
User=zot
Group=zot
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now zot
EOF

log "Zot installed. Waiting for the registry API to answer..."
ZOT_READY=false
for i in $(seq 1 30); do
    if ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${REGISTRY_FIP}" \
        "curl -sf -o /dev/null --max-time 3 http://127.0.0.1:5000/v2/" 2>/dev/null; then
        log "Zot is answering (attempt $i)."
        ZOT_READY=true
        break
    fi
    sleep 2
done
if [[ "$ZOT_READY" != "true" ]]; then
    fail "Zot did not answer on :5000 within 60s (check 'systemctl status zot')."
fi

# 3. Optimized Airgap Strategy: Push images to Zot once
log "Pushing K3s airgap images to Zot using host-downloaded Skopeo."

log "Installing Skopeo and JQ on Master VM."
./scp-safe -i "$VM_SSH_KEY" "$SKOPEO_BINARY_PATH" "${SSH_USER}@${MASTER_FIP}:~/skopeo"
./ssh-safe -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" "sudo install -m 0755 ~/skopeo /usr/local/bin/skopeo && sudo apt-get update -qq && sudo apt-get install -y -qq jq"

log "Copying import script and images to Master VM."
./scp-safe -i "$VM_SSH_KEY" "$SCRIPT_DIR/import_images.sh" "${SSH_USER}@${MASTER_FIP}:~/import_images.sh"
./scp-safe -i "$VM_SSH_KEY" "$K3S_IMAGES_PATH" "${SSH_USER}@${MASTER_FIP}:/home/${SSH_USER}/k3s-airgap-images.tar"

log "Importing images into Zot from Master VM."
./ssh-safe -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" "REGISTRY_INTERNAL_IP=$REGISTRY_INTERNAL_IP bash ~/import_images.sh"

log "Airgap images imported into Zot."
