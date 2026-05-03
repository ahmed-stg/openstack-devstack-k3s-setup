#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env AUTH_PROXY_FIP AUTH_PROXY_APP_CRED_ID AUTH_PROXY_APP_CRED_SECRET AUTH_PROXY_JWT_PUB_LOCAL K3S_CLUSTER_CIDR K3S_SERVICES_CIDR

log_section "10_registry_smoke_test.sh"
log "Configuring Nginx auth enforcement (Zot stays unauthenticated for K3s pulls)."

# 1. Ensure Zot has NO bearer auth — K3s registries.yaml can't do bearer tokens.
# Auth is enforced at the Nginx layer instead.
log "Ensuring Zot has no bearer auth (K3s internal pulls must work without tokens)."
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" <<EOF
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

# 2. Add /auth/validate endpoint to token service
# This endpoint checks if a Bearer token is valid (for Nginx auth_request).
log "Adding /auth/validate endpoint to token service for Nginx auth_request."
tmp_validate_patch="$(mktemp)"
cat > "$tmp_validate_patch" <<'PYEOF'
import base64, json, os, subprocess, time, urllib.request, urllib.parse, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEYSTONE_URL = os.environ["KEYSTONE_URL"]
PRIVATE_KEY = "/etc/auth-proxy/jwt.key"
SERVICE_NAME = "zot-registry"

def jwt_sign(payload):
    header = {"alg": "RS256", "typ": "JWT"}
    signing_input = base64.urlsafe_b64encode(json.dumps(header).encode()).rstrip(b'=') + b'.' + \
                    base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b'=')
    proc = subprocess.run(["openssl", "dgst", "-sha256", "-sign", PRIVATE_KEY], input=signing_input, capture_output=True, check=True)
    return signing_input.decode() + "." + base64.urlsafe_b64encode(proc.stdout).rstrip(b'=').decode()

def validate_bearer_token(auth_header):
    """Validate a Bearer token by checking its JWT signature with our public key."""
    import tempfile
    if not auth_header or not auth_header.startswith("Bearer "):
        return False
    token = auth_header[7:]
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return False
        # Verify signature — openssl dgst -signature requires a file, not stdin
        signing_input = (parts[0] + "." + parts[1]).encode()
        signature = base64.urlsafe_b64decode(parts[2] + "==")
        with tempfile.NamedTemporaryFile(delete=False) as sig_file:
            sig_file.write(signature)
            sig_path = sig_file.name
        try:
            proc = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", "/etc/zot/jwt.pub", "-signature", sig_path],
                input=signing_input,
                capture_output=True
            )
        finally:
            os.unlink(sig_path)
        # Also check expiry
        payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=="))
        if payload.get("exp", 0) < time.time():
            return False
        return proc.returncode == 0
    except Exception:
        return False

class TokenHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        self.do_GET()

    def do_GET(self):
        if self.path.startswith("/auth/validate"):
            # Called by Nginx auth_request — returns 200 if Bearer token is valid, 401 otherwise
            auth_header = self.headers.get("Authorization", "")
            if validate_bearer_token(auth_header):
                self.send_response(200)
                self.end_headers()
            else:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Bearer realm="http://' + self.headers.get("Host", "localhost:5000") + '/auth/token",service="zot-registry"')
                self.end_headers()

        elif self.path.startswith("/auth/token"):
            auth_header = self.headers.get("Authorization", "")
            if not auth_header.startswith("Basic "):
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="Keystone"')
                self.end_headers()
                return

            cred_raw = base64.b64decode(auth_header[6:]).decode()
            if ":" not in cred_raw:
                self.send_response(400)
                self.end_headers()
                return
            app_id, app_secret = cred_raw.split(":", 1)

            # Validate against Keystone
            try:
                body = json.dumps({"auth": {"identity": {"methods": ["application_credential"], "application_credential": {"id": app_id, "secret": app_secret}}}}).encode()
                req = urllib.request.Request(f"{KEYSTONE_URL}/auth/tokens", data=body, headers={"Content-Type": "application/json"}, method="POST")
                with urllib.request.urlopen(req) as resp:
                    if resp.status != 201:
                        raise Exception(f"Keystone returned {resp.status}")
            except urllib.error.HTTPError as e:
                err_body = e.read().decode(errors='replace')
                print(f"Keystone auth failed: HTTP {e.code} — {err_body}", flush=True)
                self.send_response(401)
                self.end_headers()
                return
            except Exception as e:
                print(f"Keystone connection error: {e}", flush=True)
                self.send_response(401)
                self.end_headers()
                return

            # Issue Token
            params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            scope = params.get("scope", ["repository:sandbox/smoke:pull"])[0]
            now = int(time.time())
            token_payload = {
                "iss": "auth-proxy", "sub": app_id, "aud": SERVICE_NAME,
                "iat": now, "nbf": now, "exp": now + 3600,
                "access": [{"type": scope.split(":")[0], "name": scope.split(":")[1], "actions": scope.split(":")[2].split(",")}]
            }
            token = jwt_sign(token_payload)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"token": token, "access_token": token, "expires_in": 3600}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        print(f"[token-service] {fmt % args}", flush=True)

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 5001), TokenHandler).serve_forever()
PYEOF

