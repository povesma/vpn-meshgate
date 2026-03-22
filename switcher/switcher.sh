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
COMPOSE_FILE="/project/docker-compose.yml"
COMPOSE_HOST_DIR="${COMPOSE_PROJECT_DIR:-/project}"
NTFY_URL="http://172.29.0.10:80"
NTFY_TOPIC="${NTFY_CMD_TOPIC:-vpn-cmd}"
GLUETUN_CONTAINER="gluetun"
IP_CHECK_URL="https://ifconfig.me/ip"

# Containers that share gluetun's network namespace — must be recreated after
# gluetun is replaced, otherwise they retain a reference to the dead namespace.
GLUETUN_DEPENDENTS="ntfy healthcheck route-init tailscale vpn-bot"

log() { echo "[switcher] $(date '+%H:%M:%S') $*"; }

compose() {
    docker compose -f "${COMPOSE_FILE}" --env-file /project/.env --project-directory "${COMPOSE_HOST_DIR}" --project-name "${COMPOSE_PROJECT}" "$@"
}

ntfy_reply() {
    local title="$1" msg="$2" priority="${3:-default}"
    curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -d "${msg}" 2>/dev/null || log "WARNING: ntfy unreachable"
}

get_vpn_ip() {
    docker exec "${GLUETUN_CONTAINER}" wget -qO- --timeout=15 "${IP_CHECK_URL}" 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

wait_gluetun_healthy() {
    local i=0
    while [ $i -lt 30 ]; do
        sleep 3
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "${GLUETUN_CONTAINER}" 2>/dev/null)
        if [ "${health}" = "healthy" ]; then
            return 0
        fi
        log "  gluetun health: ${health:-unknown} (attempt $((i+1))/30)"
        i=$((i + 1))
    done
    return 1
}

do_switch() {
    local country="$1"
    local old_ip
    old_ip=$(get_vpn_ip)
    [ -z "${old_ip}" ] && old_ip="unknown"
    log "Switching to: ${country} (current IP: ${old_ip})"
    ntfy_reply "Switching Mullvad" "⚠️ Switching to ${country}... (~30s downtime)" "high"

    log "Recreating gluetun with MULLVAD_COUNTRY=${country}..."
    export MULLVAD_COUNTRY="${country}"
    compose up -d --force-recreate gluetun 2>&1 \
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
    new_ip=$(get_vpn_ip)
    [ -z "${new_ip}" ] && new_ip="unavailable"

    if [ "${new_ip}" = "${old_ip}" ] && [ "${new_ip}" != "unavailable" ]; then
        log "WARNING: IP unchanged after switch (${new_ip})"
        echo "err same-ip" > "${RESULT_FILE}"
        ntfy_reply "Switch Failed" "⚠️ Country switch to ${country} failed — IP unchanged (${new_ip}). Server may not have changed." "urgent"
    else
        log "Switch complete. ${old_ip} → ${new_ip}"
        echo "ok ${new_ip}" > "${RESULT_FILE}"
        ntfy_reply "Mullvad Switched" "✅ Mullvad → ${country}. IP: ${old_ip} → ${new_ip}" "high"
    fi
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
