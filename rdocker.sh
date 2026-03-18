#!/usr/bin/env bash
# rdocker.sh — Run docker commands on the remote VPS via SSH.
#
# Reads REMOTE_HOST, REMOTE_PATH, and optional SSH_KEY from .env.
# All arguments are forwarded to `docker` on the remote host.
# The remote hostname is never printed.
#
# Usage:
#   ./rdocker.sh compose up -d
#   ./rdocker.sh compose ps
#   ./rdocker.sh compose logs -f gluetun
#   ./rdocker.sh exec gluetun curl ifconfig.me

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REMOTE_HOST=""
REMOTE_PATH=""
SSH_KEY=""
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
for _var in REMOTE_HOST REMOTE_PATH; do
    if [[ -z "${!_var}" ]]; then
        echo "✗ $_var not set. Add it to .env" >&2
        exit 1
    fi
done

SSH_OPTS=(-T -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

if [[ $# -eq 0 ]]; then
    echo "Usage: ./rdocker.sh <docker-args...>" >&2
    echo "Example: ./rdocker.sh compose ps" >&2
    exit 1
fi

ARGS=""
for arg in "$@"; do
    ARGS="$ARGS '${arg//\'/\'\\\'\'}'"
done
exec ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "cd '$REMOTE_PATH' && docker $ARGS"
