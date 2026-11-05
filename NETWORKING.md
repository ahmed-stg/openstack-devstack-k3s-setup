# Networking Deep Dive

## The Big Picture

Addresses are written as `$MASTER_FIP`, `$REGISTRY_INTERNAL_IP`, … because they
change on every run: `source devstack_env` to get the real values.

```
Internet / Host ($VM_HOST_IP)
    │
    │ virbr0 (libvirt NAT bridge)
    ▼
┌─────────────────────────────────────────────────────────────┐
│  DevStack VM  ($VM_IP)                                       │
│                                                               │
│  enp1s0 ─── $VM_IP/24  (management, SSH from host)          │
│  enp2s0 ─── DOWN (plumbed into br-ex by OVS)                │
│                                                               │
│  ┌─ OVS ───────────────────────────────────────────────────┐ │
│  │                                                          │ │
│  │  br-ex ─── 192.168.122.201/29  (floating IP gateway)    │ │
│  │    │                                                     │ │
│  │    │  enp2s0 (physical port, provider net)                │ │
│  │    │  patch-port ←→ br-int                               │ │
│  │    │                                                     │ │
│  │  br-int ─── integration bridge                          │ │
│  │    │  tap* ports (one per tenant VM vNIC)                │ │
│  │    │                                                     │ │
│  │  Geneve tunnels between br-int ports (OVN)              │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                               │
│  OVN logical router (no L3 agent, no qrouter namespace)       │
│  ┌─ k3s-router ───────────────────────────────────────────┐ │
│  │  external gateway → br-ex (public-subnet gateway IP)    │ │
│  │  10.10.0.1  → k3s-cluster-subnet                        │ │
│  │  10.20.0.1  → k3s-services-subnet                      │ │
│  │  NAT: floating IPs → fixed IPs (OVN distributed NAT)    │ │
│  └──────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘

           │ Floating IPs (192.168.122.200-205)
           ▼
    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
    │ k3s-master-01│  │ k3s-worker-01│  │ registry-01  │
    │ FIP          │  │ FIP          │  │ FIP          │
    │ $MASTER_FIP  │  │ $WORKER_FIP  │  │ $REGISTRY_FIP│
    │ $MASTER_     │  │ $WORKER_     │  │ $REGISTRY_   │
    │  INTERNAL_IP │  │  INTERNAL_IP │  │  INTERNAL_IP │
    │ k3s-cluster  │  │ k3s-cluster  │  │ k3s-services │
    │              │  │              │  │              │
    │ flannel.1    │  │ flannel.1    │  │ Nginx :5000  │
    │ 10.42.0.0/24 │  │ 10.42.1.0/24 │  │  (auth gate) │
    │ cni0         │  │              │  │ Zot  :5002   │
    │ 10.42.0.1/24 │  │              │  │ Token :5001  │
    └──────────────┘  └──────────────┘  └──────────────┘
```

---

## Layer by Layer

### Layer 1 — Host to DevStack VM

The host runs libvirt with a default NAT network (`virbr0`, `192.168.122.0/24`).
The DevStack VM gets `enp1s0` via this bridge — it's the management interface
used for SSH from the host.

```
Host (192.168.122.1) ── virbr0 ── enp1s0 (192.168.122.79)
```

No special configuration needed. libvirt provides DHCP and NAT.

### Layer 2 — DevStack VM's Second NIC (enp2s0 → br-ex)

The VM has a second interface `enp2s0` that starts DOWN.
DevStack's OVS agent adds it to `br-ex` (the external bridge):

```
br-ex
 ├── enp2s0          (physical port, connects to libvirt network)
 ├── br-ex internal  (192.168.122.201/29 — the floating IP gateway)
 └── patch-port ←→ br-int
```

`configure_br_ex.sh` does three critical things:
1. Assigns the floating IP gateway IP (`192.168.122.201/29`) to `br-ex`
2. Enables IP forwarding (`net.ipv4.ip_forward=1`)
3. Disables reverse path filtering (`rp_filter=0`) so the VM routes
   packets from host → VM → tenant VMs (asymmetric routing)

**Without this script, floating IPs are unreachable from the host.**

### Layer 3 — Host Route to Floating IPs

The host needs a route to reach floating IPs through the DevStack VM:

```
sudo ip route replace 192.168.122.200/29 via 192.168.122.79
```

This tells the host: "to reach 192.168.122.200-205, send packets to the
DevStack VM at 192.168.122.79". The VM then routes them through br-ex
into OVN, which applies the floating-IP DNAT/SNAT.

