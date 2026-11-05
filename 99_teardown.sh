#!/bin/bash
# 99_teardown.sh — destroy everything the lab created, in dependency order.
#
#   ./99_teardown.sh                 # dry-run: show what would be deleted
#   ./99_teardown.sh --yes           # actually delete
#   ./99_teardown.sh --yes --revert  # ... and revert BaseDevStack to PostStack_Ready
#
# SAFETY:
#   * Without --yes this script only *lists* resources. It never mutates state.
#   * Every step is idempotent and best-effort: a missing resource, an unreachable
#     VM or an OpenStack error is logged and the next step continues. The final
#     summary tells you what survived, so you can re-run or clean by hand.
#
# NOT TESTED BY DESIGN. This file is delivered with the lab and reviewed, but the
# author deliberately did not run it against a live stack. Treat the first real
# run as a supervised operation.
#
# NOTE: --revert destroys the DevStack VM's current state and the Glance image, so
# the next XX_RUN_FROM_SNAPSHOT.sh re-uploads the 629 MB cloud image.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env

CONFIRM=0
REVERT=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) CONFIRM=1 ;;
        --revert) REVERT=1 ;;
        --dry-run) CONFIRM=0 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "unknown argument: $arg (try --help)" ;;
    esac
done

WARNINGS=()

# ── helpers ─────────────────────────────────────────────────────────────
tenant() { vm_openstack tenant "$*"; }
admin()  { vm_openstack admin  "$*"; }

# exists <tenant|admin> <resource> <name>
exists() {
    local scope="$1"
    "$scope" "openstack $2 show '$3'" >/dev/null 2>&1
}

# run_step <description> <function> — in dry-run mode it only prints; otherwise it
# runs the function, shows its output, and records a failure instead of aborting.
run_step() {
    local desc="$1"
    shift
    if (( ! CONFIRM )); then
        printf '  [dry-run] %s\n' "$desc"
        return 0
    fi
    printf '\n== %s\n' "$desc"
    local out rc
    out="$("$@" 2>&1)"
    rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/   /'
    if (( rc != 0 )); then
        printf '   WARNING: this step did not complete cleanly (rc=%d)\n' "$rc"
        WARNINGS+=("$desc")
    fi
}

# server_fip <name> — floating IP from the `public=...` part of the Networks column.
server_fip() {
    tenant "openstack server list --name '$1' -f value -c Networks" \
        | tr ',;' '\n\n' | awk -F= '/public=/{print $2}' | tr -d ' ' | head -1
}

lab_servers() {
    tenant "openstack server list -f value -c Name" \
        | grep -E '^(k3s-master-01|k3s-worker-[0-9]+|registry-01)$' || true
}

# Floating IPs in the lab range. Parsed from JSON because the column name
# "Floating IP Address" contains spaces and does not survive quoting over ssh.
fips_in_range() {
    tenant "openstack floating ip list -f json" | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("[")
if start < 0:
    sys.exit(0)
for row in json.loads(raw[start:]):
    ip = row.get("Floating IP Address") or ""
    parts = ip.rsplit(".", 1)
    if len(parts) == 2 and parts[0] == "192.168.122" and parts[1].isdigit() \
            and 200 <= int(parts[1]) <= 210:
        print(ip)
' || true
}

# ── pre-flight inventory (read-only) ────────────────────────────────────
echo "== pre-flight: resources currently owned by the lab =="
printf '  servers:         %s\n' "$(lab_servers | tr '\n' ' ')"
printf '  volumes:         %s\n' "$(tenant "openstack volume list -f value -c Name" | grep -x 'registry-01-volume' | tr '\n' ' ')"
printf '  floating IPs:    %s\n' "$(fips_in_range | tr '\n' ' ')"
printf '  security groups: %s\n' "$(tenant "openstack security group list -f value -c Name" | grep -xE 'k3s-master-sg|k3s-worker-sg|registry-sg' | tr '\n' ' ')"
printf '  networks:        %s\n' "$(tenant "openstack network list -f value -c Name" | grep -xE 'k3s-cluster-net|k3s-services-net' | tr '\n' ' ')"
printf '  keypair:         %s\n' "$(tenant "openstack keypair list -f value -c Name" | grep -x 'k3s-key')"
printf '  image:           %s\n' "$(admin "openstack image list -f value -c Name" | grep -x 'Ubuntu24')"
echo

