# Private Cloud Platform — OpenStack + K3s + Auth Proxy

A fully automated private cloud platform built on a single machine:
**OpenStack** (IaaS) → **K3s** (Kubernetes) → **Zot** (private registry) → **Keystone-authenticated deploys**.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **OS** | Debian 12/13 or Ubuntu 22.04+ with KVM support |
| **RAM** | 16 GB minimum (DevStack VM uses 16 GB) |
| **Disk** | 100 GB free (80 GB for the VM + overhead) |
| **CPU** | 6+ cores with VT-x/AMD-V |
| **Packages** | `libvirt-bin`, `qemu-kvm`, `virtinst`, `genisoimage`, `curl`, `python3` |
| **SSH Key** | `~/.ssh/id_ed25519` (or edit `config.env`) |

Install host dependencies:

```bash
sudo apt update
sudo apt install -y libvirt-daemon-system qemu-kvm virtinst genisoimage curl python3
sudo usermod -aG libvirt $USER
# Log out and back in for group change to take effect
```

---

## Quick Start (from snapshot)

If you already have a DevStack VM with the `PostStack_Ready` snapshot:

```bash
git clone <repo-url> && cd final
make vendor            # one-time: fetch the two demo images (needs internet)
make vendor-tools      # one-time: fetch shellcheck for `make lint`
sudo bash XX_RUN_FROM_SNAPSHOT.sh
make verify            # independent read-only checks against the running lab
```

This reverts the VM, resets all state, and runs scripts 03-12 automatically.
When it finishes, your apps are live and reachable from the host — see `DEPLOY_WORKFLOW.md` for more.

---

## Full Setup (from scratch)

### Step 0 — Download required binaries

These files are too large for git. Download them into the project directory:

```bash
cd final

# Ubuntu 24.04 cloud image (~700 MB)
wget -O noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# K3s binary (~68 MB)
wget -O k3s https://github.com/k3s-io/k3s/releases/download/v1.31.1+k3s1/k3s
chmod +x k3s

# K3s airgap images (~182 MB)
wget -O k3s-airgap-images-amd64.tar \
  https://github.com/k3s-io/k3s/releases/download/v1.31.1+k3s1/k3s-airgap-images-amd64.tar

# Zot registry binary (~219 MB)
wget -O zot-linux-amd64 \
  https://github.com/project-zot/zot/releases/download/v2.1.16/zot-linux-amd64
chmod +x zot-linux-amd64

# Demo images, vendored as docker-archive tarballs (~66 MB total).
# This is the only internet access the demo needs; after this the deploy
# scripts never contact docker.io.
make vendor

# ShellCheck static binary for `make lint` (~2.5 MB). The apt package needs
# sudo; like the other tools, it is vendored instead.
make vendor-tools
```

The demo deploy is air-gapped: `11` and `12` push `vendor/nginx-alpine.tar`
and `vendor/busybox.tar` from disk instead of pulling from Docker Hub.

### Step 1 — Create the DevStack VM

```bash
./01_create_vm.sh
```

This creates a libvirt VM (16 GB RAM, 6 vCPU, 80 GB disk) with two NICs,
cloud-init for SSH key injection, and writes `VM_IP` to `devstack_env`.

### Step 2 — Install DevStack (partially manual)

```bash
./02_init_vm.sh
```

This preps the VM (DNS, interfaces, clones DevStack, transfers `local.conf`).
**Then you must run the DevStack installer manually** (it takes 20-40 minutes):

```bash
source devstack_env
ssh ubuntu@$VM_IP
cd ~/devstack
./stack.sh
```

Wait for it to finish. Verify:

```bash
source ~/devstack/openrc admin admin
openstack service list   # should show Keystone, Nova, Neutron, Cinder
```

### Step 2.5 — Create the snapshot (manual, one-time)

After DevStack installs successfully, create a snapshot so you can revert later:

```bash
sudo virsh shutdown BaseDevStack
sudo virsh snapshot-create-as --domain BaseDevStack \
  --name "PostStack_Ready" \
  --description "DevStack installed, ready for tenant setup"
sudo virsh start BaseDevStack
```

### Step 3-12 — Run the automation

From this point, everything is automated:

```bash
sudo bash XX_RUN_FROM_SNAPSHOT.sh
```