Script `04_k3s_master_vm.sh` adds this route automatically.

### Layer 4 — Neutron Networks

Three networks exist inside OpenStack:

| Network | CIDR | Purpose | Used by |
|---------|------|---------|---------|
| `public` | 192.168.122.200/29 | External / floating IPs | Gateway on br-ex |
| `k3s-cluster-net` | 10.10.0.0/24 | K3s control plane + workers | master-01, worker-01 |
| `k3s-services-net` | 10.20.0.0/24 | Registry + auth services | registry-01 |

The `k3s-router` connects both tenant networks to the public network:

```
                    k3s-router
                        │
            ┌───────────┼───────────┐
            │                       │
    10.10.0.1/24            10.20.0.1/24
    k3s-cluster-subnet      k3s-services-subnet
            │                       │
      master + worker          registry-01
```

### Layer 5 — Floating IPs (1:1 NAT)

OVN maps each floating IP to a fixed IP (distributed NAT on the chassis):

| Floating IP | Fixed IP | VM |
|-------------|----------|----|
| `$MASTER_FIP` | `$MASTER_INTERNAL_IP` | k3s-master-01 |
| `$WORKER_FIP` | `$WORKER_INTERNAL_IP` | k3s-worker-01 |
| `$REGISTRY_FIP` | `$REGISTRY_INTERNAL_IP` | registry-01 |

The concrete addresses change on every run: read them from `devstack_env`
(`source devstack_env`), or from `openstack floating ip list` inside the
DevStack VM. All examples below use the same symbolic names.

This is **1:1 DNAT/SNAT**. Incoming traffic to the FIP is rewritten to the
fixed IP. Outgoing traffic from the fixed IP is rewritten to the FIP.

### Layer 6 — K3s Overlay (Flannel VXLAN)

K3s uses Flannel to create an overlay network for pod-to-pod communication:

```
Node subnet: 10.42.0.0/24 (master) ←→ 10.42.1.0/24 (worker)
Transport:   VXLAN over 10.10.0.0/24 (cluster network)
```

Each node gets a `/24` from the `10.42.0.0/16` pool. The `flannel.1`
interface handles encapsulation. The `cni0` bridge connects pods on the
same node.

### Layer 7 — Cross-Network Communication

The master (10.10.0.x) needs to reach the registry (10.20.0.x).
This works because `k3s-router` routes between the two subnets.

**But there's a catch**: the registry's security group (`registry-sg`)
must allow traffic from `10.10.0.0/24`. Without that rule, the master
and workers cannot reach the registry at all.

That rule is only about *reachability*. It is not an authentication bypass:
since step `10` removed the Nginx IP allow-list, a packet from `10.10.0.0/24`
needs a scoped Bearer token exactly like a packet from the host.

---

## Data Flow Examples

### Example 1: SSH from host to master

```
Host ($VM_HOST_IP)
  → virbr0
  → enp1s0 ($VM_IP)
  → OVN DNAT: $MASTER_FIP → $MASTER_INTERNAL_IP
  → br-int → tap port → master VM ens2
```

### Example 2: K3s worker pulls image from registry

```
Worker ($WORKER_INTERNAL_IP)
  → default route → 10.10.0.1 (k3s-router)
  → router routes to 10.20.0.0/24
  → $REGISTRY_INTERNAL_IP (registry)
  → Nginx :5000 → HEAD /v2/... → auth_request /auth_validate → 401
  → registries.yaml configs.<ip>.auth supplies the credential
  → /auth/token (Basic → Keystone) → Bearer → 200 → Zot :5002
  (No IP allow-list: in-cluster traffic is authenticated too)
```

### Example 3: Developer pushes image from host

```
Host ($VM_HOST_IP)
  → ip route: 192.168.122.200/29 via $VM_IP
  → enp1s0 → br-ex
  → Neutron L3 NAT: $REGISTRY_FIP → $REGISTRY_INTERNAL_IP
  → registry → Nginx :5000
  → no token → auth_request /auth_validate → 401
  → WWW-Authenticate: Bearer realm=http://FIP:5000/auth/token
  → Skopeo gets JWT from /auth/token (Token Service → Keystone)
  → Retry /v2/ with Bearer JWT → signature + scope checked → Zot :5002
```

---

## Current Flaws

### 1. Asymmetric routing + rp_filter hack (P0)

