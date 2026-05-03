#!/bin/bash
# Source this file: 'source source_env.sh'

ROOT_DIR="$(pwd)"
export DEVSTACK_ENV_FILE="$ROOT_DIR/devstack_env"

if [[ -f "$DEVSTACK_ENV_FILE" ]]; then
    source "$DEVSTACK_ENV_FILE"
    echo "Environment loaded from $DEVSTACK_ENV_FILE"
else
    echo "No devstack_env file found in $ROOT_DIR"
fi

# Define standard SSH options to match scripts
export SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR"
export VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/id_ed25519}"

echo "SSH_OPTS exported. Use it like: ssh $SSH_OPTS -i $VM_SSH_KEY ubuntu@\$VM_IP"
