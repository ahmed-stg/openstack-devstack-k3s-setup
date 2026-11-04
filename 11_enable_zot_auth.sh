#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env KUBECONFIG_PATH REGISTRY_INTERNAL_IP AUTH_PROXY_FIP MASTER_FIP

log_section "11_deployment_flow_demo.sh"
log "Demonstrating the Production Cloud Deployment Flow."

# 1. Create a "Deployment" Application Credential
log "Step 1: Creating a new Application Credential for the app deployment."
APP_CRED_JSON=$(vm_openstack tenant "openstack application credential create deploy-app-$(date +%s) --unrestricted -f json")
# Use python3 to parse JSON robustly (vm_openstack output may include MOTD/extra text)
APP_ID=$(echo "$APP_CRED_JSON" | python3 -c "import sys,json; lines=''.join(sys.stdin); d=json.loads(lines[lines.index('{'):]); print(d.get('id') or d.get('ID'))")
APP_SECRET=$(echo "$APP_CRED_JSON" | python3 -c "import sys,json; lines=''.join(sys.stdin); d=json.loads(lines[lines.index('{'):]); print(d.get('secret') or d.get('Secret'))")

[[ -n "$APP_ID" ]] || fail "Failed to extract Application Credential ID"
[[ -n "$APP_SECRET" ]] || fail "Failed to extract Application Credential Secret"

log "App Credential: ID=$APP_ID"

# Quick sanity check: verify the credential works against Keystone directly
log "Verifying credential against Keystone (from registry VM)..."
if ! VALIDATE_CODE=$(ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" \
    "curl -s -o /dev/null -w '%{http_code}' -X POST \
     -H 'Content-Type: application/json' \
     -d '{\"auth\":{\"identity\":{\"methods\":[\"application_credential\"],\"application_credential\":{\"id\":\"${APP_ID}\",\"secret\":\"${APP_SECRET}\"}}}}' \
     http://${VM_IP}/identity/v3/auth/tokens" 2>/dev/null); then
    VALIDATE_CODE="000"
fi
if [[ "$VALIDATE_CODE" == "201" ]]; then
    log "PASS: Credential validated against Keystone (HTTP 201)."
else
    log "WARN: Keystone returned HTTP $VALIDATE_CODE for credential validation. Checking connectivity..."
    # Check if registry VM can reach Keystone at all
    ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${AUTH_PROXY_FIP}" \
        "curl -s -o /dev/null -w 'HTTP %{http_code}' http://${VM_IP}/identity/v3/ 2>&1 || echo 'UNREACHABLE'" 2>/dev/null
fi

# 2. Push an image using Skopeo on the Master VM (no Docker insecure-registry needed)
log "Step 2: Pushing nginx:alpine to Auth Proxy via Skopeo (on Master VM)."
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" <<REMOTEEOF
set -euo pipefail
# Pull from Docker Hub and push to our registry via Auth Proxy (skopeo handles HTTP).
# docker.io is an external dependency: DNS/registry hiccups are transient, so retry
# instead of failing the whole chain on one EAI_AGAIN.
push_image() {
    local src="\$1" dst="\$2" attempt
    for attempt in 1 2 3 4; do
        if skopeo copy --dest-username='${APP_ID}' --dest-password='${APP_SECRET}' \
             --dest-tls-verify=false "\$src" "\$dst"; then
            return 0
        fi
        echo "push of \$src failed (attempt \$attempt/4), retrying in 15s..." >&2
        sleep 15
    done
    return 1
}
push_image docker://docker.io/library/nginx:alpine docker://${AUTH_PROXY_FIP}:5000/my-app:v1
echo "Image pushed successfully."
REMOTEEOF

# 3. Create K8s Secret
log "Step 3: Creating Kubernetes ImagePullSecret using the Application Credential."
# Note: K3s pulls from INTERNAL_IP for performance and security
INTERNAL_REGISTRY="${REGISTRY_INTERNAL_IP}:5000"

kubectl --kubeconfig "$KUBECONFIG_PATH" create secret docker-registry registry-auth \
  --docker-server="$INTERNAL_REGISTRY" \
  --docker-username="$APP_ID" \
  --docker-password="$APP_SECRET" \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -

# 4. Deploy Pod
log "Step 4: Deploying a Pod that pulls from the internal registry."
cat <<EOF | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: prod-app
spec:
  containers:
  - name: app
    image: $INTERNAL_REGISTRY/my-app:v1
  imagePullSecrets:
  - name: registry-auth
EOF

log "Step 5: Waiting for pod to be ready."
kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready pod/prod-app --timeout=120s

log "=== DEPLOYMENT FLOW COMPLETE ==="
log "Architecture Summary:"
log "1. User -> Nginx (FIP:5000) on Registry VM: Pushes data, gets JWT from Token Service."
log "2. Nginx -> Zot (127.0.0.1:5002) on same VM: Proxies data with zero latency."
log "3. K3s -> Nginx (InternalIP:5000): Pulls data through same proxy."
log "4. Token Service -> Keystone: Validates Application Credentials."
