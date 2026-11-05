#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVSTACK_ENV_FILE="${DEVSTACK_ENV_FILE:-$ROOT_DIR/devstack_env}"

load_env() {
    if [[ -f "$DEVSTACK_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$DEVSTACK_ENV_FILE"
    fi
VM_NAME="${VM_NAME:-BaseDevStack}"
VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_PUB_KEY="${SSH_PUB_KEY:-${VM_SSH_KEY}.pub}"
SSH_USER="${SSH_USER:-ubuntu}"

    SSH_BASE_OPTS=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o GlobalKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ConnectTimeout=10
        -o BatchMode=yes
    )

    # Global SSH args for CLI use
    # Exported for callers that source this library (02_init_vm.sh uses its own).
    export SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR"

    PROJECT_NAME="${PROJECT_NAME:-k3s-project}"
    PROJECT_DESC="${PROJECT_DESC:-K3s Deployment}"
    PROJECT_USER="${PROJECT_USER:-k3s-user}"
    PROJECT_PASSWORD="${PROJECT_PASSWORD:-usersecret}"
    PROJECT_ROLE="${PROJECT_ROLE:-member}"

    PUBLIC_NET_NAME="${PUBLIC_NET_NAME:-public}"
    HOST_ACCESS_CIDR="${HOST_ACCESS_CIDR:-192.168.122.0/24}"
    FLOATING_RANGE="${FLOATING_RANGE:-192.168.122.200/29}"

    K3S_CLUSTER_NET_NAME="${K3S_CLUSTER_NET_NAME:-k3s-cluster-net}"
    K3S_CLUSTER_SUBNET_NAME="${K3S_CLUSTER_SUBNET_NAME:-k3s-cluster-subnet}"
    K3S_CLUSTER_CIDR="${K3S_CLUSTER_CIDR:-10.10.0.0/24}"
    K3S_CLUSTER_GW="${K3S_CLUSTER_GW:-10.10.0.1}"

    K3S_SERVICES_NET_NAME="${K3S_SERVICES_NET_NAME:-k3s-services-net}"
    K3S_SERVICES_SUBNET_NAME="${K3S_SERVICES_SUBNET_NAME:-k3s-services-subnet}"
    K3S_SERVICES_CIDR="${K3S_SERVICES_CIDR:-10.20.0.0/24}"
    K3S_SERVICES_GW="${K3S_SERVICES_GW:-10.20.0.1}"

    K3S_ROUTER_NAME="${K3S_ROUTER_NAME:-k3s-router}"
    IMAGE_NAME="${IMAGE_NAME:-Ubuntu24}"
    IMAGE_PATH="${IMAGE_PATH:-$ROOT_DIR/noble-server-cloudimg-amd64.img}"
    KEYPAIR_NAME="${KEYPAIR_NAME:-k3s-key}"
    WORKER_COUNT="${WORKER_COUNT:-1}"
    MASTER_NAME="${MASTER_NAME:-k3s-master-01}"
    MASTER_FLAVOR="${MASTER_FLAVOR:-m1.medium}"

    REGISTRY_NAME="${REGISTRY_NAME:-registry-01}"
    REGISTRY_FLAVOR="${REGISTRY_FLAVOR:-m1.small}"
    REGISTRY_VOLUME_NAME="${REGISTRY_VOLUME_NAME:-registry-01-volume}"
    REGISTRY_VOLUME_SIZE="${REGISTRY_VOLUME_SIZE:-20}"

    K3S_BINARY_PATH="${K3S_BINARY_PATH:-$ROOT_DIR/k3s}"
    K3S_IMAGES_PATH="${K3S_IMAGES_PATH:-$ROOT_DIR/k3s-airgap-images-amd64.tar}"
    ZOT_BINARY_PATH="${ZOT_BINARY_PATH:-$ROOT_DIR/zot-linux-amd64}"
    KUBECONFIG_PATH="${KUBECONFIG_PATH:-$ROOT_DIR/k3s-kubeconfig.yaml}"
}

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

log_section() {
    printf '\n[%s] === %s ===\n' "$(date +%H:%M:%S)" "$*" >&2
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_env() {
    local name
    for name in "$@"; do
        [[ -n "${!name:-}" ]] || fail "required variable '$name' is not set"
    done
}

require_file() {
    local path
    for path in "$@"; do
        [[ -f "$path" ]] || fail "required file not found: $path"
    done
}

persist_env() {
    local key="$1"
    local value="$2"
    touch "$DEVSTACK_ENV_FILE"
    sed -i "/^export ${key}=.*/d" "$DEVSTACK_ENV_FILE"
    printf 'export %s=%q\n' "$key" "$value" >> "$DEVSTACK_ENV_FILE"
}

vm_ssh() {
    ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${VM_IP}" "$@"
}

vm_openstack() {
    local scope="$1"
    shift
    local remote_cmd="$*"

    if [[ -z "$remote_cmd" ]]; then
        remote_cmd="$(cat)"
    fi

    if [[ "$scope" == "admin" ]]; then
        vm_ssh "bash -lc 'export PYTHONWARNINGS=ignore; set +u; source ~/devstack/openrc admin admin; set -u; $remote_cmd'"
    else
        vm_ssh "bash -lc 'export PYTHONWARNINGS=ignore; set +u; source ~/k3s-user-openrc.sh; set -u; $remote_cmd'"
    fi
}

wait_for_server_status() {
    local name="$1"
    local wanted="$2"
    local tries="${3:-120}"
    local current
    local i

    for ((i = 0; i < tries; i++)); do
        current="$(vm_openstack tenant "openstack server show $name -f value -c status" | tr -d '\r' | xargs || true)"
        log "wait_for_server_status: server=$name attempt=$((i + 1))/$tries current_status=${current:-unknown} target=$wanted"
        if [[ "$current" == "$wanted" ]]; then
            return 0
        fi
        sleep 5
    done

    fail "server '$name' did not reach status '$wanted' (last status: ${current:-unknown})"
}

first_fixed_ip_for_net() {
    local server_name="$1"
    local net_name="$2"
    local output
    local ip

    output="$(vm_openstack tenant "openstack port list --server $server_name --network $net_name -f value" || true)"
    ip="$(printf '%s\n' "$output" | grep -oE "ip_address='([0-9]{1,3}\.){3}[0-9]{1,3}'" | head -n1 | cut -d"'" -f2)"

    if [[ -z "$ip" ]]; then
        output="$(vm_openstack tenant "openstack server show $server_name -f value -c addresses" || true)"
        ip="$(printf '%s\n' "$output" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -vE '^192\.168\.122\.' | head -n1 || true)"
    fi

    printf '%s\n' "$ip"
}

wait_for_fixed_ip_for_net() {
    local server_name="$1"
    local net_name="$2"
    local tries="${3:-60}"
    local ip=""
    local i

    for ((i = 0; i < tries; i++)); do
        ip="$(first_fixed_ip_for_net "$server_name" "$net_name" || true)"
        log "wait_for_fixed_ip_for_net: server=$server_name attempt=$((i + 1))/$tries network=$net_name ip=${ip:-none}"
        if [[ -n "$ip" ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
        sleep 5
    done

    fail "server '$server_name' did not get a fixed IP on network '$net_name'"
}

wait_for_ssh() {
    local host="$1"
    local key_path="${2:-$VM_SSH_KEY}"
    local jump_host="${3:-}"
    local tries="${4:-120}"
    local ssh_args=("${SSH_BASE_OPTS[@]}" -i "$key_path")
    local i

    if [[ -n "$jump_host" ]]; then
        ssh_args+=(-J "${SSH_USER}@${jump_host}")
    fi

    for ((i = 0; i < tries; i++)); do
        log "wait_for_ssh: host=$host attempt=$((i + 1))/$tries jump_host=${jump_host:-none}"
        if ssh "${ssh_args[@]}" "${SSH_USER}@${host}" "true" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done

    fail "ssh did not become ready on host '$host'"
}