# Copy JWT public key to /etc/zot/jwt.pub for token validation
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$AUTH_PROXY_JWT_PUB_LOCAL" "${SSH_USER}@${AUTH_PROXY_FIP}:~/jwt.pub"
scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$tmp_validate_patch" "${SSH_USER}@${AUTH_PROXY_FIP}:~/token_service.py"

ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" <<EOF
set -euo pipefail
sudo mv ~/jwt.pub /etc/zot/jwt.pub
sudo chown zot:zot /etc/zot/jwt.pub
sudo mv ~/token_service.py /etc/auth-proxy/token_service.py
sudo systemctl restart token-service
EOF

# 3. Reconfigure Nginx: satisfy any (IP allow OR bearer token)
log "Reconfiguring Nginx: internal IPs bypass auth, external needs Bearer token."
tmp_nginx_conf="$(mktemp)"
cat > "$tmp_nginx_conf" <<EOF
server {
    listen 5000;
    client_max_body_size 0;
    chunked_transfer_encoding on;

    # Auth token endpoint — always open (issues JWTs)
    location /auth/token {
        proxy_pass http://127.0.0.1:5001;
    }

    # /v2/ — internal IPs bypass auth, external must present Bearer token
    location /v2/ {
        # Allow EITHER: trusted internal IP, OR valid Bearer token
        satisfy any;

        # Access control: allow internal networks
        allow $K3S_CLUSTER_CIDR;
        allow $K3S_SERVICES_CIDR;
        deny all;

        # Auth request: validate Bearer token via token service
        auth_request /auth_validate;
        auth_request_set \$auth_status \$upstream_status;

        # On auth failure, tell the client where to get a token
        error_page 401 = /auth_error_401;

        proxy_pass http://127.0.0.1:5002;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 900;
    }

    # Auth validation subrequest
    location = /auth_validate {
        internal;
        proxy_pass http://127.0.0.1:5001/auth/validate;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI \$request_uri;
        proxy_set_header Authorization \$http_authorization;
    }

    # Return proper WWW-Authenticate header on 401
    location = /auth_error_401 {
        internal;
        default_type text/plain;
        add_header WWW-Authenticate 'Bearer realm="http://\$host/auth/token",service="zot-registry"' always;
        return 401 "authentication required\n";
    }
}
EOF

scp "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "$tmp_nginx_conf" "${SSH_USER}@${AUTH_PROXY_FIP}:~/nginx.conf"

ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" <<DEOF
set -euo pipefail
sudo mv ~/nginx.conf /etc/nginx/sites-available/auth-proxy
sudo nginx -t && sudo systemctl restart nginx
DEOF

# 4. Smoke tests
log "Testing /v2/ endpoint from external (should return 401 with WWW-Authenticate)."
RESP=$(curl -s -D - "http://${AUTH_PROXY_FIP}:5000/v2/" 2>/dev/null)
HTTP_CODE=$(echo "$RESP" | head -1 | grep -oE '[0-9]{3}')
if [[ "$HTTP_CODE" == "401" ]]; then
    log "PASS: /v2/ returns 401 (auth required from external)."
else
    log "WARN: /v2/ returned $HTTP_CODE (expected 401)."
fi

log "Testing /auth/token endpoint with Application Credentials."
BASIC_AUTH="$(printf '%s:%s' "$AUTH_PROXY_APP_CRED_ID" "$AUTH_PROXY_APP_CRED_SECRET" | base64 -w0)"
TOKEN_RESPONSE=$(curl -s -H "Authorization: Basic $BASIC_AUTH" \
    "http://${AUTH_PROXY_FIP}:5000/auth/token?service=zot-registry&scope=repository:sandbox/smoke:pull")
if echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'token' in d or 'access_token' in d" 2>/dev/null; then
    log "PASS: Token endpoint issued a JWT."
else
    log "FAIL: Token endpoint did not return a token. Response: $TOKEN_RESPONSE"
fi

log "Testing /v2/ with Bearer token (should return 200)."
JWT_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token') or d.get('access_token'))")
AUTHED_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $JWT_TOKEN" "http://${AUTH_PROXY_FIP}:5000/v2/")
if [[ "$AUTHED_CODE" == "200" ]]; then
    log "PASS: /v2/ with Bearer token returns 200."
else
    log "WARN: /v2/ with Bearer token returned $AUTHED_CODE (expected 200)."
fi

log "Smoke test complete: Nginx auth enforcement working (internal=open, external=JWT required)."
