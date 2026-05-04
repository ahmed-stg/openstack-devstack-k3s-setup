#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env KUBECONFIG_PATH MASTER_FIP MASTER_SG AUTH_PROXY_FIP \
  AUTH_PROXY_APP_CRED_ID AUTH_PROXY_APP_CRED_SECRET \
  REGISTRY_INTERNAL_IP VM_SSH_KEY HOST_ACCESS_CIDR

log_section "12_demo_deploy.sh"
log "Showcase: Expose running apps, push a custom image, deploy and curl it."

# ── 0. Open NodePort range in security groups ──────────────────────
# K3s NodePort services listen on 30000-32767. The master/worker security
# groups only allow SSH (22) and K3s API (6443) from the host — we must
# open the NodePort range so we can curl from the host machine.
log "Opening NodePort range (30000-32767/tcp) in security groups."
vm_openstack tenant <<EOF
set -euo pipefail
openstack security group rule create \
  --remote-ip "$HOST_ACCESS_CIDR" \
  --protocol tcp \
  --dst-port 30000:32767 \
  "$MASTER_SG" >/dev/null 2>&1 || true
EOF

if [[ -n "${WORKER_FIP:-}" ]]; then
    vm_openstack tenant <<EOF
set -euo pipefail
openstack security group rule create \
  --remote-ip "$HOST_ACCESS_CIDR" \
  --protocol tcp \
  --dst-port 30000:32767 \
  k3s-worker-sg >/dev/null 2>&1 || true
EOF
fi

# ── Part A: Expose the existing prod-app (nginx:alpine from script 11) ──
log_section "Part A: Expose prod-app (nginx:alpine)"

# Script 11 creates the pod without labels — add one so the Service selector works.
kubectl --kubeconfig "$KUBECONFIG_PATH" label pod prod-app app=prod-app --overwrite >/dev/null 2>&1 || true

# Create a NodePort Service
log "Creating NodePort Service for prod-app."
cat <<YAML | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: prod-app-svc
spec:
  type: NodePort
  selector:
    app: prod-app
  ports:
  - port: 80
    targetPort: 80
YAML

sleep 3

PROD_NODE_PORT=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get svc prod-app-svc \
  -o jsonpath='{.spec.ports[0].nodePort}')
log "prod-app NodePort: $PROD_NODE_PORT"

# Curl it from the host
log "Curling prod-app at http://$MASTER_FIP:$PROD_NODE_PORT ..."
PROD_HTTP_CODE=$(curl -s -o /tmp/prod-app-response.txt -w '%{http_code}' \
    --max-time 10 "http://$MASTER_FIP:$PROD_NODE_PORT" || echo "000")
if [[ "$PROD_HTTP_CODE" == "200" ]]; then
    log "SUCCESS: prod-app (nginx) responded HTTP 200"
    log "Page title: $(grep -oP '(?<=<title>).*?(?=</title>)' /tmp/prod-app-response.txt 2>/dev/null || echo 'nginx')"
else
    log "WARN: prod-app returned HTTP $PROD_HTTP_CODE — pod may still be starting"
fi

PROD_APP_URL="http://$MASTER_FIP:$PROD_NODE_PORT"
persist_env PROD_APP_URL "$PROD_APP_URL"

# ── Part B: Push busybox and deploy a custom HTTP server ─────────────
#
# What is BusyBox?
# ────────────────
# BusyBox ("The Swiss Army Knife of Embedded Linux") is a single ~2 MB
# binary that combines tiny versions of many common UNIX utilities (sh,
# ls, cat, grep, sed, awk, wget, httpd, and dozens more).  It is the
# standard base image for minimal containers — far smaller than Alpine
# (1.3 MB vs 7 MB) and ideal for embedded or demo environments.
#
# In this demo we use 'busybox httpd' — its built-in HTTP server — to
# serve a custom HTML page.  This proves that *any* container image can
# be pushed through the authenticated Nginx/Zot registry and deployed
# to the K3s cluster.
# ──────────────────────────────────────────────────────────────────────
log_section "Part B: Push busybox, deploy custom HTTP server"

