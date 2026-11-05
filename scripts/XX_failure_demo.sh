#!/bin/bash
# XX_failure_demo.sh — three operational drills against a running lab.
#
#   1. drain the worker            -> Deployment reschedules, PDB keeps one copy
#   2. kill the registry mid-pull  -> new pods enter ImagePullBackOff, old ones
#                                     keep serving; recovery is automatic
#   3. rotate the app credential   -> new imagePullSecret, old credential revoked
#
# It mutates the lab on purpose, but the trap (and the final steps) restore a
# healthy state: the worker is uncordoned, nginx is running, and the rotated
# credential is the one persisted in devstack_env.
#
# Usage: ./scripts/XX_failure_demo.sh 2>&1 | tee failure_demo.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
load_env
require_env KUBECONFIG_PATH MASTER_FIP REGISTRY_FIP REGISTRY_INTERNAL_IP \
  AUTH_PROXY_FIP AUTH_PROXY_APP_CRED_ID AUTH_PROXY_APP_CRED_SECRET \
  PROD_APP_URL VM_SSH_KEY

K=(kubectl --kubeconfig "$KUBECONFIG_PATH")
INTERNAL_REGISTRY="${REGISTRY_INTERNAL_IP}:5000"
WORKER_NODE="$("${K[@]}" get nodes -o name | sed 's|^node/||' | grep worker | head -1 || true)"
DRAINED=0

cleanup() {
    if [[ "$DRAINED" == "1" && -n "$WORKER_NODE" ]]; then
        "${K[@]}" uncordon "$WORKER_NODE" >/dev/null 2>&1 || true
    fi
    ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${REGISTRY_FIP}" \
        "sudo systemctl start nginx" >/dev/null 2>&1 || true
}
trap cleanup EXIT

http_code() {
    local code
    if ! code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1"); then
        code="000"
    fi
    printf '%s' "$code"
}

assert_http_200() {
    local label="$1" url="$2" code
    code=$(http_code "$url")
    if [[ "$code" == "200" ]]; then
        log "PASS: $label still serves HTTP 200"
    else
        fail "$label returned HTTP $code (expected 200)"
    fi
}

wait_for_rollout() {
    local app="$1" timeout="${2:-240s}"
    "${K[@]}" rollout status "deployment/$app" --timeout="$timeout" >/dev/null
    log "PASS: $app rolled out"
}

pod_on_node() {
    local app="$1" node="$2"
    "${K[@]}" get pods -l "app=$app" \
        -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.nodeName}{"\n"}{end}' \
        | awk -F'|' -v n="$node" '$2 == n {print $1; exit}'
}

log_section "FAILURE DRILLS — $(date -Is)"

if [[ -z "$WORKER_NODE" ]]; then
    fail "no worker node found"
fi
log "worker node: $WORKER_NODE"
log "prod URL:    $PROD_APP_URL"
"${K[@]}" get deploy,pdb -o wide

# ── Drill 1: drain the worker ─────────────────────────────────────────
log_section "Drill 1/3 — drain the worker under load"
BEFORE_PODS="$("${K[@]}" get pods -l 'app in (prod-app,demo-app)' -o wide --no-headers)"
printf '%s\n' "$BEFORE_PODS"

DRAINED=1
log "Draining $WORKER_NODE (PDB minAvailable=1 should allow exactly one eviction per app)..."
"${K[@]}" drain "$WORKER_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=240s
wait_for_rollout prod-app
wait_for_rollout demo-app
assert_http_200 "prod-app" "$PROD_APP_URL"

log "Pods after the drain:"
"${K[@]}" get pods -l 'app in (prod-app,demo-app)' -o wide --no-headers

log "Uncordoning $WORKER_NODE..."
"${K[@]}" uncordon "$WORKER_NODE"
DRAINED=0
wait_for_rollout prod-app
wait_for_rollout demo-app
log "PASS: cluster returned to a schedulable state"

# ── Drill 2: registry outage during an image pull ─────────────────────
log_section "Drill 2/3 — kill the registry while a pod pulls"
log "Stopping nginx on registry-01 ($REGISTRY_FIP)..."
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${REGISTRY_FIP}" \
    "sudo systemctl stop nginx"
if ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${REGISTRY_FIP}" \
    "systemctl is-active --quiet nginx"; then
    fail "nginx is still active on the registry VM"
fi

log "Forcing a fresh pull (imagePullPolicy=Always) with rollout restart..."
"${K[@]}" rollout restart deployment/prod-app >/dev/null

FAIL_STATE=""
for _ in $(seq 1 60); do
    FAIL_STATE="$("${K[@]}" get pods -l app=prod-app --no-headers 2>/dev/null \
        | grep -E 'ErrImagePull|ImagePullBackOff' || true)"
    [[ -n "$FAIL_STATE" ]] && break
    sleep 2
