#!/bin/bash
# XX_RUN_FROM_SNAPSHOT.sh
# Revert DevStack VM to PostStack_Ready snapshot, reset state, and run the full stack.
# Usage: sudo bash XX_RUN_FROM_SNAPSHOT.sh   (sudo needed for virsh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VM_NAME="BaseDevStack"
SNAPSHOT="PostStack_Ready"
DEVSTACK_ENV_FILE="$SCRIPT_DIR/devstack_env"

# ── 0. Pre-flight: ensure devstack_env has the base VM info ──────────
if [[ ! -f "$DEVSTACK_ENV_FILE" ]]; then
    echo "ERROR: $DEVSTACK_ENV_FILE not found. Create it with VM_NAME, VM_IP, VM_SSH_KEY." >&2
    exit 1
fi

vm_name_line="$(grep '^export VM_NAME=' "$DEVSTACK_ENV_FILE" || true)"
vm_ip_line="$(grep '^export VM_IP=' "$DEVSTACK_ENV_FILE" || true)"
vm_ssh_key_line="$(grep '^export VM_SSH_KEY=' "$DEVSTACK_ENV_FILE" || true)"

if [[ -z "$vm_name_line" || -z "$vm_ip_line" || -z "$vm_ssh_key_line" ]]; then
    echo "ERROR: devstack_env must contain VM_NAME, VM_IP, and VM_SSH_KEY." >&2
    exit 1
fi

# ── 1. Revert VM to snapshot ─────────────────────────────────────────
echo "[1/3] Reverting $VM_NAME to snapshot '$SNAPSHOT'..."
sudo virsh destroy "$VM_NAME" 2>/dev/null || true
sudo virsh snapshot-revert --domain "$VM_NAME" --snapshotname "$SNAPSHOT"
sudo virsh start "$VM_NAME"
echo "      VM reverted and started. Waiting 30s for boot..."
sleep 30

# ── 2. Reset env vars and clean artifacts ─────────────────────────────
echo "[2/3] Resetting devstack_env and cleaning artifacts..."
cat > "$DEVSTACK_ENV_FILE" <<EOF
$vm_name_line
$vm_ip_line
$vm_ssh_key_line
EOF

# --- Generated keys & credentials ---
rm -f \
    "$SCRIPT_DIR/auth-proxy-jwt.pem" \
    "$SCRIPT_DIR/auth-proxy-jwt.pub.pem" \
    "$SCRIPT_DIR/k3s-key.pem" \
    "$SCRIPT_DIR/k3s-user-openrc.sh" \
    "$SCRIPT_DIR/k3s-kubeconfig.yaml" \
    "$SCRIPT_DIR/master_fip.txt"

# --- Step logs (fresh run produces new ones) ---
rm -f "$SCRIPT_DIR"/{03,04,05,06,07,08,09,10,11,12}.log
rm -f "$SCRIPT_DIR"/{3,4,5,6,7}.log          # old naming
rm -f "$SCRIPT_DIR"/revert.log "$SCRIPT_DIR"/reset.log

# --- Retry / debug logs from previous attempts ---
rm -f "$SCRIPT_DIR"/*_retry*.log
rm -f "$SCRIPT_DIR"/*_test_run.log
rm -f "$SCRIPT_DIR"/*_retry_merged.log
rm -f "$SCRIPT_DIR"/*_retry_final*.log

# --- Old markdown logs ---
rm -f "$SCRIPT_DIR"/{3,4,5,6,7}log.md
rm -f "$SCRIPT_DIR"/k3slog.md

# Clear stale SSH known-hosts for the floating IP range
for ip in $(seq 200 210); do
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "192.168.122.$ip" 2>/dev/null || true
done

echo "      Env reset. Keys, logs, and stale SSH entries cleaned."

# ── 3. Run the full stack (03 → 12) ──────────────────────────────────
run_step() {
    local number="$1"
    local script="$2"
    local log_file="${number}.log"

    printf '\n═══ Step %s: %s ═══\n' "$number" "$script"
    if ! "./$script" 2>&1 | tee "$log_file"; then
        echo "" >&2
        echo "ERROR: step $number ($script) failed — see $log_file" >&2
        exit 1
    fi
}

echo "[3/3] Running full stack..."
echo ""

run_step 03 03_openstack_bootstrap.sh
run_step 04 04_k3s_master_vm.sh
run_step 05 05_registry_vm.sh
run_step 06 06_zot_install.sh
run_step 07 07_auth_proxy_vm.sh
run_step 08 08_auth_proxy_install.sh
run_step 09 09_k3s_cluster_install.sh
run_step 10 10_registry_smoke_test.sh
run_step 11 11_enable_zot_auth.sh
run_step 12 12_demo_deploy.sh

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FULL STACK COMPLETE"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Apps are live and reachable. To interact:"
echo "  1. source devstack_env"
echo "  2. curl \$PROD_APP_URL    # nginx:alpine"
echo "  3. curl \$DEMO_APP_URL    # busybox httpd"
echo ""
