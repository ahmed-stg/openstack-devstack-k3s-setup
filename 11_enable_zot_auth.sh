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
APP_CRED_JSON=$(vm_openstack tenant "openstack application credential create deploy-app-$(date +%s) -f json")
APP_ID=$(echo "$APP_CRED_JSON" | grep -oP '"id": "\K[^"]+' || echo "$APP_CRED_JSON" | grep -oP '"ID": "\K[^"]+')
APP_SECRET=$(echo "$APP_CRED_JSON" | grep -oP '"secret": "\K[^"]+' || echo "$APP_CRED_JSON" | grep -oP '"Secret": "\K[^"]+')

[[ -n "$APP_ID" ]] || fail "Failed to extract Application Credential ID"
[[ -n "$APP_SECRET" ]] || fail "Failed to extract Application Credential Secret"

log "App Credential: ID=$APP_ID"

# 2. Push an image using Skopeo on the Master VM (no Docker insecure-registry needed)
log "Step 2: Pushing nginx:alpine to Auth Proxy via Skopeo (on Master VM)."
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" <<REMOTEEOF
set -euo pipefail
# Pull from Docker Hub and push to our registry via Auth Proxy (skopeo handles HTTP)
skopeo copy --dest-username='${APP_ID}' --dest-password='${APP_SECRET}' \
  --dest-tls-verify=false \
  docker://docker.io/library/nginx:alpine \
  docker://${AUTH_PROXY_FIP}:5000/my-app:v1
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
