# Architecture

How the platform is put together: the components, what each script does
internally, and why the design ended up this way. Read
**[README.md](README.md)** first for the pitch, the quick start and the security
model; networking has its own document, **[NETWORKING.md](NETWORKING.md)**.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Host Machine (192.168.122.0/24)                               │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │  DevStack VM  "BaseDevStack"  (192.168.122.79)           │ │
│  │  16 GB RAM | 6 vCPU | 80 GB disk                         │ │
│  │                                                           │ │
│  │  OpenStack Services:                                      │ │
│  │  ├── Keystone (Identity)                                  │ │
│  │  ├── Nova (Compute) — libvirt/QEMU driver                │ │
│  │  ├── Neutron (Networking) — OVS + br-ex                   │ │
│  │  └── Cinder (Block Storage) — LVM backend                 │ │
│  │                                                           │ │
│  │  Tenant VMs (nested KVM):                                 │ │
│  │                                                           │ │
│  │  ┌─────────────────┐  ┌────────────────────────────────┐  │ │
│  │  │ k3s-master-01  │  │ registry-01 (also Auth Proxy)  │  │ │
│  │  │ m1.medium       │  │ m1.small                       │  │ │
│  │  │ 4GB / 2 vCPU    │  │ 2GB / 1 vCPU + 20GB Cinder    │  │ │
│  │  │                 │  │                                │  │ │
│  │  │ K3s Server      │  │ ┌─ Nginx :5000 (public) ───┐ │  │ │
│  │  │ (control plane) │  │ │  /auth/token → :5001      │ │  │ │
│  │  │                 │  │ │  /v2/*      → :5002 (Zot) │ │  │ │
│  │  │ FIP: .204       │  │ └───────────────────────────┘ │  │ │
│  │  │ Int: 10.10.0.x  │  │ FIP: .205                     │  │ │
│  │  └────────┬────────┘  │ Int: 10.20.0.x                │  │ │
│  │           │            └────────────────────────────────┘  │ │
│  │  ┌────────┴────────┐                                     │ │
│  │  │ k3s-worker-01   │  ds1G flavor (1GB / 1 vCPU / 10GB) │ │
│  │  │ K3s Agent       │  FIP: .202 | Int: 10.10.0.x        │ │
│  │  └─────────────────┘                                     │ │
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Networks

| Network | CIDR | Purpose |
|---------|------|---------|
| `public` | 192.168.122.0/24 | Floating IPs, external access |
| `k3s-cluster-net` | 10.10.0.0/24 | K3s control plane + worker communication |
| `k3s-services-net` | 10.20.0.0/24 | Registry + auth services |

### Auth Flow

```
  Docker/Skopeo/K8s
        │
        ▼
  Nginx :5000  ─── /auth/token ──►  Token Service :5001
        │                                │
        │                          Validates against
        │                          Keystone (Application Credential)
        │                                │
        │                          Issues JWT (RS256 signed)
        │                                │
        ├── /v2/* ──►  Nginx auth_request ──► /auth/validate
        │              │   (JWT signature + iss/aud/exp
        │              │    + scope: repository:<name>:<action>)
        │              ├── No / bad / unscoped token → 401
        │              └── Valid, in-scope token → 200 (internal or external)
        │                                │
        │           ──────────────────►  Zot :5002 (no auth, Nginx gates access)
        │
   Image data flows through
```

---

## Step-by-Step Journey

### Step 01 — Create the DevStack VM

**Script:** `01_create_vm.sh`

A libvirt VM (`BaseDevStack`) is created with:
- 16 GB RAM, 6 vCPUs, 80 GB disk
- Ubuntu 24.04 cloud image
- Cloud-init for SSH key injection
- Bridged to `virbr0` (192.168.122.0/24)

This VM becomes the OpenStack control plane.

### Step 02 — Install DevStack

**Script:** `02_init_vm.sh`

DevStack is installed inside the VM with:
- **Keystone** — Identity service (user/project/role management)
- **Nova** — Compute service (manages tenant VMs via nested KVM)
- **Neutron** — Network service (virtual networks, routers, floating IPs)
- **Cinder** — Block storage service (LVM volumes for tenant VMs)

Configuration (`local.conf`):
- `ENABLED_SERVICES=key,nova,n-novnc,n-cauth,n-api-meta,neutron,cinder`
- `LIBVIRT_TYPE=kvm` (nested virtualization; use `qemu` only on hosts
  without hardware virtualization)
- Admin password: `nomoresecret`

A snapshot `PostStack_Ready` is taken after installation for fast reverts.

### Step 03 — OpenStack Bootstrap

**Script:** `03_openstack_bootstrap.sh`

Sets up the OpenStack tenant environment:

1. **Project & User** — Creates `k3s-project` with user `k3s-user`
2. **Quotas** — 32 GB RAM, 20 cores, 20 instances, 20 floating IPs
3. **Networks** — Creates two tenant networks:
   - `k3s-cluster-net` (10.10.0.0/24) — for K3s nodes
   - `k3s-services-net` (10.20.0.0/24) — for registry
4. **Router** — `k3s-router` connects both networks to the external net
5. **Image** — Uploads Ubuntu 24.04 as `Ubuntu24`
6. **Keypair** — Creates `k3s-key` from the host's SSH public key
7. **Application Credential** — Creates `auth-proxy-system` for the token service

### Step 04 — K3s Master VM

**Script:** `04_k3s_master_vm.sh`

Creates the K3s master node:

1. **Security Group** — `k3s-master-sg` with rules for SSH, K8s API (6443),
   and full cluster-network access
2. **Server** — `k3s-master-01` on `m1.medium` (4 GB, 2 vCPU) on `k3s-cluster-net`
3. **Floating IP** — Allocated from `public` pool and assigned
4. **Host Route** — `sudo ip route replace 192.168.122.200/29 via $VM_IP`
   so the host can reach floating IPs
5. **br-ex Configuration** — Ensures DevStack VM forwards floating range
   through the OVS bridge

### Step 05 — Registry VM (with Auth Proxy)

**Script:** `05_registry_vm.sh`

Creates the registry VM that also hosts the auth proxy (merged architecture):

1. **Security Group** — `registry-sg` with rules for:
   - Internal: SSH + port 5000 from cluster and services networks
   - External: SSH from host, port 5000 from anywhere (for auth proxy)
2. **Cinder Volume** — 20 GB volume for registry storage
3. **Server** — `registry-01` on `m1.small` (2 GB, 1 vCPU) on `k3s-services-net`
4. **Floating IP** — For external access (push images from host)
5. **Volume Attachment** — Cinder volume attached as `/dev/vdb`

### Step 06 — Zot Install

**Script:** `06_zot_install.sh`

Installs the Zot OCI registry on the registry VM:

1. **Binary** — Zot binary is SCP'd directly (no Docker needed)
2. **Disk Setup** — Cinder volume is formatted (ext4), mounted at `/mnt/registry`,
   and added to `/etc/fstab` for persistence
3. **Zot User** — System user `zot` created for running the service
4. **Config** — `/etc/zot/config.json` with:
   - `address: 0.0.0.0`, `port: 5000` (initially public for image import)
   - Storage at `/mnt/registry/data`
   - Search and UI extensions enabled
5. **Systemd** — `zot.service` for automatic startup
6. **Airgap Images** — K3s airgap images are imported via Skopeo from
   the master VM into Zot. The *deploy* is air-gapped: `nginx:alpine` and
   `busybox` are vendored as `docker-archive` tarballs (`make vendor`) and
   `11`/`12` push them from disk, so no external registry is contacted at
   deploy time. Internet is only needed once, to assemble the offline
   bundle (cloud image, k3s, airgap tar, zot, shellcheck, demo images).

### Step 07 — Auth Proxy Address Aliases

**Script:** `07_auth_proxy_vm.sh`

**Originally** created a separate VM for the auth proxy. After hitting
Nova placement errors (not enough disk for a 4th VM), the auth proxy
was merged into the registry VM, so no fourth VM is created.

The step still runs: it persists the aliases
`AUTH_PROXY_FIP = REGISTRY_FIP` and
`AUTH_PROXY_INTERNAL_IP = REGISTRY_INTERNAL_IP` to `devstack_env`, which keeps
08, 10 and 11 working unchanged. It creates no OpenStack resource.

### Step 08 — Auth Proxy Install

**Script:** `08_auth_proxy_install.sh`

Installs Nginx + Token Service on the registry VM:

1. **RSA Keypair** — Generates `auth-proxy-jwt.pem` / `.pub.pem` for JWT signing
2. **Token Service** — `lib/token_service.py`, a Python HTTP server on
   `127.0.0.1:5001`. It is the single source of truth: `08` installs it and `10`
   never rewrites it, so the two copies cannot drift apart. It:
   - accepts Basic Auth (Keystone Application Credential ID:secret) and validates
     it against Keystone `/auth/tokens`
   - issues RS256-signed JWTs carrying an `access` claim, and rejects malformed
     scopes with 400 instead of crashing
   - serves `/auth/validate` for Nginx `auth_request`, checking signature,
     `iss`, `aud`, `nbf`, `exp` and the requested repository/action
   - handles both GET and POST (containerd sends POST)
3. **Zot Reconfiguration** — Changes Zot from `0.0.0.0:5000` to `127.0.0.1:5002`
   (frees port 5000 for Nginx, avoids port conflict)
4. **Nginx** — Reverse proxy on `0.0.0.0:5000`:
   - `/auth/token` → Token Service (127.0.0.1:5001)
   - `/v2/` → Zot (127.0.0.1:5002), gated by `auth_request /auth/validate`
   - Zero network latency between proxy and registry (localhost)
   - Plain HTTP, no TLS: credentials, tokens and blobs are cleartext on the
     host-local network (see README §6)

### Step 09 — K3s Cluster Install

**Script:** `09_k3s_cluster_install.sh`

Installs K3s on master + worker:

1. **Worker VM** — `k3s-worker-01` on `ds1G` flavor (1 GB, 1 vCPU, 10 GB disk)
   - `m1.small` fails due to disk constraints; `ds1G` fits
   - Assigned a floating IP for SSH access from host
   - Security group allows cluster traffic + SSH from host
2. **K3s Server** — Installed on master with:
   - `--node-ip` and `--advertise-address` set to internal IP
   - `--tls-san` for FIP access to K8s API
   - `--token` for secure worker join
   - `--disable traefik` (not needed for demo)
   - `registries.yaml` pointing all mirrors to the internal registry, plus an
     explicit `mirrors."<internal-ip>:5000"` entry with an `http://` endpoint (a
     `*` wildcard alone is not used for a directly-referenced host, and the
     generated `hosts.toml` would be https-only), plus
     `configs.<internal-ip>.auth` so containerd performs the registry token flow
     with the application credential created by `03`
3. **K3s Agent** — Installed on worker, joins via `--server=https://MASTER_INTERNAL_IP:6443`
4. **Kubeconfig** — Fetched from master, rewritten with FIP for host access

### Step 10 — Registry Smoke Test

**Script:** `10_registry_smoke_test.sh`

Configures Nginx auth enforcement:

1. **Zot: no auth, loopback only** — Zot listens on `127.0.0.1:5002` and is
   reachable only through Nginx, which is the single enforcement point.
2. **One token service** — `lib/token_service.py` (installed by `08`) provides
   `/auth/token` and `/auth/validate`. `10` only reconfigures Nginx; it does not
   rewrite the service, so the two copies can no longer drift apart.
3. **No IP allow-list** — every `/v2/` request, internal or external, needs a
   valid Bearer token. The `auth_request` subrequest forwards `X-Original-URI`
   and `X-Original-Method`, and the service enforces the token's `access` claim
   (`repository:<name>:<action>`) on top of `iss`/`aud`/`exp`. Cluster nodes
   authenticate via `registries.yaml` (`configs.<ip>.auth`).
4. **curl tests (hard gates)**:
   - unauthenticated `/v2/` → 401 with `WWW-Authenticate: Bearer`
   - valid token on the ping endpoint → 200
   - scoped pull token → 200
   - pull-only token on `PUT` → 401/403
   - token for repository A used on repository B → 401/403
   - in-cluster client without a token → 401 (the old bypass is gone)
   - malformed scope on `/auth/token` → 400 (no crash)
   - the Zot catalog contains all 8 mirrored `rancher/…` images

### Authorisation

Four kinds of client (external, node, pod, anonymous) all end up at the same
`auth_request` gate; the matrix of what each one may do is in
**[README.md §6](README.md#6-security-model)**. The point worth repeating here:
there is no IP-based exemption, so security groups only decide *reachability*.

### Step 11 — Deployment Flow Demo

**Script:** `11_enable_zot_auth.sh`

End-to-end demo of the production deployment flow:

1. **Create App Credential** — New Keystone credential for the deployment
2. **Push Image** — Skopeo on master copies the vendored
   `vendor/nginx-alpine.tar` (`docker-archive:` source) to the private registry,
   authenticated via the app credential. No docker.io contact at deploy time.
3. **Create ImagePullSecret** — K8s secret with the app credential
4. **Deploy Pod** — Pod spec references the internal registry + imagePullSecret,
   and carries `app: prod-app` so the Service created by `12` has an endpoint
5. **Verify** — Pod reaches `Ready` state, image pulled successfully

Note that the push from the master is now genuinely authenticated: before the
IP allow-list was removed, `10.10.0.6` was whitelisted and the credentials were
decorative.

### Step 12 — Demo Deploy (Expose & Curl)

**Script:** `12_demo_deploy.sh`

Makes deployed apps reachable from the host machine:

1. **Open NodePort Range** — Adds security group rules for TCP 30000-32767
   on both master and worker SGs so the host can reach NodePort services
2. **Expose prod-app** — Labels the pod from step 11, creates a NodePort Service,
   curls it from the host (nginx:alpine default page)
3. **Push busybox** — Skopeo copies the vendored `vendor/busybox.tar` to the
   private registry as `demo-app:v1` (same air-gapped path)
4. **Deploy demo-app** — Pod runs `busybox httpd` (built-in HTTP server) serving
   a custom HTML page, proving any image works through the auth flow
5. **Expose demo-app** — NodePort Service, curl from host, verify HTTP 200
6. **Persist URLs** — `PROD_APP_URL` and `DEMO_APP_URL` saved to `devstack_env`

What is BusyBox? "The Swiss Army Knife of Embedded Linux" — a single ~2 MB
binary combining tiny versions of many common UNIX utilities (sh, ls, cat,
grep, wget, httpd, etc.). Its `httpd` applet serves as a minimal HTTP server,
ideal for proving the full push-to-deploy pipeline with the smallest image.

---

## Key Design Decisions

### Auth Proxy Merged into Registry VM

**Problem:** Nova scheduler refused to place a 4th VM ("No valid host was found").
The DevStack VM's hypervisor had only 16 GB free disk after 3 VMs.

**Solution:** Consolidated Nginx + Token Service onto the registry VM.

**Benefits:**
- Zero network latency between proxy and registry (localhost)
- One fewer security group to manage
- Eliminates placement errors entirely
- Zot reconfigured to `127.0.0.1:5002` (Nginx owns public port 5000)

### Worker VM Uses ds1G Flavor

**Problem:** `m1.small` (20 GB disk) fails placement. `m1.tiny` (1 GB disk) is too small
for the Ubuntu image (3.5 GB).

**Solution:** `ds1G` flavor (1 GB RAM, 1 vCPU, 10 GB disk) fits both the image
and the hypervisor's remaining capacity.

### Token Service Handles POST

**Problem:** containerd (K3s's container runtime) sends POST requests to
`/auth/token`, but the Python token service only handled GET.

**Solution:** Added `do_POST` method that delegates to `do_GET`.

### Skopeo Instead of Docker

**Problem:** Docker on the host requires `insecure-registries` config in
`/etc/docker/daemon.json` (needs sudo). Docker on VMs requires daemon installation.

**Solution:** Skopeo handles HTTP registries natively with `--dest-tls-verify=false`.
Already installed on the master VM for airgap image import.

---

## OpenStack Services Used

| Service | Role in This Project |
|---------|----------------------|
| **Keystone** | Identity: projects, users, roles, application credentials. The token service validates app creds against Keystone to issue JWTs. |
| **Nova** | Compute: schedules and runs 3 tenant VMs (master, worker, registry). Uses libvirt/QEMU driver with nested virtualization. |
| **Neutron** | Networking: 2 tenant networks + 1 external, 1 router, 3 security groups, floating IPs for external access. |
| **Cinder** | Block Storage: 20 GB volume attached to registry VM for persistent image storage. LVM backend. |
| **Glance** | Image: Ubuntu 24.04 cloud image registered as `Ubuntu24` for VM boot. |

---

## Resource Consumption

| Component | Flavor | RAM | vCPU | Disk (declared) |
|-----------|--------|-----|------|-----------------|
| DevStack VM (host) | — | 16 GB | 6 | 80 GB |
| k3s-master-01 | `m1.medium` | 4 GB | 2 | 40 GB |
| registry-01 | `m1.small` | 2 GB | 1 | 20 GB (root) + 20 GB (Cinder) |
| k3s-worker-01 | `ds1G` | 1 GB | 1 | 10 GB |
| **Total tenant** | | **7 GB** | **4** | **90 GB** |

The disks are qcow2 and thin-provisioned: the 90 GB above is the *declared*
size of the flavors, while the whole DevStack overlay is about 6.3 GB on the
host's 80 GB disk. Sizing an instance by its flavor therefore over-commits
the hypervisor disk, which is why the worker uses `ds1G` (10 GB) and the
registry keeps its data on a separate Cinder volume instead of its root disk.

---

## Lessons Learned

1. **Placement errors are real** — Nova's scheduler is strict about disk.
   A 80 GB host disk with 3 VMs leaves very little room. Choose flavors carefully.

2. **Nested networking is tricky** — Floating IPs need br-ex configuration on
   the DevStack VM AND a host route (`ip route replace`) to be reachable.

3. **Auth proxy on localhost wins** — Merging the proxy into the registry VM
   eliminated placement issues, reduced latency, and simplified security groups.

4. **containerd uses POST for auth** — The Docker registry auth spec mentions
   GET, but containerd sends POST. Both must be handled.

5. **Skopeo > Docker for CI** — No daemon, no insecure-registry config,
   works with HTTP registries out of the box.

6. **Scope enforcement needs the original request** — `auth_request`
   subrequests are always `GET`, so Nginx forwards `X-Original-URI` and
   `X-Original-Method`; without them the validator cannot tell a pull from a
   push and a pull-only token would authorise a `PUT`.

7. **Auth theatre is worse than no auth** — An IP allow-list plus a validator
   that only checks the signature looks secure while letting every internal
   client push anything. The fix was to delete the allow-list and check the
   token's `access` claim, then prove it with negative tests (`10` T4/T5/T6).

8. **A `*` mirror does not cover a directly-referenced host** — As soon as
   `registries.yaml` contains `configs."<ip>:5000"`, k3s writes
   `certs.d/<ip>:5000/hosts.toml` with an https-only `server` line. The `*`
   wildcard is a fallback for registries nobody configured, so the plain-HTTP
   Nginx answered an HTTPS request: `server gave HTTP response to HTTPS client`,
   pod stuck in `ImagePullBackOff`. The fix is to list the registry host under
   `mirrors` too, with its `http://` endpoint; k3s then emits a `[host]` fallback.
