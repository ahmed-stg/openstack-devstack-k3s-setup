#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/common.sh"
load_env
require_env REGISTRY_FIP REGISTRY_INTERNAL_IP

log_section "07_auth_proxy_vm.sh"
log "Auth Proxy is merged into the Registry VM — no separate VM needed."

# Alias the registry IPs as auth-proxy IPs so downstream scripts (08, 10, 11)
# continue to work without modification.
persist_env AUTH_PROXY_FIP "$REGISTRY_FIP"
persist_env AUTH_PROXY_INTERNAL_IP "$REGISTRY_INTERNAL_IP"

log "AUTH_PROXY_FIP=$REGISTRY_FIP  AUTH_PROXY_INTERNAL_IP=$REGISTRY_INTERNAL_IP"
