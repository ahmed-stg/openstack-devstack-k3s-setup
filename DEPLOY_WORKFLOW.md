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

Everything below works without internet: the deploy scripts push the vendored
tarballs from `vendor/` (`make vendor` once). Only the optional "build your own
image" path needs egress.

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

Keep in mind what this credential authorises: Keystone decides *who* you are, and
the token service then signs whatever valid scope the client requests. The token
is checked per request (`repository:<name>:pull|push`), but the credential itself
is not repository-scoped. If you want a hard repository allow-list, set
`ALLOWED_REPOS='my-app,demo-app,rancher/*'` in the token service environment on
the registry VM (glob patterns, comma-separated).

## Step 2 — Push Your Image

Use Skopeo on the Master VM to copy an image into the registry.
The Auth Proxy validates your credentials via Keystone and issues a JWT.

### Option A: Push a vendored tar (air-gapped, no local Docker needed)

The repo ships `vendor/nginx-alpine.tar`, produced once by `make vendor`. Copy it
to the master and push it from disk — no external registry is contacted:

```bash
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -i "$VM_SSH_KEY" vendor/nginx-alpine.tar ubuntu@$MASTER_FIP:~/nginx-alpine.tar

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -i "$VM_SSH_KEY" ubuntu@$MASTER_FIP <<EOF
skopeo copy \
  --dest-username='$APP_ID' \
  --dest-password='$APP_SECRET' \
  --dest-tls-verify=false \
  docker-archive:/home/ubuntu/nginx-alpine.tar:nginx:alpine \
  docker://$AUTH_PROXY_FIP:5000/my-app:v1
rm -f /home/ubuntu/nginx-alpine.tar
EOF
```

Pushing an arbitrary image from Docker Hub still works — replace the source with
`docker://docker.io/library/<image>:<tag>` — but that needs internet egress from
the master and is the one path the air-gap claim does not cover.

### Option B: Push a custom image (Node.js hello-world example)

First, build on the Master VM. `buildah` and the `node:20-alpine` base image are
downloaded here, so this option needs internet (unlike Option A):

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
Nginx enforces authentication for every client, including the cluster nodes, so
the credential is required: nodes read it from `registries.yaml`
(`configs.<internal-ip>.auth`, written by `09`), and pods get it from the
ImagePullSecret below. Neither is optional any more.

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
│  │  Nginx :5000 (public)   │◄──── /auth/token → JWT
│  │  no IP allow-list:      │    │
│  │  every client needs a   │    │
│  │  scoped Bearer token    │    │
│  └──────┬──────────────────┘    │
│         │ localhost             │
│  ┌──────▼──────┐  ┌──────────┐ │
│  │  Zot :5002  │  │ Token    │ │
│  │  (no auth)  │  │ Service  │──┼──► Keystone (VM_IP)
│  └─────────────┘  └──────────┘ │
└──────────────────────────────────┘
         ▲
         │ INTERNAL_IP:5000 (Nginx — nodes auth via registries.yaml)
┌────────┴───────────────────────┐
│  K3s Cluster                   │
│  master-01 + worker-01         │
│  (imagePullSecret required)    │
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

# 2. Push the vendored image (scp the tar first; no docker.io needed)
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$VM_SSH_KEY" vendor/nginx-alpine.tar ubuntu@$MASTER_FIP:~/nginx-alpine.tar
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$VM_SSH_KEY" ubuntu@$MASTER_FIP "skopeo copy --dest-username='$AI' --dest-password='$AS' --dest-tls-verify=false docker-archive:/home/ubuntu/nginx-alpine.tar:nginx:alpine docker://$AUTH_PROXY_FIP:5000/demo:v1 && rm -f /home/ubuntu/nginx-alpine.tar"

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

# 4. Verify the whole platform, independently of these steps
make verify
```
