#!/bin/sh
# mullvad-switcher — watches /data/switch-request for a country name written
# by vpn-bot, performs a full gluetun recreate with the new country, then
# brings all gluetun-namespace containers back up and reports via ntfy.
#
# Communication contract with vpn-bot:
#   /data/switch-request  — vpn-bot writes "<country>" to trigger a switch
#   /data/switch-result   — switcher writes "ok <ip>" or "err <msg>" when done

REQUEST_FILE="/data/switch-request"
RESULT_FILE="/data/switch-result"
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-vpn}"
COMPOSE_DIR="${COMPOSE_PROJECT_DIR:-/project}"
NTFY_URL="http://172.29.0.10:80"
NTFY_TOPIC="${NTFY_CMD_TOPIC:-vpn-cmd}"
GLUETUN_HEALTH_URL="http://172.29.0.10:9999/v1/publicip/ip"

# Containers that share gluetun's network namespace — must be recreated after
# gluetun is replaced, otherwise they retain a reference to the dead namespace.
GLUETUN_DEPENDENTS="ntfy healthcheck route-init tailscale vpn-bot"

log() { echo "[switcher] $(date '+%H:%M:%S') $*"; }

compose() {
    docker compose --project-directory "${COMPOSE_DIR}" --project-name "${COMPOSE_PROJECT}" "$@"
}

ntfy_reply() {
    local title="$1" msg="$2" priority="${3:-default}"
    curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -d "${msg}" 2>/dev/null || log "WARNING: ntfy unreachable"
}

wait_gluetun_healthy() {
    local i=0
    while [ $i -lt 30 ]; do
        sleep 3
        if curl -sf "${GLUETUN_HEALTH_URL}" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

do_switch() {
    local country="$1"
    log "Switching to: ${country}"
    ntfy_reply "Switching Mullvad" "⚠️ Switching to ${country}... (~30s downtime)" "high"

    log "Recreating gluetun with SERVER_COUNTRIES=${country}..."
    SERVER_COUNTRIES="${country}" compose up -d --force-recreate gluetun 2>&1 \
        | while IFS= read -r line; do log "compose: ${line}"; done

    log "Waiting for gluetun healthy..."
    if ! wait_gluetun_healthy; then
        log "ERROR: gluetun did not recover within 90s"
        echo "err timeout" > "${RESULT_FILE}"
        ntfy_reply "Switch Failed" "⚠️ Gluetun did not recover in 90s switching to ${country}." "urgent"
        return
    fi

    log "Gluetun healthy. Recreating namespace-dependent containers..."
    # shellcheck disable=SC2086
    compose up -d --force-recreate ${GLUETUN_DEPENDENTS} 2>&1 \
        | while IFS= read -r line; do log "compose: ${line}"; done

    local new_ip
    new_ip=$(curl -sf --max-time 15 https://ifconfig.me 2>/dev/null || echo "unavailable")
    log "Switch complete. New IP: ${new_ip}"
    echo "ok ${new_ip}" > "${RESULT_FILE}"
    ntfy_reply "Mullvad Switched" "✅ Mullvad → ${country}. New IP: ${new_ip}" "high"
}

log "mullvad-switcher starting"
rm -f "${REQUEST_FILE}" "${RESULT_FILE}"

while true; do
    if [ -f "${REQUEST_FILE}" ]; then
        country=$(cat "${REQUEST_FILE}")
        rm -f "${REQUEST_FILE}" "${RESULT_FILE}"
        if [ -n "${country}" ]; then
            do_switch "${country}"
        fi
    fi
    sleep 2
done
