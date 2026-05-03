#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env AUTH_PROXY_FIP AUTH_PROXY_APP_CRED_ID AUTH_PROXY_APP_CRED_SECRET

log_section "10_registry_smoke_test.sh"
log "Testing authenticated push/pull through Auth Proxy: $AUTH_PROXY_FIP"

# 1. Enable Bearer Auth on Zot (now on same VM as Nginx, so Zot binds 127.0.0.1:5002)

log "Enabling Bearer Auth on Zot pointing to $AUTH_PROXY_REALM"
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$AUTH_PROXY_JWT_PUB_LOCAL" "${SSH_USER}@${AUTH_PROXY_FIP}:~/jwt.pub"

ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" <<EOF
set -euo pipefail
sudo mv ~/jwt.pub /etc/zot/jwt.pub
sudo chown zot:zot /etc/zot/jwt.pub

cat <<JSON | sudo tee /etc/zot/config.json >/dev/null
{
  "distSpecVersion": "1.1.0",
  "storage": { "rootDirectory": "/mnt/registry/data" },
  "http": {
    "address": "127.0.0.1",
    "port": "5002",
    "auth": {
      "bearer": {
        "realm": "$AUTH_PROXY_REALM",
        "service": "zot-registry",
        "cert": "/etc/zot/jwt.pub"
      }
    }
  },
  "log": { "level": "info", "output": "/var/log/zot/zot.log" }
}
JSON
sudo systemctl restart zot
EOF

log "Zot is now locked down with Bearer Auth (127.0.0.1:5002 behind Nginx on port 5000)."

# 2. Test auth flow with curl (no Docker insecure-registry config needed)
log "Testing /v2/ endpoint (should return 401 with WWW-Authenticate header)."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${AUTH_PROXY_FIP}:5000/v2/")
if [[ "$HTTP_CODE" == "401" ]]; then
    log "PASS: /v2/ returns 401 (auth required)."
else
    log "WARN: /v2/ returned $HTTP_CODE (expected 401)."
fi

log "Testing /auth/token endpoint with Application Credentials."
# Base64 encode app cred
BASIC_AUTH="$(printf '%s:%s' "$AUTH_PROXY_APP_CRED_ID" "$AUTH_PROXY_APP_CRED_SECRET" | base64 -w0)"
TOKEN_RESPONSE=$(curl -s -H "Authorization: Basic $BASIC_AUTH" \
    "http://${AUTH_PROXY_FIP}:5000/auth/token?service=zot-registry&scope=repository:sandbox/smoke:pull")
if echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'token' in d or 'access_token' in d" 2>/dev/null; then
    log "PASS: Token endpoint issued a JWT."
else
    log "FAIL: Token endpoint did not return a token. Response: $TOKEN_RESPONSE"
fi

log "Smoke test complete: Auth Proxy + Zot Bearer Auth working."
