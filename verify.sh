#!/bin/bash
# verify.sh — independent, read-only verification of the running platform.
#
# Deliberately does NOT read 03.log…12.log: it re-derives every claim from the
# live system (host curl, Kubernetes API, OpenStack API, registry API) so a
# green log cannot mask a broken deployment.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_env
require_env MASTER_FIP REGISTRY_INTERNAL_IP REGISTRY_FIP KUBECONFIG_PATH PROD_APP_URL DEMO_APP_URL
require_env AUTH_PROXY_APP_CRED_ID AUTH_PROXY_APP_CRED_SECRET WORKER_FIP

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

http_code() {
    local code
    if ! code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"); then
        code="000"
    fi
    printf '%s' "$code"
}

echo "== 1. reachability from the host =="
FLOAT_RANGE="$(grep -oP '^FLOATING_RANGE=\K.*' "$SCRIPT_DIR/local.conf" 2>/dev/null || true)"
FLOAT_NET="${FLOAT_RANGE%%/*}"
if [[ -n "$FLOAT_NET" ]] && ip route | grep -q "$FLOAT_NET"; then
    ok "host route to $FLOAT_RANGE exists"
else
    bad "host route to $FLOAT_RANGE is missing"
fi
PROD_CODE=$(http_code "$PROD_APP_URL")
[[ "$PROD_CODE" == "200" ]] && ok "prod-app $PROD_APP_URL -> 200" \
    || bad "prod-app $PROD_APP_URL -> $PROD_CODE"
DEMO_CODE=$(http_code "$DEMO_APP_URL")
[[ "$DEMO_CODE" == "200" ]] && ok "demo-app $DEMO_APP_URL -> 200" \
    || bad "demo-app $DEMO_APP_URL -> $DEMO_CODE"

echo "== 2. cluster state =="
K=(kubectl --kubeconfig "$KUBECONFIG_PATH")
NODES_TOTAL=$("${K[@]}" get nodes --no-headers 2>/dev/null | wc -l)
NODES_READY=$("${K[@]}" get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)
if (( NODES_TOTAL >= 2 && NODES_READY == NODES_TOTAL )); then
    ok "nodes Ready: ${NODES_READY}/${NODES_TOTAL}"
else
    bad "nodes Ready: ${NODES_READY}/${NODES_TOTAL}"
fi
for app in prod-app demo-app; do
    phase=$("${K[@]}" get pod "$app" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    ready=$("${K[@]}" get pod "$app" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
    [[ "$phase" == "Running" && "$ready" == "true" ]] \
        && ok "$app is Running and Ready" || bad "$app is phase=$phase ready=$ready"
done

echo "== 3. cross-node data path (VXLAN) =="
PROD_NODE=$("${K[@]}" get pod prod-app -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
PROD_IP=$("${K[@]}" get pod prod-app -o jsonpath='{.status.podIP}' 2>/dev/null || true)
DEMO_IP=$("${K[@]}" get pod demo-app -o jsonpath='{.status.podIP}' 2>/dev/null || true)
case "$PROD_NODE" in
    *master*) bad "prod-app runs on the master ($PROD_NODE); the cross-node path is untested" ;;
    "")       bad "could not determine prod-app's node" ;;
    *)        ok "prod-app runs on ${PROD_NODE} (cross-node path is exercised)" ;;
esac
if "${K[@]}" exec demo-app -- wget -q -O /dev/null --timeout=8 "http://${PROD_IP}/" >/dev/null 2>&1; then
    ok "master pod ${DEMO_IP} -> worker pod ${PROD_IP} (VXLAN)"
else
    bad "master pod ${DEMO_IP} -> worker pod ${PROD_IP} (VXLAN)"
fi
if "${K[@]}" exec prod-app -- wget -q -O /dev/null --timeout=8 "http://${DEMO_IP}/" >/dev/null 2>&1; then
    ok "worker pod ${PROD_IP} -> master pod ${DEMO_IP} (reverse)"
else
    bad "worker pod ${PROD_IP} -> master pod ${DEMO_IP} (reverse)"
fi

