#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env AUTH_PROXY_FIP REGISTRY_INTERNAL_IP MASTER_FIP
require_env AUTH_PROXY_APP_CRED_ID AUTH_PROXY_APP_CRED_SECRET AUTH_PROXY_JWT_PUB_LOCAL

log_section "10_registry_smoke_test.sh"
log "Enforcing registry auth at Nginx (Zot stays loopback-only, unauthenticated)."

# 1. Zot itself keeps no auth: it is bound to 127.0.0.1 and only reachable
# through Nginx, which is the single enforcement point.
log "Ensuring Zot has no bearer auth and listens on loopback only."
# Remote blocks are executed by a NON-login bash on purpose: Ubuntu's
# ~/.bash_logout calls `clear_console -q`, which fails without a tty and — with
# `set -e` still active — turns an explicit `exit 0` into exit status 1. Using
# `bash -s` keeps .bash_logout out of the picture and preserves exit codes.
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" 'bash -s' <<EOF
set -euo pipefail
cat <<JSON | sudo tee /etc/zot/config.json >/dev/null
{
  "distSpecVersion": "1.1.0",
  "storage": { "rootDirectory": "/mnt/registry/data" },
  "http": { "address": "127.0.0.1", "port": "5002" },
  "log": { "level": "info", "output": "/var/log/zot/zot.log" },
  "extensions": { "search": { "enable": true }, "ui": { "enable": true } }
}
JSON
sudo systemctl restart zot
EOF

# 2. The token service is installed by 08 from lib/token_service.py (single
#    source of truth). Here we only hand it the public key and check that the
#    /auth/validate endpoint is live. 10 must never rewrite the service: that
#    is what caused the two copies to drift apart.
log "Installing JWT public key for token validation."
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$AUTH_PROXY_JWT_PUB_LOCAL" \
    "${SSH_USER}@${AUTH_PROXY_FIP}:~/jwt.pub"

ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" 'bash -s' <<EOF
set -euo pipefail
sudo mv ~/jwt.pub /etc/zot/jwt.pub
sudo chown zot:zot /etc/zot/jwt.pub
sudo systemctl restart token-service
# A token-less /auth/validate must answer 401, which proves the endpoint exists
# and the service is up (a 404 would mean 08 installed an older script).
for i in \$(seq 1 15); do
    CODE=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:5001/auth/validate || true)
    if [[ "\$CODE" == "401" ]]; then
        echo "Token service /auth/validate is live (HTTP 401 without a token)."
        exit 0
    fi
    sleep 2
done
echo "FAIL: /auth/validate did not answer 401 within 30s" >&2
exit 1
EOF

# 3. Reconfigure Nginx: every /v2/ request needs a valid Bearer token.
#    There is deliberately NO ip allow-list. The K3s nodes authenticate with the
#    application credential configured in registries.yaml (09), so in-cluster
#    traffic is authorised exactly like external traffic. The previous
#    "satisfy any + allow 10.10.0.0/24" made any pod able to push anonymously.
log "Reconfiguring Nginx: Bearer token required for every registry request."
tmp_nginx_conf="$(mktemp)"
cat > "$tmp_nginx_conf" <<EOF
server {
    listen 5000;
    client_max_body_size 0;
    chunked_transfer_encoding on;

    # Auth token endpoint — open, but requires Basic application credentials.
    location /auth/token {
        proxy_pass http://127.0.0.1:5001;
    }

    # /v2/ — authenticated for internal and external clients alike.
    location /v2/ {
        auth_request /auth_validate;
        auth_request_set \$auth_status \$upstream_status;

        # On auth failure, tell the client where to get a token.
        error_page 401 = /auth_error_401;

        proxy_pass http://127.0.0.1:5002;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 900;
    }

    # Auth validation subrequest. The token service needs the ORIGINAL method
    # and URI to decide whether the token's scope covers this request;
    # auth_request subrequests are always GET on /auth_validate.
    location = /auth_validate {
        internal;
        proxy_pass http://127.0.0.1:5001/auth/validate;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI \$request_uri;
        proxy_set_header X-Original-Method \$request_method;
        proxy_set_header Authorization \$http_authorization;
        # CRITICAL: use \$http_host (includes port), not \$host (strips port).
        # The token service uses this to construct the realm URL in
        # WWW-Authenticate — without the port, Skopeo dials port 80.
        proxy_set_header Host \$http_host;
    }

    # Return proper WWW-Authenticate header on 401
    location = /auth_error_401 {
        internal;
        default_type text/plain;
        add_header WWW-Authenticate 'Bearer realm="http://\$http_host/auth/token",service="zot-registry"' always;
        return 401 "authentication required\n";
    }
}
EOF

scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$tmp_nginx_conf" "${SSH_USER}@${AUTH_PROXY_FIP}:~/nginx.conf"

ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" 'bash -s' <<DEOF
set -euo pipefail
sudo mv ~/nginx.conf /etc/nginx/sites-available/auth-proxy
sudo nginx -t && sudo systemctl restart nginx
DEOF