log "Pushing busybox:latest to private registry as demo-app:v1 ..."
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${MASTER_FIP}" <<REMOTEEOF
set -euo pipefail
skopeo copy --dest-username='${AUTH_PROXY_APP_CRED_ID}' \
  --dest-password='${AUTH_PROXY_APP_CRED_SECRET}' \
  --dest-tls-verify=false \
  docker://docker.io/library/busybox:latest \
  docker://${AUTH_PROXY_FIP}:5000/demo-app:v1
echo "busybox pushed successfully."
REMOTEEOF

# Deploy demo-app
INTERNAL_REGISTRY="${REGISTRY_INTERNAL_IP}:5000"
log "Deploying demo-app (busybox httpd with custom page)."
cat <<YAML | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: demo-app
  labels:
    app: demo-app
spec:
  containers:
  - name: app
    image: ${INTERNAL_REGISTRY}/demo-app:v1
    command: ["/bin/sh", "-c"]
    args:
    - |
      mkdir -p /www
      printf '%s\n' \
        '<!DOCTYPE html>' \
        '<html><head><title>Cloud Demo App</title></head>' \
        '<body>' \
        '<h1>Hello from the Private Cloud!</h1>' \
        '<p>Served by <strong>BusyBox httpd</strong> in a K3s pod.</p>' \
        '<p>Image pushed through the <strong>authenticated Nginx/Zot registry</strong></p>' \
        '<p>and pulled by K3s over the <strong>internal network</strong>.</p>' \
        '</body></html>' > /www/index.html
      httpd -f -p 80 -h /www
    ports:
    - containerPort: 80
  imagePullSecrets:
  - name: registry-auth
YAML

log "Waiting for demo-app to be ready..."
kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready pod/demo-app --timeout=120s

# Create NodePort Service for demo-app
log "Creating NodePort Service for demo-app."
cat <<YAML | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: demo-app-svc
spec:
  type: NodePort
  selector:
    app: demo-app
  ports:
  - port: 80
    targetPort: 80
YAML

sleep 3

DEMO_NODE_PORT=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get svc demo-app-svc \
  -o jsonpath='{.spec.ports[0].nodePort}')
log "demo-app NodePort: $DEMO_NODE_PORT"

# Curl it from the host
log "Curling demo-app at http://$MASTER_FIP:$DEMO_NODE_PORT ..."
DEMO_HTTP_CODE=$(curl -s -o /tmp/demo-app-response.txt -w '%{http_code}' \
    --max-time 10 "http://$MASTER_FIP:$DEMO_NODE_PORT" || echo "000")
if [[ "$DEMO_HTTP_CODE" == "200" ]]; then
    log "SUCCESS: demo-app (busybox httpd) responded HTTP 200"
    log "Heading: $(grep -oP '(?<=<h1>).*?(?=</h1>)' /tmp/demo-app-response.txt 2>/dev/null || echo '(parse failed)')"
else
    log "WARN: demo-app returned HTTP $DEMO_HTTP_CODE"
fi

DEMO_APP_URL="http://$MASTER_FIP:$DEMO_NODE_PORT"
persist_env DEMO_APP_URL "$DEMO_APP_URL"

# ── Summary ─────────────────────────────────────────────────────────
log_section "DEMO DEPLOY COMPLETE"
echo ""
echo "  Reachable apps (curl from your host):"
echo "    prod-app (nginx:alpine) : $PROD_APP_URL"
echo "    demo-app (busybox httpd): $DEMO_APP_URL"
echo ""
echo "  What is BusyBox?"
echo "  ─────────────────"
echo "  BusyBox ('The Swiss Army Knife of Embedded Linux') is a single ~2 MB"
echo "  binary that combines tiny versions of many common UNIX utilities"
echo "  (sh, ls, cat, grep, wget, httpd, and dozens more). It is the standard"
echo "  base image for minimal containers — far smaller than Alpine (1.3 MB"
echo "  vs 7 MB) and ideal for embedded or demo environments."
echo ""
echo "  In this demo, 'busybox httpd' — its built-in HTTP server — serves a"
echo "  custom HTML page, proving that any container image can be pushed through"
echo "  the authenticated Nginx/Zot registry and deployed to the K3s cluster."