if (( ! CONFIRM )); then
    echo "Dry-run only. Re-run with --yes to delete (add --revert to restore the snapshot)."
    exit 0
fi

echo "== tearing down =="

# ── 0. capture FIP allocations before the servers disappear ─────────────
FIP_ALLOCATIONS=""
for srv in $(lab_servers); do
    fip="$(server_fip "$srv")"
    [[ -n "$fip" ]] && FIP_ALLOCATIONS+="$fip"$'\n'
done
FIP_ALLOCATIONS+="$(fips_in_range)"

# ── 1. Kubernetes workloads and NodePort services ───────────────────────
del_workloads() {
    if [[ ! -f "$KUBECONFIG_PATH" ]]; then
        echo "no kubeconfig at $KUBECONFIG_PATH — cluster is already unreachable"
        return 0
    fi
    local K=(kubectl --kubeconfig "$KUBECONFIG_PATH")
    "${K[@]}" delete service prod-app-svc demo-app-svc --ignore-not-found || true
    "${K[@]}" delete pod prod-app demo-app --ignore-not-found --wait=false || true
    "${K[@]}" delete secret registry-auth --ignore-not-found || true
    return 0
}
run_step "delete NodePort services, demo/prod pods, registry-auth secret" del_workloads

# ── 2. stop the k3s agents, then the server ─────────────────────────────
uninstall_k3s() {
    local srv fip rc=0
    for srv in $(lab_servers | grep '^k3s-worker-'); do
        fip="$(server_fip "$srv")"
        [[ -n "$fip" ]] || continue
        ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${fip}" \
            'sudo -n /usr/local/bin/k3s-agent-uninstall.sh' || rc=1
    done
    fip="$(server_fip "$MASTER_NAME")"
    if [[ -n "$fip" ]]; then
        ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${fip}" \
            'sudo -n /usr/local/bin/k3s-uninstall.sh' || rc=1
    fi
    return $rc
}
run_step "uninstall k3s agent (workers) and server (master)" uninstall_k3s

# ── 3. Nova servers ─────────────────────────────────────────────────────
del_servers() {
    local srv rc=0
    for srv in $(lab_servers); do
        tenant "openstack server delete --wait '$srv'" || rc=1
    done
    return $rc
}
run_step "delete worker, master and registry servers" del_servers

# ── 4. volumes ──────────────────────────────────────────────────────────
del_volume() {
    exists tenant volume "$REGISTRY_VOLUME_NAME" || { echo "volume already gone"; return 0; }
    tenant "openstack volume delete --wait '$REGISTRY_VOLUME_NAME'"
}
run_step "delete volume $REGISTRY_VOLUME_NAME" del_volume

# ── 5. floating IPs (captured before the servers were deleted) ──────────
release_fips() {
    local fip rc=0
    while IFS= read -r fip; do
        [[ -n "$fip" ]] || continue
        tenant "openstack floating ip delete '$fip'" || rc=1
    done <<< "$(printf '%s\n' "$FIP_ALLOCATIONS" | sort -u)"
    return $rc
}
run_step "release floating IPs in 192.168.122.200/29" release_fips

# ── 6. security groups (worker first: it references the others' rules) ──
del_sgs() {
    local sg rc=0
    for sg in k3s-worker-sg registry-sg k3s-master-sg; do
        exists tenant security-group "$sg" || continue
        tenant "openstack security group delete '$sg'" || rc=1
    done
    return $rc
}
run_step "delete security groups (worker, registry, master)" del_sgs

