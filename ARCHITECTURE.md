# Zero to Hero: Building a Private Cloud Platform with OpenStack + K3s

## Overview

This project transforms a single bare-metal machine running DevStack into a
fully operational private cloud platform with:

- **OpenStack** — IaaS layer (Keystone, Nova, Neutron, Cinder)
- **K3s** — Lightweight Kubernetes cluster (1 master + 1 worker)
- **Zot** — Private OCI container registry with Cinder-backed storage
- **Nginx + Token Service** — Auth proxy integrated into the registry VM
- **Keystone Application Credentials** — K8s pulls images with OpenStack-native auth

The entire stack is reproducible from a single command:

```bash
sudo bash XX_RUN_FROM_SNAPSHOT.sh
```

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
│  │  Tenant VMs (nested QEMU):                                │ │
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
        ├── /v2/* ──────────────►  Zot :5002 (verifies JWT)
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
- **Nova** — Compute service (manages tenant VMs via nested QEMU)
- **Neutron** — Network service (virtual networks, routers, floating IPs)
- **Cinder** — Block storage service (LVM volumes for tenant VMs)

Configuration (`local.conf`):
- `ENABLED_SERVICES=key,nova,n-novnc,n-cauth,n-api-meta,neutron,cinder`
- `LIBVIRT_TYPE=qemu` (nested virtualization)
- Admin password: `openstack`

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
   the master VM into Zot (local mirror for air-gapped operation)

### Step 07 — Auth Proxy VM (No-Op)

**Script:** `07_auth_proxy_vm.sh`

**Originally** created a separate VM for the auth proxy. After hitting
Nova placement errors (not enough disk for a 4th VM), the auth proxy
was merged into the registry VM.

This script is now a **no-op** that just aliases:
- `AUTH_PROXY_FIP = REGISTRY_FIP`
- `AUTH_PROXY_INTERNAL_IP = REGISTRY_INTERNAL_IP`

This keeps downstream scripts (08, 10, 11) working without modification.

### Step 08 — Auth Proxy Install

**Script:** `08_auth_proxy_install.sh`

Installs Nginx + Token Service on the registry VM:

1. **RSA Keypair** — Generates `auth-proxy-jwt.pem` / `.pub.pem` for JWT signing
2. **Token Service** — Python HTTP server on `127.0.0.1:5001` that:
   - Accepts Basic Auth (Keystone Application Credential ID:secret)
   - Validates against Keystone `/auth/tokens` endpoint
   - Issues RS256-signed JWTs with scope-based access control
   - Handles both GET and POST (containerd sends POST)
3. **Zot Reconfiguration** — Changes Zot from `0.0.0.0:5000` to `127.0.0.1:5002`
   (frees port 5000 for Nginx, avoids port conflict)
4. **Nginx** — Reverse proxy on `0.0.0.0:5000`:
   - `/auth/token` → Token Service (127.0.0.1:5001)
   - `/v2/` → Zot (127.0.0.1:5002)
   - Zero network latency between proxy and registry (localhost)

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
   - `registries.yaml` pointing all mirrors to the internal registry
3. **K3s Agent** — Installed on worker, joins via `--server=https://MASTER_INTERNAL_IP:6443`
4. **Kubeconfig** — Fetched from master, rewritten with FIP for host access

### Step 10 — Registry Smoke Test

**Script:** `10_registry_smoke_test.sh`

Enables bearer auth on Zot and tests the auth flow:

1. **Bearer Auth** — Zot config updated with:
   - `auth.bearer.realm` pointing to the auth proxy
   - `auth.bearer.cert` (JWT public key)
   - Zot restarts on `127.0.0.1:5002`
2. **curl Tests**:
   - `/v2/` returns 401 with `WWW-Authenticate: Bearer` header
   - `/auth/token` with Basic Auth returns a valid JWT

### Step 11 — Deployment Flow Demo

**Script:** `11_enable_zot_auth.sh`

End-to-end demo of the production deployment flow:

1. **Create App Credential** — New Keystone credential for the deployment
2. **Push Image** — Skopeo on master copies `nginx:alpine` from Docker Hub
   to the private registry (authenticated via app credential)
3. **Create ImagePullSecret** — K8s secret with the app credential
4. **Deploy Pod** — Pod spec references the internal registry + imagePullSecret
5. **Verify** — Pod reaches `Ready` state, image pulled successfully

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

## File Reference

| File | Purpose |
|------|---------|
| `config.env` | Base VM configuration (RAM, vCPUs, disk) |
| `devstack_env` | Runtime state (IPs, credentials, persisted by scripts) |
| `lib/common.sh` | Shared functions (SSH helpers, OpenStack wrappers, wait loops) |
| `01_create_vm.sh` | Create the DevStack libvirt VM |
| `02_init_vm.sh` | Install DevStack inside the VM |
| `03_openstack_bootstrap.sh` | Project, networks, quotas, keypair, app credential |
| `04_k3s_master_vm.sh` | Create K3s master VM with floating IP |
| `05_registry_vm.sh` | Create registry VM with Cinder volume + floating IP |
| `06_zot_install.sh` | Install Zot, format volume, import airgap images |
| `07_auth_proxy_vm.sh` | No-op: aliases auth-proxy IPs to registry IPs |
| `08_auth_proxy_install.sh` | Install Nginx + Token Service, reconfigure Zot to localhost |
| `09_k3s_cluster_install.sh` | Create worker VM, install K3s server + agent |
| `10_registry_smoke_test.sh` | Enable bearer auth, test with curl |
| `11_enable_zot_auth.sh` | End-to-end: push image, deploy pod |
| `XX_RUN_FROM_SNAPSHOT.sh` | Revert + reset + run full stack (03-11) |
| `XX_revert_to_snapshot.sh` | virsh snapshot revert (needs sudo) |
| `XX_reset_rerun_state.sh` | Reset devstack_env to base values |
| `DEPLOY_WORKFLOW.md` | User guide for push-to-deploy |
| `configure_br_ex.sh` | Configure OVS bridge on DevStack VM |
| `import_images.sh` | Skopeo-based airgap image import script |
| `scp-safe` / `ssh-safe` | SSH wrappers with known-hosts bypass |
| `source_env.sh` | Source devstack_env helper |

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

| Component | RAM | vCPU | Disk |
|-----------|-----|------|------|
| DevStack VM (host) | 16 GB | 6 | 80 GB |
| k3s-master-01 | 4 GB | 2 | 40 GB |
| registry-01 | 2 GB | 1 | 20 GB (root) + 20 GB (Cinder) |
| k3s-worker-01 | 1 GB | 1 | 10 GB |
| **Total tenant** | **7 GB** | **4** | **90 GB** |

---

## Quick Start

```bash
# 1. One command to build everything from a clean snapshot
sudo bash XX_RUN_FROM_SNAPSHOT.sh

# 2. Deploy your first app (see DEPLOY_WORKFLOW.md for details)
source devstack_env
# ... follow the one-liner in DEPLOY_WORKFLOW.md
```

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