# 4. Hard gates. Each failure would otherwise surface much later as a confusing
#    timeout, an empty catalog, or a 000000 from the deploy scripts.
REGISTRY_URL="http://${AUTH_PROXY_FIP}:5000"
http_code() {
    local code
    if ! code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"); then
        code="000"
    fi
    printf '%s' "$code"
}
mint_token() {  # $1 = scope, empty for a ping-only token
    local scope="$1"
    curl -s -u "${AUTH_PROXY_APP_CRED_ID}:${AUTH_PROXY_APP_CRED_SECRET}" \
        "${REGISTRY_URL}/auth/token?service=zot-registry${scope:+&scope=${scope}}" \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("token") or d.get("access_token") or "")'
}

log "T1: /v2/ without a token must be 401."
CODE=$(http_code "${REGISTRY_URL}/v2/")
[[ "$CODE" == "401" ]] || fail "/v2/ without a token returned ${CODE} (expected 401)."
log "PASS: unauthenticated /v2/ is rejected."

log "T2: a valid token must be accepted on the ping endpoint."
TOKEN=$(mint_token "")
[[ -n "$TOKEN" ]] || fail "token endpoint did not return a JWT."
CODE=$(http_code -H "Authorization: Bearer ${TOKEN}" "${REGISTRY_URL}/v2/")
[[ "$CODE" == "200" ]] || fail "/v2/ with a valid token returned ${CODE} (expected 200)."
log "PASS: token endpoint issues a JWT and /v2/ accepts it."

log "T3: a pull-scoped token must be accepted for that repository."
PULL_TOKEN=$(mint_token "repository:rancher/mirrored-pause:pull")
CODE=$(http_code -H "Authorization: Bearer ${PULL_TOKEN}" \
    "${REGISTRY_URL}/v2/rancher/mirrored-pause/tags/list")
[[ "$CODE" == "200" ]] || fail "pull token on mirrored-pause returned ${CODE} (expected 200)."
log "PASS: pull-scoped token works on its repository."

log "T4: a pull-only token must NOT be able to push."
CODE=$(http_code -X PUT -H "Authorization: Bearer ${PULL_TOKEN}" \
    -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data '{}' "${REGISTRY_URL}/v2/my-app/manifests/scope-check")
[[ "$CODE" == "401" || "$CODE" == "403" ]] || fail \
    "pull-only token was allowed to PUT (HTTP ${CODE}) — scope is not enforced."
log "PASS: scope is enforced (pull token rejected on push)."

log "T5: a token for one repository must NOT grant access to another."
CODE=$(http_code -H "Authorization: Bearer ${PULL_TOKEN}" \
    "${REGISTRY_URL}/v2/my-app/tags/list")
[[ "$CODE" == "401" || "$CODE" == "403" ]] || fail \
    "token scoped to mirrored-pause was accepted for my-app (HTTP ${CODE})."
log "PASS: repository scope is enforced."

log "T6: in-cluster clients must no longer bypass authentication."
CODE=$(ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${REGISTRY_INTERNAL_IP}:5000/v2/" 2>/dev/null || echo "000")
[[ "$CODE" == "401" ]] || fail \
    "a cluster node reached the registry without a token (HTTP ${CODE}) — the IP allow-list still bypasses auth."
log "PASS: internal traffic is authenticated too (no IP allow-list)."

log "T7: malformed scope must be rejected with 400, not crash the service."
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${AUTH_PROXY_APP_CRED_ID}:${AUTH_PROXY_APP_CRED_SECRET}" \
    "${REGISTRY_URL}/auth/token?scope=not-a-valid-scope" || true)
[[ "$CODE" == "400" ]] || fail "malformed scope returned ${CODE} (expected 400)."
log "PASS: malformed scope is rejected cleanly."

# 5. The registry must actually hold every mirrored image. K3s resolves
# docker.io/<repo> through registries.yaml, so a wrong repository path (for
# example "mirrored-pause" instead of "rancher/mirrored-pause") makes the pull
# silently fall back to the internet instead of failing.
log "Checking that every airgap image is mirrored in Zot."
CATALOG=$(ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" \
    "curl -s --max-time 10 http://127.0.0.1:5002/v2/_catalog" 2>/dev/null || true)
# Must match the images in the pinned k3s airgap tarball (v1.31.1+k3s1).
EXPECTED_REPOS=(
    rancher/klipper-helm
    rancher/klipper-lb
    rancher/local-path-provisioner
    rancher/mirrored-coredns-coredns
    rancher/mirrored-library-busybox
    rancher/mirrored-library-traefik
    rancher/mirrored-metrics-server
    rancher/mirrored-pause
)
MISSING=()
for repo in "${EXPECTED_REPOS[@]}"; do
    printf '%s' "$CATALOG" | grep -q "\"${repo}\"" || MISSING+=("$repo")
done
if (( ${#MISSING[@]} > 0 )); then
    fail "Zot catalog is missing: ${MISSING[*]} (got: ${CATALOG:-<empty>})"
fi
log "PASS: all ${#EXPECTED_REPOS[@]} airgap images are mirrored under rancher/."

log "Smoke test complete: auth enforced for all clients, scope checked, images mirrored."