# ── 7. router, subnets, networks ────────────────────────────────────────
del_networks() {
    local rc=0
    if exists tenant router "$K3S_ROUTER_NAME"; then
        tenant "openstack router remove subnet '$K3S_ROUTER_NAME' '$K3S_CLUSTER_SUBNET_NAME'" || true
        tenant "openstack router remove subnet '$K3S_ROUTER_NAME' '$K3S_SERVICES_SUBNET_NAME'" || true
        tenant "openstack router unset --external-gateway '$K3S_ROUTER_NAME'" || true
        tenant "openstack router delete '$K3S_ROUTER_NAME'" || rc=1
    else
        echo "router $K3S_ROUTER_NAME already gone"
    fi
    local subnet net
    for subnet in "$K3S_CLUSTER_SUBNET_NAME" "$K3S_SERVICES_SUBNET_NAME"; do
        exists tenant subnet "$subnet" || continue
        tenant "openstack subnet delete '$subnet'" || rc=1
    done
    for net in "$K3S_CLUSTER_NET_NAME" "$K3S_SERVICES_NET_NAME"; do
        exists tenant network "$net" || continue
        tenant "openstack network delete '$net'" || rc=1
    done
    return $rc
}
run_step "delete router $K3S_ROUTER_NAME, subnets and networks" del_networks

# ── 8. keypair ──────────────────────────────────────────────────────────
del_keypair() {
    exists tenant keypair "$KEYPAIR_NAME" || { echo "keypair already gone"; return 0; }
    tenant "openstack keypair delete '$KEYPAIR_NAME'"
}
run_step "delete keypair $KEYPAIR_NAME" del_keypair

# ── 9. application credential ───────────────────────────────────────────
del_app_cred() {
    exists tenant application-credential auth-proxy-system \
        || { echo "application credential already gone"; return 0; }
    tenant "openstack application credential delete auth-proxy-system"
}
run_step "delete application credential auth-proxy-system" del_app_cred

# ── 10. Glance image ────────────────────────────────────────────────────
del_image() {
    exists admin image "$IMAGE_NAME" || { echo "image already gone"; return 0; }
    admin "openstack image delete '$IMAGE_NAME'"
}
run_step "delete image $IMAGE_NAME" del_image

# ── 11. optional: revert the DevStack VM to PostStack_Ready ─────────────
if (( REVERT )); then
    run_step "revert $VM_NAME to snapshot PostStack_Ready" \
        sudo bash "$SCRIPT_DIR/XX_revert_to_snapshot.sh"
else
    echo
    echo "  [skipped] DevStack snapshot revert (pass --revert to include it)"
fi

# ── summary: what is still there ────────────────────────────────────────
echo
echo "== remaining lab resources =="
printf '  servers:         %s\n' "$(lab_servers | tr '\n' ' ')"
printf '  volumes:         %s\n' "$(tenant "openstack volume list -f value -c Name" | grep -x 'registry-01-volume' | tr '\n' ' ')"
printf '  floating IPs:    %s\n' "$(fips_in_range | tr '\n' ' ')"
printf '  security groups: %s\n' "$(tenant "openstack security group list -f value -c Name" | grep -xE 'k3s-master-sg|k3s-worker-sg|registry-sg' | tr '\n' ' ')"
printf '  networks:        %s\n' "$(tenant "openstack network list -f value -c Name" | grep -xE 'k3s-cluster-net|k3s-services-net' | tr '\n' ' ')"
printf '  keypair:         %s\n' "$(tenant "openstack keypair list -f value -c Name" | grep -x 'k3s-key')"
printf '  image:           %s\n' "$(admin "openstack image list -f value -c Name" | grep -x 'Ubuntu24')"

echo
echo "  Left in place on purpose: project $PROJECT_NAME, user $PROJECT_USER,"
echo "  the public network and the BaseDevStack VM. They are inputs, not lab output."
echo "  Remember: sudo rm /etc/sudoers.d/99-final-lab once you no longer need the lab."

if (( ${#WARNINGS[@]} > 0 )); then
    echo
    echo "== steps that did not complete cleanly =="
    printf '  - %s\n' "${WARNINGS[@]}"
    echo "  Re-run the script (it is idempotent) or clean the listed resources by hand."
    exit 1
fi
echo
echo "Teardown complete."
