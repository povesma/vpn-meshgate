#!/usr/bin/env bash
# vps-secrets-init.sh — Run ON THE VPS to generate and wire secrets that must
# never be seen locally.
#
# Usage (from your local machine):
#   ssh user@vps "cd /path/to/project && bash vps-secrets-init.sh"
#
# What it does:
#   1. Generates GLUETUN_API_KEY if not already in .env
#   2. Creates gluetun/auth/config.toml from the generated key
#
# Safe to re-run — skips steps that are already done.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 1. Generate GLUETUN_API_KEY if missing ────────────────────────────────────
if grep -q '^GLUETUN_API_KEY=' "${SCRIPT_DIR}/.env" 2>/dev/null; then
    echo "✓ GLUETUN_API_KEY already set in .env"
else
    NEW_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    echo "GLUETUN_API_KEY=${NEW_KEY}" >> "${SCRIPT_DIR}/.env"
    echo "✓ Generated and appended GLUETUN_API_KEY to .env"
fi

# ── 2. Create gluetun/auth/config.toml from the key in .env ──────────────────
API_KEY=$(grep '^GLUETUN_API_KEY=' "${SCRIPT_DIR}/.env" | cut -d= -f2-)

if [ -z "${API_KEY}" ] || [ "${API_KEY}" = "change-me" ]; then
    echo "✗ GLUETUN_API_KEY is empty or placeholder. Fix .env first." >&2
    exit 1
fi

mkdir -p "${SCRIPT_DIR}/gluetun/auth"
cat > "${SCRIPT_DIR}/gluetun/auth/config.toml" <<EOF
[[roles]]
name = "vpn-bot"
routes = [
  "GET /v1/vpn/status",
  "PUT /v1/vpn/status",
  "GET /v1/vpn/settings",
  "PUT /v1/vpn/settings",
]
auth = "apikey"
apikey = "${API_KEY}"
EOF

echo "✓ Written gluetun/auth/config.toml"
echo ""
echo "Next: docker compose up -d --force-recreate gluetun vpn-bot"