done
if [[ -n "$FAIL_STATE" ]]; then
    log "PASS: the new pod is failing to pull:"
    printf '%s\n' "$FAIL_STATE"
else
    fail "expected ImagePullBackOff/ErrImagePull while nginx was down, saw none"
fi

# maxUnavailable=0 means the old ReplicaSet must keep serving.
assert_http_200 "prod-app during registry outage" "$PROD_APP_URL"

log "Restarting nginx; kubelet retries with backoff, no manual action..."
ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${REGISTRY_FIP}" \
    "sudo systemctl start nginx"
wait_for_rollout prod-app 300s
assert_http_200 "prod-app after recovery" "$PROD_APP_URL"
"${K[@]}" get pods -l app=prod-app -o wide --no-headers

# ── Drill 3: rotate the deployment credential ─────────────────────────
log_section "Drill 3/3 — rotate the application credential"
OLD_ID="$AUTH_PROXY_APP_CRED_ID"
OLD_SECRET="$AUTH_PROXY_APP_CRED_SECRET"
log "Current credential: $OLD_ID"

log "Creating a replacement Keystone application credential..."
NEW_JSON="$(vm_openstack tenant "openstack application credential create deploy-rotate-$(date +%s) --unrestricted -f json")"
NEW_ID="$(printf '%s' "$NEW_JSON" | python3 -c "import sys,json; s=''.join(sys.stdin); d=json.loads(s[s.index('{'):]); print(d.get('id') or d.get('ID'))")"
NEW_SECRET="$(printf '%s' "$NEW_JSON" | python3 -c "import sys,json; s=''.join(sys.stdin); d=json.loads(s[s.index('{'):]); print(d.get('secret') or d.get('Secret'))")"
[[ -n "$NEW_ID" && -n "$NEW_SECRET" ]] || fail "could not parse the new credential"
log "New credential: $NEW_ID"

log "Updating the registry-auth imagePullSecret..."
kubectl --kubeconfig "$KUBECONFIG_PATH" create secret docker-registry registry-auth \
  --docker-server="$INTERNAL_REGISTRY" \
  --docker-username="$NEW_ID" \
  --docker-password="$NEW_SECRET" \
  --dry-run=client -o yaml \
  | kubectl --kubeconfig "$KUBECONFIG_PATH" apply -f -

log "Restarting prod-app so every replica uses the new secret..."
"${K[@]}" rollout restart deployment/prod-app >/dev/null
wait_for_rollout prod-app 240s
assert_http_200 "prod-app with the rotated credential" "$PROD_APP_URL"

log "Revoking the old credential in Keystone..."
vm_openstack tenant "openstack application credential delete $OLD_ID" >/dev/null

TOKEN_URL="http://${AUTH_PROXY_FIP}:5000/auth/token?service=zot-registry&scope=repository:my-app:pull"
OLD_CODE="$(curl -s -o /dev/null -w '%{http_code}' -u "${OLD_ID}:${OLD_SECRET}" "$TOKEN_URL" || true)"
NEW_CODE="$(curl -s -o /dev/null -w '%{http_code}' -u "${NEW_ID}:${NEW_SECRET}" "$TOKEN_URL" || true)"
[[ "$OLD_CODE" == "401" ]] && log "PASS: revoked credential is rejected (401)" \
    || fail "old credential still gets HTTP $OLD_CODE from /auth/token"
[[ "$NEW_CODE" == "200" ]] && log "PASS: new credential is accepted (200)" \
    || fail "new credential got HTTP $NEW_CODE from /auth/token"

persist_env AUTH_PROXY_APP_CRED_ID "$NEW_ID"
persist_env AUTH_PROXY_APP_CRED_SECRET "$NEW_SECRET"
log "devstack_env updated with the new credential (used by 12 for future pushes)."

# Put one replica of each app back on each node: a drain does not rebalance
# existing pods, and verify.sh exercises a real cross-node pod-to-pod path.
log "Rebalancing replicas across both nodes..."
"${K[@]}" rollout restart deployment/prod-app deployment/demo-app >/dev/null
wait_for_rollout prod-app
wait_for_rollout demo-app
"${K[@]}" get pods -l 'app in (prod-app,demo-app)' -o wide --no-headers

log_section "FAILURE DRILLS COMPLETE"
log "1. worker drain: PDB minAvailable=1 allowed one eviction, no outage"
log "2. registry outage: new pods ImagePullBackOff, old replicas kept serving,"
log "   recovery was automatic once nginx restarted"
log "3. credential rotation: secret replaced, rollout green, old credential 401"