Or run each step individually:

```bash
source devstack_env
./03_openstack_bootstrap.sh 2>&1 | tee 03.log
./04_k3s_master_vm.sh       2>&1 | tee 04.log
./05_registry_vm.sh          2>&1 | tee 05.log
./06_zot_install.sh         2>&1 | tee 06.log
./07_auth_proxy_vm.sh       2>&1 | tee 07.log
./08_auth_proxy_install.sh  2>&1 | tee 08.log
./09_k3s_cluster_install.sh 2>&1 | tee 09.log
./10_registry_smoke_test.sh 2>&1 | tee 10.log
./11_enable_zot_auth.sh     2>&1 | tee 11.log
./12_demo_deploy.sh         2>&1 | tee 12.log
```

### Deploy your first app

Apps are already exposed by script 12. To curl them:

```bash
source devstack_env
curl $PROD_APP_URL    # nginx:alpine
curl $DEMO_APP_URL    # busybox httpd
```

See **[DEPLOY_WORKFLOW.md](DEPLOY_WORKFLOW.md)** for the full push-to-deploy guide.

---

## Verification & Linting

```bash
make lint     # bash -n + shellcheck + py_compile over every tracked script
make verify   # read-only checks against the live lab
```

`make lint` needs no lab and finishes in seconds; `hooks/pre-commit` calls it once
you enable `git config core.hooksPath hooks`. `verify.sh` deliberately does not read
`03.log`…`12.log`: it re-derives every claim from the running system (both apps
200, nodes 2/2, VXLAN both directions, 401/200/scope-rejection on the registry,
all 8 mirrored images), so a green log cannot hide a broken deployment.

---

## Project Structure

```
final/
├── 01_create_vm.sh            # Create libvirt VM
├── 02_init_vm.sh              # Prep VM for DevStack
├── 03_openstack_bootstrap.sh  # Project, networks, quotas, keypair
├── 04_k3s_master_vm.sh        # K3s master VM + floating IP
├── 05_registry_vm.sh          # Registry VM + Cinder volume + FIP
├── 06_zot_install.sh          # Install Zot, format volume, import images
├── 07_auth_proxy_vm.sh        # Alias AUTH_PROXY_* to the registry VM (no 4th VM)
├── 08_auth_proxy_install.sh   # Nginx + token service; Zot moved to loopback
├── 09_k3s_cluster_install.sh  # Worker VM, K3s server/agent, registries.yaml auth
├── 10_registry_smoke_test.sh  # Nginx auth enforcement + 7 hard gates
├── 11_enable_zot_auth.sh      # Push the vendored nginx tar, deploy a pod
├── 12_demo_deploy.sh          # NodePort services, push the vendored busybox
├── 99_teardown.sh             # Destroy the lab (dry-run default; untested by design)
├── XX_RUN_FROM_SNAPSHOT.sh    # Revert + reset + full stack (03-12)
├── XX_revert_to_snapshot.sh   # virsh snapshot revert
├── XX_reset_rerun_state.sh    # Reset env vars + clean artifacts
├── verify.sh                  # Independent, read-only verification of the live lab
├── Makefile                   # make lint / vendor / run / verify / teardown
├── ci/lint.sh                 # bash -n + shellcheck + py_compile over tracked files
├── hooks/pre-commit           # Runs ci/lint.sh (git config core.hooksPath hooks)
├── DEPLOY_WORKFLOW.md         # Push-to-deploy user guide
├── ARCHITECTURE.md            # Detailed technical writeup
├── NETWORKING.md              # Networking deep dive + improvement roadmap
├── TODO.md                    # Prioritised hardening plan and status
├── config.env                 # Base VM config (RAM, vCPUs)
├── devstack_env               # Runtime state (IPs, credentials)
├── local.conf                 # DevStack configuration
├── lib/common.sh              # Shared functions (SSH, OpenStack wrappers)
├── lib/token_service.py       # Token service, single source (installed by 08)
├── configure_br_ex.sh         # OVS bridge setup on DevStack VM
├── import_images.sh           # Skopeo airgap image import
├── scp-safe / ssh-safe        # SSH wrappers (bypass known-hosts)
├── source_env.sh              # Source devstack_env helper
└── vendor/                    # Ignored: offline binaries + the two demo tars
```

