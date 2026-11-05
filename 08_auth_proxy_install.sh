#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env AUTH_PROXY_FIP AUTH_PROXY_INTERNAL_IP REGISTRY_INTERNAL_IP VM_IP
require_env AUTH_PROXY_APP_CRED_ID AUTH_PROXY_APP_CRED_SECRET

log_section "08_auth_proxy_install.sh"
log "Installing Auth Proxy (Nginx + Token Service) on Registry VM."

AUTH_PROXY_JWT_KEY_LOCAL="$ROOT_DIR/auth-proxy-jwt.pem"
AUTH_PROXY_JWT_PUB_LOCAL="$ROOT_DIR/auth-proxy-jwt.pub.pem"

if [[ ! -f "$AUTH_PROXY_JWT_KEY_LOCAL" ]]; then
    log "Generating RSA keypair for JWT signing."
    openssl genrsa -out "$AUTH_PROXY_JWT_KEY_LOCAL" 2048
    openssl rsa -in "$AUTH_PROXY_JWT_KEY_LOCAL" -pubout -out "$AUTH_PROXY_JWT_PUB_LOCAL"
fi

# Python Token Service — single source of truth, shared with 10's checks.
tmp_token_service="$SCRIPT_DIR/lib/token_service.py"
[[ -f "$tmp_token_service" ]] || fail "missing $tmp_token_service"

# Nginx Config — proxies to Zot on localhost (same VM)
tmp_nginx_conf="$(mktemp)"
cat > "$tmp_nginx_conf" <<EOF
server {
    listen 5000;
    client_max_body_size 0;
    chunked_transfer_encoding on;

    location /auth/token {
        proxy_pass http://127.0.0.1:5001;
    }

    location /v2/ {
        proxy_pass http://127.0.0.1:5002;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 900;
    }
}
EOF

log "Installing Auth Proxy services on Registry VM ($AUTH_PROXY_FIP)."
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$tmp_token_service" "${SSH_USER}@${AUTH_PROXY_FIP}:~/token_service.py"
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$tmp_nginx_conf" "${SSH_USER}@${AUTH_PROXY_FIP}:~/nginx.conf"
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$AUTH_PROXY_JWT_KEY_LOCAL" "${SSH_USER}@${AUTH_PROXY_FIP}:~/jwt.key"

# shellcheck disable=SC2087  # heredoc expands locally on purpose (values are injected into the remote script)
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" <<EOF
set -euo pipefail

# --- Reconfigure Zot to listen on localhost:5002 (free port 5000 for Nginx) ---
echo "Reconfiguring Zot to bind 127.0.0.1:5002 (Nginx will own port 5000)."
sudo systemctl stop zot || true

cat <<JSON | sudo tee /etc/zot/config.json >/dev/null
{
  "distSpecVersion": "1.1.0",
  "storage": { "rootDirectory": "/mnt/registry/data" },
  "http": { "address": "127.0.0.1", "port": "5002" },
  "log": { "level": "info", "output": "/var/log/zot/zot.log" },
  "extensions": { "search": { "enable": true }, "ui": { "enable": true } }
}
JSON

sudo systemctl start zot
sleep 2

# --- Install Nginx + Token Service ---
sudo apt-get update -qq && sudo apt-get install -y -qq nginx

sudo mkdir -p /etc/auth-proxy
sudo mv ~/jwt.key /etc/auth-proxy/jwt.key
sudo chmod 600 /etc/auth-proxy/jwt.key
sudo mv ~/token_service.py /etc/auth-proxy/token_service.py

# Systemd for Token Service
sudo tee /etc/systemd/system/token-service.service >/dev/null <<SERVICE
[Unit]
Description=Token Auth Service
[Service]
ExecStart=/usr/bin/python3 /etc/auth-proxy/token_service.py
Environment=KEYSTONE_URL=http://$VM_IP/identity/v3
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now token-service

# Nginx
sudo mv ~/nginx.conf /etc/nginx/sites-available/auth-proxy
sudo ln -sf /etc/nginx/sites-available/auth-proxy /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl restart nginx
EOF

persist_env AUTH_PROXY_JWT_PUB_LOCAL "$AUTH_PROXY_JWT_PUB_LOCAL"
persist_env AUTH_PROXY_REALM "http://${AUTH_PROXY_FIP}:5000/auth/token"

log "Auth Proxy installed on Registry VM (Token Service + Nginx → Zot on localhost)."
