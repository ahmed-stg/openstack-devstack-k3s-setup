#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVSTACK_ENV_FILE="$ROOT_DIR/devstack_env"

if [[ ! -f "$DEVSTACK_ENV_FILE" ]]; then
    echo "ERROR: $DEVSTACK_ENV_FILE not found" >&2
    exit 1
fi

vm_name_line="$(grep '^export VM_NAME=' "$DEVSTACK_ENV_FILE" || true)"
vm_ip_line="$(grep '^export VM_IP=' "$DEVSTACK_ENV_FILE" || true)"
vm_ssh_key_line="$(grep '^export VM_SSH_KEY=' "$DEVSTACK_ENV_FILE" || true)"

if [[ -z "$vm_name_line" || -z "$vm_ip_line" || -z "$vm_ssh_key_line" ]]; then
    echo "ERROR: devstack_env must contain VM_NAME, VM_IP, and VM_SSH_KEY before reset" >&2
    exit 1
fi

cat > "$DEVSTACK_ENV_FILE" <<EOF
$vm_name_line
$vm_ip_line
$vm_ssh_key_line
EOF

rm -f \
    "$ROOT_DIR/auth-proxy-jwt.pem" \
    "$ROOT_DIR/auth-proxy-jwt.pub.pem" \
    "$ROOT_DIR/k3s-key.pem" \
    "$ROOT_DIR/k3s-user-openrc.sh" \
    "$ROOT_DIR/k3s-kubeconfig.yaml" \
    "$ROOT_DIR/master_fip.txt" \
    "$ROOT_DIR"/{03,04,05,06,07,08,09,10,11}.log \
    "$ROOT_DIR"/{3,4,5,6,7}.log \
    "$ROOT_DIR"/revert.log \
    "$ROOT_DIR"/reset.log \
    "$ROOT_DIR"/*_retry*.log \
    "$ROOT_DIR"/*_test_run.log \
    "$ROOT_DIR"/*_retry_merged.log \
    "$ROOT_DIR"/*_retry_final*.log \
    "$ROOT_DIR"/{3,4,5,6,7}log.md \
    "$ROOT_DIR"/k3slog.md

echo "Reset devstack_env to VM base values and removed generated rerun artifacts."