---

## Configuration

### `config.env` — VM hardware settings

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

### `local.conf` — DevStack settings

Key values:
- `LIBVIRT_TYPE=kvm` — uses KVM (change to `qemu` if no hardware virtualization)
- `FLOATING_RANGE=192.168.122.200/29` — 6 floating IPs
- `PUBLIC_INTERFACE=enp2s0` — second NIC for br-ex
- `ENABLED_SERVICES` — Keystone, Nova, Neutron (OVN), Cinder, Glance, Placement

### `devstack_env` — Runtime state (auto-generated)

Do not edit manually. Scripts persist IPs, tokens, and credentials here.
Reset with `XX_reset_rerun_state.sh` or `XX_RUN_FROM_SNAPSHOT.sh`.

---

## Known Issues & Security Flaws

This project is a **learning/demo platform**. Several shortcuts were taken
that would be unacceptable in production. Here's an honest accounting:

### Security

| Issue | Severity | Details |
|-------|----------|---------|
| **HTTP-only registry** | High | Nginx and Zot listen on plain HTTP. All credentials and image data travel unencrypted. In production, add TLS termination (Let's Encrypt or self-signed certs with `--dest-tls-verify=false` removed). |
| **JWT secret on disk** | Medium | The RSA private key (`auth-proxy-jwt.pem`) is stored on the registry VM's filesystem. A VM compromise leaks the signing key. In production, use a secrets manager or HSM. |
| **Application Credential in K8s Secret** | Medium | The Keystone app credential is stored as a K8s `imagePullSecret`. Anyone with `kubectl get secrets` can extract it. In production, use short-lived tokens or a credential operator. |
| **No RBAC on K8s** | Medium | The K3s cluster runs with default RBAC. Any pod can access the Kubernetes API. In production, apply Pod Security Standards and network policies. |
| **DevStack admin password in plaintext** | Medium | `local.conf` contains `ADMIN_PASSWORD=nomoresecret`, which is DevStack's documented sample default, not a leaked secret. The tenant `k3s-user-openrc.sh` is generated on the DevStack VM at runtime and gitignored. In production, use Keystone tokens with expiry. |
| **SSH key reuse** | Low | The same SSH key is used for the DevStack VM, all tenant VMs, and the OpenStack keypair. Compromise of one key compromises everything. |
| **No image signing/verification** | Low | Zot accepts any pushed image without signature verification. A compromised push could deploy malicious code. Use cosign or Notary for image signing. |
| **Token service is a single Python script** | Low | It validates signature, `iss`, `aud`, `nbf`, `exp` and the `access` scope, and logs every denial, but has no rate limiting, no request audit trail and no token revocation. A brute-force attack on `/auth/token` is still possible. In production, use a proper OAuth2/OIDC provider. |
| **Credential can mint any scope** | Medium | Once Keystone accepts an application credential, `/auth/token` will sign whatever valid scope the client asks for. The token is checked on use, but the *credential* is not repository-scoped. Mitigation: set `ALLOWED_REPOS` (globs, e.g. `my-app,demo-app,rancher/*`) in the token service environment. |

### Logistical / Operational

| Issue | Impact | Mitigation |
|-------|--------|------------|
| **Nova placement failures** | Worker VMs may fail to schedule if disk is full. The `ds1G` flavor (10 GB disk) is a tight fit. | Monitor hypervisor disk with `openstack hypervisor stats show`. Use smaller images or increase host disk. |
| **Floating IP exhaustion** | Only 6 floating IPs in `192.168.122.200/29`. Each VM needs one. | Expand `FLOATING_RANGE` in `local.conf` before running DevStack (requires re-stack). |
| **No persistence across reboots** | DevStack is not designed for reboot survival. The VM must be snapshotted. | Always `sudo virsh snapshot-create-as` after a working state. Revert on failure. |
| **Nested virtualization is slow** | Tenant VMs run as QEMU-inside-QEMU. Build times and image pulls are noticeably slower than bare-metal. | Use `LIBVIRT_TYPE=kvm` if the host supports it. Accept the latency for a demo. |
| **br-ex must be reconfigured after revert** | The OVS bridge loses its IP on snapshot revert. Script `04` handles this automatically via `configure_br_ex.sh`. | If manual intervention is needed: `sudo ip addr add 192.168.122.201/29 dev br-ex` inside the DevStack VM. |
| **MTU issues with VXLAN** | OpenStack's default MTU is 1450 (VXLAN overhead). Large Docker pushes may time out. | Set `DOCKER_CLIENT_MTU=1450` or configure Neutron with `segment_mtu`. |
| **Single point of failure** | One DevStack VM, one registry VM. If either dies, the entire platform is down. | In production: HA DevStack (3 controllers), replicated registry, load-balanced auth proxy. |
| **No monitoring or alerting** | There is no Prometheus, Grafana, or logging stack. Failures are silent. | Add the K3s monitoring chart or deploy Prometheus Operator after step 11. |
| **Teardown script is untested** | `99_teardown.sh` deletes everything in dependency order and is dry-run by default, but it was written and reviewed without ever being run against a live stack. | Run `./99_teardown.sh` first (lists resources), then `./99_teardown.sh --yes` under supervision. |

---

## Troubleshooting

### `No valid host was found` (Nova placement error)

The hypervisor doesn't have enough disk. Check:
```bash
source devstack_env
ssh ubuntu@$VM_IP "bash -lc 'source ~/devstack/openrc admin admin; openstack hypervisor stats show -f json'"
```
Free disk must be > 10 GB for a `ds1G` worker. Delete failed servers:
```bash
ssh ubuntu@$VM_IP "bash -lc 'source ~/k3s-user-openrc.sh; openstack server list -f value -c Name -c Status'"
```

### SSH `REMOTE HOST IDENTIFICATION HAS CHANGED`

Stale known_hosts entries from previous VMs. Fix:
```bash
ssh-keygen -f ~/.ssh/known_hosts -R 192.168.122.204  # or whichever IP
```
Or use the cleanup in `XX_RUN_FROM_SNAPSHOT.sh` which clears the whole range.

### DevStack `stack.sh` fails

Common causes:
- **Python version mismatch**: DevStack needs Python 3.10-3.12. Check with `python3 --version`.
- **AppArmor blocking libvirt**: `sudo aa-complain /usr/sbin/libvirtd` on the host.
- **Disk full**: DevStack needs ~30 GB free. Check with `df -h` inside the VM.

### Pod stuck in `ImagePullBackOff`

Check the pod events:
```bash
kubectl --kubeconfig k3s-kubeconfig.yaml describe pod <name>
```
Common causes:
- **501 Unsupported method POST**: the token service needs its `do_POST` handler. It lives in `lib/token_service.py` (installed by `08`); re-run `08` if the copy on the registry VM is stale.
- **`ImagePullBackOff` + `server gave HTTP response to HTTPS client`**: `registries.yaml` is missing the explicit `mirrors."<registry-ip>:5000"` entry. A `*` wildcard does not apply to a directly-referenced registry host, so k3s generated an https-only `certs.d/.../hosts.toml`. Re-run `09` (or add the mirror and restart `k3s`/`k3s-agent`).
- **authentication required**: The credential in `registries.yaml` (nodes) or the imagePullSecret (pods) is wrong. There is no IP allow-list: in-cluster pulls authenticate with the application credential exactly like external clients. Recreate the secret/credential if it was rotated.
- **401 with `deny ... scope does not grant`** in `journalctl -u token-service`: the JWT's `access` claim does not cover this repository/action. Mint the token with the right scope (`repository:<name>:pull` or `:push`); a pull token can never push.
- **unknown**: Registry may be unreachable from the worker. Check security groups (reachability) — but note that security groups no longer imply authorisation.

### Cannot reach floating IPs from host

You need a host route:
```bash
source devstack_env
sudo ip route replace 192.168.122.200/29 via $VM_IP
```

---

## References

- [DevStack Documentation](https://docs.openstack.org/devstack/latest/)
- [K3s Documentation](https://docs.k3s.io/)
- [Zot Registry](https://github.com/project-zot/zot)
- [OpenStack Application Credentials](https://docs.openstack.org/keystone/latest/user/application_credentials.html)
- [Docker Registry Auth Spec](https://distribution.github.io/distribution/spec/auth/)
