# Deploy Workflow — Push to Production

This guide shows how to push a container image through the Auth Proxy
and deploy it on the K3s cluster.

## Prerequisites

After running `sudo bash XX_RUN_FROM_SNAPSHOT.sh`, you should have:

```bash
source devstack_env          # loads all IPs and credentials
echo $AUTH_PROXY_FIP         # Registry + Auth Proxy floating IP
echo $MASTER_FIP             # K3s master floating IP
echo $REGISTRY_INTERNAL_IP   # Registry internal IP (K3s pulls from here)
echo $KUBECONFIG_PATH        # k3s-kubeconfig.yaml
echo $PROD_APP_URL           # nginx:alpine (exposed by script 12)
echo $DEMO_APP_URL           # busybox httpd (exposed by script 12)
```

Script 12 already exposes two apps via NodePort. You can curl them immediately:

```bash
source devstack_env
curl $PROD_APP_URL    # nginx:alpine default page
curl $DEMO_APP_URL    # busybox httpd custom page
```

## Step 1 — Create an Application Credential

Every deployment needs its own Keystone Application Credential.
This acts as a "robot account" — the K8s cluster will use it to pull images.

```bash
source devstack_env

APP_CRED_JSON=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -i "$VM_SSH_KEY" ubuntu@$VM_IP \
  "bash -lc 'source ~/k3s-user-openrc.sh 2>/dev/null; \
   openstack application credential create my-deploy-$(date +%s) --unrestricted -f json'" 2>/dev/null)

APP_ID=$(echo "$APP_CRED_JSON" | python3 -c "import sys,json; lines=''.join(sys.stdin); d=json.loads(lines[lines.index('{'):]); print(d.get('id') or d.get('ID'))")
APP_SECRET=$(echo "$APP_CRED_JSON" | python3 -c "import sys,json; lines=''.join(sys.stdin); d=json.loads(lines[lines.index('{'):]); print(d.get('secret') or d.get('Secret'))")

echo "APP_ID=$APP_ID"
echo "APP_SECRET=$APP_SECRET"
```

## Step 2 — Push Your Image

Use Skopeo on the Master VM to copy an image into the registry.
The Auth Proxy validates your credentials via Keystone and issues a JWT.

### Option A: Push from Docker Hub (no local Docker needed)

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -i "$VM_SSH_KEY" ubuntu@$MASTER_FIP <<EOF
skopeo copy \
  --dest-username='$APP_ID' \
  --dest-password='$APP_SECRET' \
  --dest-tls-verify=false \
  docker://docker.io/library/nginx:alpine \
  docker://$AUTH_PROXY_FIP:5000/my-app:v1
EOF
```

### Option B: Push a custom image (Node.js hello-world example)

First, build on the Master VM:

```bash
ssh -i "$VM_SSH_KEY" ubuntu@$MASTER_FIP <<'EOF'
# Create a minimal Node.js server
mkdir -p ~/my-app && cat > ~/my-app/server.js <<'JS'
const http = require('http');
const os = require('os');
const server = http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type': 'text/plain'});
  res.end('Hello from ' + os.hostname() + '\n');
});
server.listen(8080);
JS

cat > ~/my-app/Dockerfile <<'DF'
FROM node:20-alpine
COPY server.js /app/server.js
CMD ["node", "/app/server.js"]
DF

# Build with buildah (no Docker daemon needed)
sudo apt-get install -y -qq buildah 2>/dev/null
buildah build -t my-app:v1 ~/my-app

# Push to our registry
buildah push --tls-verify=false \
  --creds=$APP_ID:$APP_SECRET \
  my-app:v1 docker://$AUTH_PROXY_FIP:5000/my-app:v1
EOF
```

## Step 3 — Create a Kubernetes ImagePullSecret

The K3s workers pull from the **internal** registry IP (no floating IP needed).
Nginx allows internal IPs (10.10.0.0/24, 10.20.0.0/24) without authentication,
so the ImagePullSecret is technically optional for internal pulls. However,
creating it is good practice and required if you later restrict access.

```bash
INTERNAL_REGISTRY="${REGISTRY_INTERNAL_IP}:5000"

kubectl --kubeconfig "$KUBECONFIG_PATH" create secret docker-registry registry-auth \
  --docker-server="$INTERNAL_REGISTRY" \
  --docker-username="$APP_ID" \
  --docker-password="$APP_SECRET" \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
```

## Step 4 — Deploy

```bash
cat <<YAML | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: $INTERNAL_REGISTRY/my-app:v1
  imagePullSecrets:
  - name: registry-auth
YAML
```

## Step 5 — Verify

```bash
# Wait for the pod to be ready
kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready pod/my-app --timeout=120s

# Check status
kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -o wide

# Test the app (if you used the Node.js server)
kubectl --kubeconfig "$KUBECONFIG_PATH" exec my-app -- wget -qO- http://localhost:8080
```

## Architecture Flow

```
Developer (host)
    │
    ▼  skopeo copy (with App Cred)
┌──────────────────────────────────┐
│  Registry VM  (AUTH_PROXY_FIP)  │
│  ┌─────────────────────────┐    │
│  │  Nginx :5000 (public)   │◄──── Auth: /auth/token → JWT
│  │  satisfy any:           │    │
│  │  - Internal IP → allow  │    │
│  │  - External → JWT only │    │
│  └──────┬──────────────────┘    │
│         │ localhost             │
│  ┌──────▼──────┐  ┌──────────┐ │
│  │  Zot :5002  │  │ Token    │ │
│  │  (no auth)  │  │ Service  │──┼──► Keystone (VM_IP)
│  └─────────────┘  └──────────┘ │
└──────────────────────────────────┘
         ▲
         │ INTERNAL_IP:5000 (Nginx — no auth for internal IPs)
┌────────┴───────────────────────┐
│  K3s Cluster                   │
│  master-01 + worker-01         │
│  (imagePullSecret optional)    │
└────────────────────────────────┘
```

## Quick Reference — One-liner Deploy

For a fast demo using nginx:alpine:

```bash
source devstack_env

# 1. Create credential
AJ=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$VM_SSH_KEY" ubuntu@$VM_IP "bash -lc 'source ~/k3s-user-openrc.sh 2>/dev/null; openstack application credential create qd-$(date +%s) --unrestricted -f json'" 2>/dev/null)
AI=$(echo "$AJ" | python3 -c "import sys,json; lines=''.join(sys.stdin); d=json.loads(lines[lines.index('{'):]); print(d.get('id') or d.get('ID'))")
AS=$(echo "$AJ" | python3 -c "import sys,json; lines=''.join(sys.stdin); d=json.loads(lines[lines.index('{'):]); print(d.get('secret') or d.get('Secret'))")

# 2. Push image
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$VM_SSH_KEY" ubuntu@$MASTER_FIP "skopeo copy --dest-username='$AI' --dest-password='$AS' --dest-tls-verify=false docker://docker.io/library/nginx:alpine docker://$AUTH_PROXY_FIP:5000/demo:v1"

# 3. Deploy
IR="${REGISTRY_INTERNAL_IP}:5000"
kubectl --kubeconfig "$KUBECONFIG_PATH" create secret docker-registry reg-auth --docker-server="$IR" --docker-username="$AI" --docker-password="$AS" --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
cat <<YAML | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
apiVersion: v1
kind: Pod
metadata: {name: demo}
spec:
  containers: [{name: app, image: $IR/demo:v1}]
  imagePullSecrets: [{name: reg-auth}]
YAML
kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready pod/demo --timeout=120s && echo "DEPLOYED!"
```