**Problem:** Packets from host to floating IPs go host→VM→br-ex→L3→VM,
but return packets go VM→L3→br-ex→enp1s0→host (different path).
Linux's `rp_filter` (reverse path filtering) drops these by default.

**Current fix:** `configure_br_ex.sh` disables `rp_filter` globally.
This is a security risk — it disables spoof protection on all interfaces.

**Better fix:** Disable `rp_filter` only on `br-ex`:
```bash
sudo sysctl -w net.ipv4.conf.br-ex.rp_filter=0
# Keep rp_filter=1 on enp1s0 and other interfaces
```

### 2. Single NIC for management + floating IPs (P2)

**Problem:** `enp1s0` handles both SSH management AND floating IP traffic.
If OpenStack networking breaks, you lose SSH access too.

**Better fix:** Use the second NIC (`enp2s0`) as a dedicated provider
network on a separate libvirt network. Then management and tenant traffic
are fully isolated:
```bash
# Create a separate libvirt network for the provider net
sudo virsh net-define provider.xml   # isolated, no NAT
sudo virsh net-start provider
# Attach enp2s0 to this network instead of the default NAT
```

### 3. No MTU consideration (P0)

**Problem:** OpenStack VXLAN/Geneve tunnels add 50 bytes of overhead.
The default MTU is 1500, but tenant VM MTU should be 1450. Large Docker
pushes (layer blobs > 1400 bytes) can silently fail or time out.

**Current state:** Not configured. Works by luck for small images.

**Fix:** Set Neutron MTU:
```bash
# In local.conf
NEUTRON_ML2_SEGMENT_MTU=1450

# Or per-network after creation:
openstack network set --mtu 1450 k3s-cluster-net
openstack network set --mtu 1450 k3s-services-net
```
Then cloud-init inside VMs will set the correct MTU via DHCP.

### 4. Floating IP range is tiny (6 IPs) (P1)

**Problem:** `FLOATING_RANGE=192.168.122.200/29` gives only 6 usable IPs
(.200-.205). With 3 VMs, you have 3 left. Adding more VMs requires
expanding the range, which means re-running DevStack.

**Fix:** Use a wider range in `local.conf`:
```bash
FLOATING_RANGE=192.168.122.200/28   # 14 usable IPs
```
This requires `./stack.sh` to take effect.

### 5. Security groups are too permissive (P1)

**Problem:** Several rules use `0.0.0.0/0`:
- `registry-sg`: port 5000 from anywhere (for auth proxy)
- `k3s-worker-sg`: SSH from `HOST_ACCESS_CIDR` (192.168.122.0/24)

In a real deployment, port 5000 should only be accessible from
specific CIDRs (VPN, CI runners), and SSH should use a bastion host.

**Fix:** Restrict to known CIDRs:
```bash
# Instead of 0.0.0.0/0 for port 5000:
openstack security group rule create --remote-ip <YOUR_VPN_CIDR> \
  --protocol tcp --dst-port 5000 registry-sg
```

### 6. No network isolation between tenants (P3)

**Problem:** All VMs share the same project. If you add another tenant
later, there's no isolation — they can reach each other's internal IPs.

**Fix:** Use separate OpenStack projects with network RBAC policies,
or use Neutron's `allowed-address-pairs` for fine-grained control.

### 7. K3s Flannel uses the cluster network as transport (P2)

**Problem:** Flannel VXLAN encapsulates pod traffic over 10.10.0.0/24.
This means pod-to-pod traffic between master and worker is double-encapsulated
if the cluster network itself is a Geneve overlay (OVN).

**Fix:** Use OVN-Kubernetes instead of Flannel. It integrates natively
with Neutron's OVN backend, eliminating double encapsulation:
```bash
k3s server --flannel-backend=none --disable-network-policy
# Then install ovn-kubernetes as the CNI
```

### 8. Registry has no dedicated internal DNS (P3)

**Problem:** K3s workers reach the registry via IP (`10.20.0.91:5000`).
If the registry VM is recreated with a new IP, every K3s config must
be updated (`registries.yaml`, kubeconfig, imagePullSecrets).

**Fix:** Use Neutron's internal DNS with a designated FQDN:
```bash
openstack network set --dns-domain k3s.local. k3s-services-net
# Then access registry as: registry-01.k3s.local:5000
```
This requires `enable_dhcp=True` and `dns_publish_fixed_ip=True` on the subnet.

Each flaw above is tagged with a priority (P0 = fix first, P3 = nice to have).
