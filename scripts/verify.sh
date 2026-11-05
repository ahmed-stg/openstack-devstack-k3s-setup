#!/bin/bash
# verify.sh — independent, read-only verification of the running platform.
#
# Deliberately does NOT read 03.log…12.log: it re-derives every claim from the
# live system (host curl, Kubernetes API, OpenStack API, registry API) so a
# green log cannot mask a broken deployment.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
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

K=(kubectl --kubeconfig "$KUBECONFIG_PATH")

echo "== 1. reachability from the host =="
FLOAT_RANGE="$(grep -oP '^FLOATING_RANGE=\K.*' "$ROOT_DIR/local.conf" 2>/dev/null || true)"
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
NODES_TOTAL=$("${K[@]}" get nodes --no-headers 2>/dev/null | wc -l)
NODES_READY=$("${K[@]}" get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)
if (( NODES_TOTAL >= 2 && NODES_READY == NODES_TOTAL )); then
    ok "nodes Ready: ${NODES_READY}/${NODES_TOTAL}"
else
    bad "nodes Ready: ${NODES_READY}/${NODES_TOTAL}"
fi
for app in prod-app demo-app; do
    desired=$("${K[@]}" get deploy "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
    available=$("${K[@]}" get deploy "$app" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
    if [[ -n "$desired" && "$available" == "$desired" ]]; then
        ok "$app Deployment available: ${available}/${desired}"
    else
        bad "$app Deployment available: ${available:-0}/${desired:-?}"
    fi
    ready_pods=$("${K[@]}" get pods -l "app=$app" \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
        | grep -c '^true$')
    [[ "$ready_pods" == "$desired" ]] \
        && ok "$app pods Ready: ${ready_pods}/${desired}" \
        || bad "$app pods Ready: ${ready_pods}/${desired:-?}"
done

echo "== 3. workload hygiene (probes, resources, PDB, rollout) =="
for app in prod-app demo-app; do
    probes=$("${K[@]}" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}{" "}{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null || true)
    [[ "$probes" == "/ /" ]] && ok "$app has readiness and liveness probes" \
        || bad "$app probes are '${probes:-none}' (expected '/ /')"

    limits=$("${K[@]}" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}{" "}{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)
    [[ -n "$limits" && "$limits" != " " ]] && ok "$app has CPU requests and limits ($limits)" \
        || bad "$app has no resource requests/limits"

    min_avail=$("${K[@]}" get pdb "$app" -o jsonpath='{.spec.minAvailable}' 2>/dev/null || true)
    [[ "$min_avail" =~ ^[1-9] ]] && ok "$app PDB minAvailable=$min_avail" \
        || bad "$app has no effective PDB (minAvailable=${min_avail:-none})"

    max_unavail=$("${K[@]}" get deploy "$app" -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null || true)
    [[ "$max_unavail" == "0" ]] && ok "$app rollout maxUnavailable=0" \
        || bad "$app rollout maxUnavailable=${max_unavail:-unset}"
done

echo "== 4. cross-node data path (VXLAN) =="
mapfile -t POD_ROWS < <("${K[@]}" get pods -l 'app in (prod-app,demo-app)' \
    -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.nodeName}|{.status.podIP}{"\n"}{end}' 2>/dev/null)
SRC_NAME=""; SRC_NODE=""; SRC_IP=""; DST_NAME=""; DST_NODE=""; DST_IP=""
for ((i = 0; i < ${#POD_ROWS[@]}; i++)); do
    IFS='|' read -r n1 node1 ip1 <<< "${POD_ROWS[i]}"
    for ((j = 0; j < ${#POD_ROWS[@]}; j++)); do
        IFS='|' read -r n2 node2 ip2 <<< "${POD_ROWS[j]}"
        if [[ -n "$node1" && -n "$node2" && "$node1" != "$node2" ]]; then
            SRC_NAME="$n1"; SRC_NODE="$node1"; SRC_IP="$ip1"
            DST_NAME="$n2"; DST_NODE="$node2"; DST_IP="$ip2"
            break 2
        fi
    done
done
if [[ -n "$SRC_NAME" ]]; then
    ok "cross-node pod pair found: $SRC_NAME ($SRC_NODE) <-> $DST_NAME ($DST_NODE)"
else
    bad "no two pods on different nodes (cross-node path untested)"
fi
if [[ -n "$SRC_NAME" ]]; then
    if "${K[@]}" exec "$SRC_NAME" -- wget -q -O /dev/null --timeout=8 "http://${DST_IP}/" >/dev/null 2>&1; then
        ok "$SRC_NODE pod ${SRC_IP} -> $DST_NODE pod ${DST_IP} (VXLAN)"
    else
        bad "$SRC_NODE pod ${SRC_IP} -> $DST_NODE pod ${DST_IP} (VXLAN)"
    fi
    if "${K[@]}" exec "$DST_NAME" -- wget -q -O /dev/null --timeout=8 "http://${SRC_IP}/" >/dev/null 2>&1; then
        ok "$DST_NODE pod ${DST_IP} -> $SRC_NODE pod ${SRC_IP} (reverse)"
    else
        bad "$DST_NODE pod ${DST_IP} -> $SRC_NODE pod ${SRC_IP} (reverse)"
    fi
fi

echo "== 5. security group rule that allows the VXLAN =="
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

echo "== 6. registry: auth and content =="
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

echo "== 7. images really come from the private registry =="
for app in prod-app demo-app; do
    image=$("${K[@]}" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    case "$image" in
        "${REGISTRY_INTERNAL_IP}:5000/"*) ok "$app image is ${image}" ;;
        *) bad "$app image is '${image}' (not the private registry)" ;;
    esac
done

echo "== 8. no 000000 artefacts in the recorded logs =="
if compgen -G "$ROOT_DIR/*.log" >/dev/null; then
    if grep -R "000000" "$ROOT_DIR"/*.log >/dev/null 2>&1; then
        bad "found '000000' in *.log"
    else
        ok "no '000000' in *.log"
    fi
fi

echo
printf '== result: %d passed, %d failed ==\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
