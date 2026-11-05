#!/bin/bash
# Lint every tracked script: bash -n, Python compile, shellcheck.
# Used by `make lint` and the pre-commit hook. No lab required.
set -euo pipefail
cd "$(dirname "$0")/.."

SHELLCHECK="${SHELLCHECK:-$PWD/vendor/shellcheck}"
status=0

mapfile -d '' SCRIPTS < <(git ls-files -z '*.sh')
mapfile -d '' PYFILES < <(git ls-files -z '*.py')

echo "== bash -n (${#SCRIPTS[@]} files) =="
for f in "${SCRIPTS[@]}"; do
    if ! bash -n "$f"; then
        echo "FAIL: bash -n $f" >&2
        status=1
    fi
done

if (( ${#PYFILES[@]} > 0 )); then
    echo "== python compile (${#PYFILES[@]} files) =="
    python3 -m py_compile "${PYFILES[@]}" || status=1
fi

if [[ -d tests ]]; then
    echo "== unit tests (token service) =="
    python3 -m unittest discover -s tests -p 'test_*.py' -q || status=1
fi

if command -v kubectl >/dev/null 2>&1; then
    echo "== kustomize render =="
    for dir in k8s/*/; do
        if ! kubectl kustomize "$dir" >/dev/null; then
            echo "FAIL: kubectl kustomize $dir" >&2
            status=1
        fi
    done
fi

if [[ -x "$SHELLCHECK" ]]; then
    echo "== shellcheck (${#SCRIPTS[@]} files) =="
    "$SHELLCHECK" -x -S warning "${SCRIPTS[@]}" || status=1
else
    echo "WARN: shellcheck not found at $SHELLCHECK — run 'make vendor-tools'" >&2
fi

if (( status == 0 )); then
    echo "lint: OK"
else
    echo "lint: FAILED" >&2
fi
exit "$status"