echo "== 4. security group rule that allows the VXLAN =="
SG_JSON="$(vm_openstack tenant "openstack security group rule list k3s-worker-sg -f json" 2>/dev/null || true)"
if printf '%s' "$SG_JSON" | python3 -c '
import json, sys
rules = json.load(sys.stdin)
for r in rules:
    if (r.get("IP Protocol") is None and r.get("Direction") == "ingress"
            and r.get("Ethertype") == "IPv4" and r.get("IP Range") == "10.10.0.0/24"):
        sys.exit(0)
sys.exit(1)
' 2>/dev/null; then
    ok "k3s-worker-sg has ingress protocol=any from 10.10.0.0/24"
else
    bad "k3s-worker-sg is missing the protocol=any / 10.10.0.0/24 ingress rule"
fi

echo "== 5. registry: auth and content =="
REGISTRY_URL="http://${REGISTRY_FIP}:5000"
CODE=$(http_code "${REGISTRY_URL}/v2/")
[[ "$CODE" == "401" ]] && ok "external /v2/ without a token -> 401" \
    || bad "external /v2/ without a token -> $CODE (expected 401)"

TOKEN=$(curl -s -u "${AUTH_PROXY_APP_CRED_ID}:${AUTH_PROXY_APP_CRED_SECRET}" \
    "${REGISTRY_URL}/auth/token?service=zot-registry&scope=repository:rancher/mirrored-pause:pull" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("token") or d.get("access_token") or "")' 2>/dev/null || true)
[[ -n "$TOKEN" ]] && ok "token endpoint issued a JWT" || bad "token endpoint issued no JWT"

if [[ -n "$TOKEN" ]]; then
    CODE=$(http_code -H "Authorization: Bearer ${TOKEN}" \
        "${REGISTRY_URL}/v2/rancher/mirrored-pause/tags/list")
    [[ "$CODE" == "200" ]] && ok "scoped pull token -> 200" \
        || bad "scoped pull token -> $CODE (expected 200)"
    CODE=$(http_code -X PUT -H "Authorization: Bearer ${TOKEN}" \
        -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
        --data '{}' "${REGISTRY_URL}/v2/my-app/manifests/verify-scope")
    [[ "$CODE" == "401" || "$CODE" == "403" ]] \
        && ok "pull-only token rejected on push ($CODE)" \
        || bad "pull-only token allowed on push ($CODE) — scope not enforced"
fi

CATALOG=$(ssh "${SSH_BASE_OPTS[@]}" -i "$VM_SSH_KEY" "${SSH_USER}@${REGISTRY_FIP}" \
    "curl -s --max-time 10 http://127.0.0.1:5002/v2/_catalog" 2>/dev/null || true)
MISSING=""
for repo in rancher/klipper-helm rancher/klipper-lb rancher/local-path-provisioner \
            rancher/mirrored-coredns-coredns rancher/mirrored-library-busybox \
            rancher/mirrored-library-traefik rancher/mirrored-metrics-server \
            rancher/mirrored-pause; do
    printf '%s' "$CATALOG" | grep -q "\"${repo}\"" || MISSING="${MISSING} ${repo}"
done
if [[ -z "$MISSING" ]]; then
    ok "all 8 airgap images are mirrored in Zot"
else
    bad "missing from Zot:${MISSING}"
fi

echo "== 6. images really come from the private registry =="
for app in prod-app demo-app; do
    image=$("${K[@]}" get pod "$app" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)
    case "$image" in
        "${REGISTRY_INTERNAL_IP}:5000/"*) ok "$app image is ${image}" ;;
        *) bad "$app image is '${image}' (not the private registry)" ;;
    esac
done

echo "== 7. no 000000 artefacts in the recorded logs =="
if compgen -G "$SCRIPT_DIR/*.log" >/dev/null; then
    if grep -R "000000" "$SCRIPT_DIR"/*.log >/dev/null 2>&1; then
        bad "found '000000' in *.log"
    else
        ok "no '000000' in *.log"
    fi
fi

echo
printf '== result: %d passed, %d failed ==\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
