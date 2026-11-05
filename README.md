# Private Cloud Platform — OpenStack + K3s + authenticated registry

DevStack runs on a single host; inside it, three tenant VMs provide a K3s cluster
and a private OCI registry (Zot) behind an Nginx + Keystone auth proxy. One
command rebuilds the whole stack from a libvirt snapshot.

```
Host ── libvirt ── DevStack VM 192.168.122.79 (OpenStack: Keystone/Nova/Neutron/Cinder)
                      │
                      ├── k3s-master-01   10.10.0.x   K3s server, FIP 192.168.122.20x
                      ├── k3s-worker-01   10.10.0.x   K3s agent,  FIP 192.168.122.20x
                      └── registry-01     10.20.0.x   Nginx :5000 ──► Zot :5002
                                                      └─ /auth/token ──► :5001 ──► Keystone
```

**Contents**

1. [Prerequisites](#1-prerequisites)
2. [Quick start (existing snapshot)](#2-quick-start-existing-snapshot)
3. [Set up from scratch](#3-set-up-from-scratch)
4. [What the automation builds](#4-what-the-automation-builds)
5. [Push an image and deploy it](#5-push-an-image-and-deploy-it)
6. [Security model](#6-security-model)
7. [Verification and linting](#7-verification-and-linting)
8. [Troubleshooting](#8-troubleshooting)
9. [Known limitations](#9-known-limitations)
10. [Configuration](#10-configuration)
11. [Project structure](#11-project-structure)
12. [Further reading](#12-further-reading)

---

## 1. Prerequisites

| Requirement | Details |
|---|---|
| **OS** | Debian 12/13 or Ubuntu 22.04+ with KVM support |
| **RAM** | 16 GB minimum (the DevStack VM alone takes 16 GB) |
| **Disk** | 100 GB free (80 GB for the VM + overhead) |
| **CPU** | 6+ cores with VT-x/AMD-V |
| **SSH key** | `~/.ssh/id_ed25519` (configurable in `config.env`) |

```bash
sudo apt update
sudo apt install -y libvirt-daemon-system qemu-kvm virtinst genisoimage curl python3
sudo usermod -aG libvirt "$USER"     # log out and back in
```

---

## 2. Quick start (existing snapshot)

Requires a DevStack VM with the `PostStack_Ready` snapshot (see §3 for the
one-time setup).

```bash
git clone <repo-url> && cd final
make vendor            # one-time, needs internet: the two demo images
make vendor-tools      # one-time, needs internet: shellcheck for `make lint`

sudo bash XX_RUN_FROM_SNAPSHOT.sh   # revert + reset + steps 03-12 (~7 min here)
make verify                         # independent, read-only checks

source devstack_env
curl "$PROD_APP_URL"    # nginx:alpine
curl "$DEMO_APP_URL"    # busybox httpd
```

`make vendor` and `make vendor-tools` are the only internet accesses in the
whole flow. After that, deploys are air-gapped: scripts `11` and `12` push the
tarballs in `vendor/` instead of pulling from Docker Hub.

---

## 3. Set up from scratch

### 3.1 Download the large binaries (not in git)

```bash
cd final

wget -O noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img   # ~700 MB
wget -O k3s https://github.com/k3s-io/k3s/releases/download/v1.31.1+k3s1/k3s      # ~68 MB
wget -O k3s-airgap-images-amd64.tar \
  https://github.com/k3s-io/k3s/releases/download/v1.31.1+k3s1/k3s-airgap-images-amd64.tar
wget -O zot-linux-amd64 \
  https://github.com/project-zot/zot/releases/download/v2.1.16/zot-linux-amd64    # ~219 MB
chmod +x k3s zot-linux-amd64

make vendor && make vendor-tools
```

### 3.2 Create the VM and install DevStack

```bash
./01_create_vm.sh    # libvirt VM: 16 GB RAM, 6 vCPU, 80 GB, 2 NICs, cloud-init
./02_init_vm.sh      # prep the VM, clone DevStack, copy local.conf
```

`02` stops before the installer; DevStack must be stacked manually (20-40 min):

```bash
source devstack_env
ssh "ubuntu@$VM_IP"
cd ~/devstack && ./stack.sh
# verify inside the VM:
source ~/devstack/openrc admin admin && openstack service list
```

### 3.3 Snapshot the working state (one-time)

Every later run reverts to this snapshot, so take it once DevStack is healthy:

```bash
sudo virsh shutdown BaseDevStack
sudo virsh snapshot-create-as --domain BaseDevStack \
  --name "PostStack_Ready" \
  --description "DevStack installed, ready for tenant setup"
sudo virsh start BaseDevStack
```

### 3.4 Run the automation

```bash
sudo bash XX_RUN_FROM_SNAPSHOT.sh
```

To run a single step (order matters):

```bash
source devstack_env
./03_openstack_bootstrap.sh 2>&1 | tee 03.log
# ...
./12_demo_deploy.sh         2>&1 | tee 12.log
```

---

## 4. What the automation builds

| Step | Script | Result |
|---|---|---|
| 03 | `03_openstack_bootstrap.sh` | project + user, quotas, 2 tenant networks + router, `Ubuntu24` image, keypair, `auth-proxy-system` app credential |
| 04 | `04_k3s_master_vm.sh` | `k3s-master-01`, security group, floating IP, host route, `br-ex` config |
| 05 | `05_registry_vm.sh` | `registry-01` + 20 GB Cinder volume + floating IP |
| 06 | `06_zot_install.sh` | Zot binary, volume formatted/mounted, systemd unit, airgap images imported |
| 07 | `07_auth_proxy_vm.sh` | no VM: aliases `AUTH_PROXY_*` to the registry VM |
| 08 | `08_auth_proxy_install.sh` | RSA keypair, `lib/token_service.py`, Zot moved to `127.0.0.1:5002`, Nginx on `:5000` |
| 09 | `09_k3s_cluster_install.sh` | `k3s-worker-01`, K3s server/agent, `registries.yaml` (mirrors + `configs.<ip>.auth`), kubeconfig |
| 10 | `10_registry_smoke_test.sh` | Nginx auth enforcement, 7 hard gates + catalog check |
| 11 | `11_enable_zot_auth.sh` | deploy credential, push `my-app:v1` from the vendored tar, pod `prod-app` |
| 12 | `12_demo_deploy.sh` | NodePort services, push `demo-app:v1`, curl both apps from the host |
| 99 | `99_teardown.sh` | destroys everything in dependency order (dry-run by default) |

Why the stack looks like this, per-step internals and the design decisions are in
**[ARCHITECTURE.md](ARCHITECTURE.md)**.

---

## 5. Push an image and deploy it

```bash
source devstack_env
echo "$AUTH_PROXY_FIP"        # registry + auth proxy (external)
echo "$REGISTRY_INTERNAL_IP"  # what the K3s nodes pull from
echo "$KUBECONFIG_PATH"       # k3s-kubeconfig.yaml
```

> **No TLS.** `nginx:5000` and Zot speak plain HTTP, so the application
> credential, the JWTs and the image blobs cross the network in cleartext, and
> clients must pass `--dest-tls-verify=false`. That is acceptable only because
> this runs on a host-local libvirt network; see §6.

### 5.1 Create an application credential

Each deployment gets its own Keystone application credential — the "robot
account" the cluster uses to pull:

```bash
APP_CRED_JSON=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$VM_SSH_KEY" "ubuntu@$VM_IP" \
  "bash -lc 'source ~/k3s-user-openrc.sh 2>/dev/null; \
   openstack application credential create my-deploy-$(date +%s) --unrestricted -f json'" 2>/dev/null)

APP_ID=$(echo "$APP_CRED_JSON"     | python3 -c "import sys,json; s=''.join(sys.stdin); d=json.loads(s[s.index('{'):]); print(d.get('id'))")
APP_SECRET=$(echo "$APP_CRED_JSON" | python3 -c "import sys,json; s=''.join(sys.stdin); d=json.loads(s[s.index('{'):]); print(d.get('secret'))")
```

Keystone decides *who* you are; the token service then signs the scope the client
asks for. The **token** is checked per request (`repository:<name>:pull|push`),
the **credential** is not repository-scoped. For a hard allow-list, set
`ALLOWED_REPOS='my-app,demo-app,rancher/*'` in the token service environment on
the registry VM.

### 5.2 Push

From the master, using the vendored tarball (no external registry contacted):

```bash
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -i "$VM_SSH_KEY" vendor/nginx-alpine.tar "ubuntu@$MASTER_FIP:~/nginx-alpine.tar"

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -i "$VM_SSH_KEY" "ubuntu@$MASTER_FIP" <<EOF
skopeo copy --dest-username='$APP_ID' --dest-password='$APP_SECRET' \
  --dest-tls-verify=false \
  docker-archive:/home/ubuntu/nginx-alpine.tar:nginx:alpine \
  docker://$AUTH_PROXY_FIP:5000/my-app:v1
rm -f /home/ubuntu/nginx-alpine.tar
EOF
```

An arbitrary image works the same way with `docker://docker.io/library/<image>:<tag>`
as the source — but that needs egress from the master, outside the air-gap claim.
To build your own image, use `buildah` on the master (also needs internet for the
base image), then `buildah push --tls-verify=false --creds=$APP_ID:$APP_SECRET
my-app:v1 docker://$AUTH_PROXY_FIP:5000/my-app:v1`.

### 5.3 ImagePullSecret

Nodes read the credential from `registries.yaml` (`configs.<ip>.auth`, written by
`09`); pods get it from the secret below. Neither is optional: Nginx
authenticates every client, including in-cluster ones.

```bash
IR="${REGISTRY_INTERNAL_IP}:5000"
kubectl --kubeconfig "$KUBECONFIG_PATH" create secret docker-registry registry-auth \
  --docker-server="$IR" --docker-username="$APP_ID" --docker-password="$APP_SECRET" \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
```

### 5.4 Deploy and check

```bash
cat <<YAML | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  labels: { app: my-app }
spec:
  containers:
  - name: app
    image: ${IR}/my-app:v1
  imagePullSecrets:
  - name: registry-auth
YAML

kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready pod/my-app --timeout=120s
kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -o wide
```

To expose it from the host, add a `NodePort` Service (selector `app: my-app`)
and open TCP 30000-32767 in the node security groups — exactly what `12` does
for the two demo apps.

---

## 6. Security model

**No IP exemption.** Authorisation is a Bearer token with a scope; a packet from
`10.10.0.0/24` needs one exactly like a packet from the host. Security groups
decide *reachability* only.

| Client | Authenticates with | May do |
|---|---|---|
| External (host, CI) | Basic app credential → `/auth/token` → Bearer | only the requested scopes, re-checked against `access` on every request |
| K3s node (containerd) | `registries.yaml` `configs.<ip>.auth` | pull mirrored repositories (one token per pull) |
| Pod | imagePullSecret | same as the node, for its own image |
| Anonymous | — | 401 on every `/v2/` request |

The validator checks signature, `iss`, `aud`, `nbf`, `exp` **and** that `access`
grants `repository:<name>:<pull|push>` for the actual request (Nginx forwards
`X-Original-URI`/`X-Original-Method`, because `auth_request` subrequests are
always `GET`). Malformed scopes are rejected with 400, denials are logged.

**Cleartext, by design.** There is no TLS on the registry: `nginx:5000` serves
plain HTTP and every client passes `--dest-tls-verify=false`. Credentials,
tokens and image layers are unencrypted on the wire. This is tolerable only on
the isolated libvirt host network; anything reachable beyond it needs TLS
termination first.

Remaining risks and the deferred work around them are listed in §9.

---

## 7. Verification and linting

```bash
make lint     # bash -n + shellcheck 0.10.0 + py_compile, no lab needed
make verify   # read-only checks against the running lab
```

`hooks/pre-commit` runs the linter once you enable it:

```bash
git config core.hooksPath hooks
```

`verify.sh` deliberately ignores `03.log`…`12.log` — a green log can hide a
broken deployment, so it re-derives everything from the live system:

- host `curl` of both NodePort apps → 200
- K3s nodes `Ready` 2/2, both pods `Running` and `Ready`
- cross-node pod→pod traffic in both directions (VXLAN actually works)
- the worker security group rule that permits it
- registry behaviour: no token → 401, token issued, scoped pull → 200,
  pull-only token rejected on push, all 8 mirrored images present
- both pods really run images from the private registry
- no `000000` artefacts in the recorded logs

**Latest results**

| Check | Result |
|---|---|
| `./ci/lint.sh` (22 scripts + 1 python file) | clean |
| `10_registry_smoke_test.sh` T1-T7 + catalog | all PASS |
| `11.log` / `12.log` `docker.io` occurrences | 0 / 0 |
| `./verify.sh` | 18 passed, 0 failed |
| clean `XX_RUN_FROM_SNAPSHOT.sh` from `PostStack_Ready` | `EXIT=0`, steps 03-12 all green (6 min 19 s), followed by 18/0 on `verify.sh` |

---

## 8. Troubleshooting

**`No valid host was found`** (Nova placement) — the hypervisor is out of disk
(`ds1G` needs ~10 GB free):

```bash
source devstack_env
ssh "ubuntu@$VM_IP" "bash -lc 'source ~/devstack/openrc admin admin; openstack hypervisor stats show -f json'"
```

**`REMOTE HOST IDENTIFICATION HAS CHANGED`** — stale key from a previous VM:

```bash
ssh-keygen -f ~/.ssh/known_hosts -R 192.168.122.204
```

**`stack.sh` fails** — check the Python version (3.10-3.12), AppArmor blocking
libvirt (`sudo aa-complain /usr/sbin/libvirtd`), and free disk (~30 GB needed).

**Pod stuck in `ImagePullBackOff`** — check `kubectl describe pod <name>`:

| Symptom | Cause / fix |
|---|---|
| `server gave HTTP response to HTTPS client` | `registries.yaml` lacks the explicit `mirrors."<registry-ip>:5000"` entry, so k3s generated an https-only `certs.d/.../hosts.toml`. Re-run `09` (a `*` wildcard does not apply to a directly-referenced host). |
| `501 Unsupported method POST` | stale token service on the registry VM; `lib/token_service.py` handles POST — re-run `08`. |
| `authentication required` | wrong credential in the imagePullSecret or `registries.yaml`; nothing is exempt from auth, so recreate the rotated credential. |
| `401 ... scope does not grant` in `journalctl -u token-service` | the JWT's `access` claim does not cover this repo/action — mint the token with `repository:<name>:pull` (or `:push`). |

**Floating IPs unreachable from the host** — a host route is required:

```bash
source devstack_env
sudo ip route replace 192.168.122.200/29 via "$VM_IP"
```

---

## 9. Known limitations

This is a learning platform, not production. Honest accounting:

| Limitation | Impact | Mitigation |
|---|---|---|
| **HTTP-only registry** | credentials, JWTs, image data in cleartext (§6) | terminate TLS at Nginx and drop `--dest-tls-verify=false`; or keep it host-local |
| **JWT signing key on disk** | VM compromise leaks the signer | secrets manager / HSM in production |
| **App credential in a K8s Secret** | anyone with `get secrets` can extract it | short-lived tokens or a credential operator |
| **No K8s RBAC / network policies** | any pod can reach the API | Pod Security Standards + NetworkPolicy |
| **Credential can mint any scope** | the token is scoped, the credential is not | `ALLOWED_REPOS` allow-list in the token service |
| **No rate limit / revocation on `/auth/token`** | brute force is possible | put an OAuth2/OIDC provider in front |
| **No image signing** | any push can be deployed | cosign / Notary |
| **One SSH key everywhere** | one key compromise opens everything | per-role keys, bastion |
| **DevStack admin password in `local.conf`** | it is DevStack's documented sample default, not a leak; the tenant openrc is generated at runtime and gitignored | change all four passwords for anything real |
| **Teardown never executed** | `99_teardown.sh` is written and reviewed but untested against a live stack | run it with no flags first (dry-run), then `--yes` under supervision |
| **Nested virtualisation is slow, no monitoring, single VM per role** | build/pull latency, silent failures, SPOF | accept for a demo; Prometheus + HA for real |

Network-specific weaknesses (asymmetric routing / `rp_filter`, MTU, tiny floating
IP range, permissive security groups, double encapsulation, no registry DNS) and
their fixes are in **[NETWORKING.md](NETWORKING.md)**.

**Deferred work** — deliberately not done:

- TLS on the registry (see above).
- `chmod 600` on the JWT key, rate limiting, token revocation.
- Reproducibility: pre-seed the 629 MB cloud image into the snapshot so `03`
  stops re-uploading it; an idempotency sweep (`03`→`12` twice without revert);
  per-step timings in the `XX_` summary.
- `kubeconform` over the rendered manifests.

**Run history**

| Run | Result |
|---|---|
| token service unit tests (22 pure-function + 7 HTTP) | 22/22, 7/7 pass |
| `verify.sh` on the pre-hardening lab | 17 passed, 1 failed — caught a pull-only token accepted on push |
| `verify.sh` on the hardened lab | 18 passed, 0 failed |
| clean `XX_RUN_FROM_SNAPSHOT.sh` from `PostStack_Ready` | `EXIT=0` in 6 min 19 s: 03-12 all green, T1-T7 pass, both apps 200, `verify.sh` 18/0 afterwards |
| `hosts.toml` written by that run's `09` | contains the `http://` fallback, so the pod pulled through the authenticated registry on the first try |

---

## 10. Configuration

**`config.env`** — VM hardware:

```bash
export VM_NAME="BaseDevStack"
export VM_RAM=16284       # MB
export VM_VCPUS=6
export DISK_SIZE="80G"
export SSH_KEY_PUB="$HOME/.ssh/id_ed25519.pub"
export K3S_BINARY="./k3s"
export K3S_AIRGAP_IMAGES="./k3s-airgap-images-amd64.tar"
export WORKER_COUNT=1
```

**`local.conf`** — DevStack: `LIBVIRT_TYPE=kvm`,
`FLOATING_RANGE=192.168.122.200/29` (6 usable IPs),
`PUBLIC_INTERFACE=enp2s0`, `ENABLED_SERVICES` = Keystone, Nova, Neutron (OVN),
Cinder, Glance, Placement.

**`devstack_env`** — runtime state (IPs, credentials) persisted by the scripts.
Do not edit; reset it with `XX_reset_rerun_state.sh` or by reverting the snapshot.

---

## 11. Project structure

```
final/
├── 01_create_vm.sh            # libvirt VM for DevStack
├── 02_init_vm.sh              # prep the VM, transfer local.conf
├── 03_openstack_bootstrap.sh  # project, networks, quotas, keypair, app credential
├── 04_k3s_master_vm.sh        # K3s master VM + floating IP + host route
├── 05_registry_vm.sh          # registry VM + Cinder volume + floating IP
├── 06_zot_install.sh          # Zot, volume, systemd, airgap image import
├── 07_auth_proxy_vm.sh        # alias AUTH_PROXY_* to the registry VM (no 4th VM)
├── 08_auth_proxy_install.sh   # Nginx, token service, Zot on loopback
├── 09_k3s_cluster_install.sh  # worker VM, K3s server/agent, registries.yaml auth
├── 10_registry_smoke_test.sh  # auth enforcement + 7 hard gates
├── 11_enable_zot_auth.sh      # push vendored nginx tar, deploy prod-app
├── 12_demo_deploy.sh          # NodePort services, vendored busybox, curl from host
├── 99_teardown.sh             # destroy the lab (dry-run default; never executed)
├── XX_RUN_FROM_SNAPSHOT.sh    # revert + reset + steps 03-12
├── XX_revert_to_snapshot.sh   # virsh snapshot revert
├── XX_reset_rerun_state.sh    # reset env vars, clean artifacts
├── verify.sh                  # independent read-only verification
├── Makefile                   # lint / vendor / vendor-tools / run / verify / teardown
├── ci/lint.sh                 # bash -n + shellcheck + py_compile
├── ci/containers-policy.json  # skopeo copy policy
├── hooks/pre-commit           # runs ci/lint.sh (core.hooksPath=hooks)
├── lib/common.sh              # SSH/OpenStack helpers, wait loops
├── lib/token_service.py       # token service, single source (installed by 08)
├── README.md                  # this file
├── ARCHITECTURE.md            # design, per-step internals, decisions, lessons
├── NETWORKING.md              # network layers, data flows, network flaws
├── config.env                 # VM hardware settings
├── local.conf                 # DevStack configuration
├── devstack_env               # runtime state (generated, gitignored)
├── configure_br_ex.sh         # OVS bridge / routing inside the DevStack VM
├── import_images.sh           # skopeo airgap image import
├── source_env.sh              # source devstack_env helper
├── scp-safe / ssh-safe        # SSH wrappers that bypass known_hosts
└── vendor/                    # gitignored: offline binaries + demo image tars
```

---

## 12. Further reading

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — component design, what each step does
  internally, authorisation flow, design decisions and lessons learned.
- **[NETWORKING.md](NETWORKING.md)** — every network layer from `virbr0` to
  VXLAN, three data-flow walkthroughs, network flaws and their fixes.

References: [DevStack](https://docs.openstack.org/devstack/latest/),
[K3s](https://docs.k3s.io/), [Zot](https://github.com/project-zot/zot),
[Keystone application credentials](https://docs.openstack.org/keystone/latest/user/application_credentials.html),
[Registry auth spec](https://distribution.github.io/distribution/spec/auth/).
