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
    local old_ip old_country switch_ok=1
    old_ip=$(get_vpn_ip)
    [ -z "${old_ip}" ] && old_ip="unknown"
    old_country=$(docker exec "${GLUETUN_CONTAINER}" printenv SERVER_COUNTRIES 2>/dev/null)
    log "Switching to: ${country} (current IP: ${old_ip}, from: ${old_country:-unknown})"
    ntfy_reply "Switching Mullvad" "⚠️ Switching to ${country}... (~30s downtime)" "high"

    log "Recreating gluetun with MULLVAD_COUNTRY=${country}..."
    export MULLVAD_COUNTRY="${country}"
    compose up -d --force-recreate gluetun 2>&1 \
        | while IFS= read -r line; do log "compose: ${line}"; done

    log "Waiting for gluetun healthy..."
    if ! wait_gluetun_healthy; then
        switch_ok=0
        log "ERROR: gluetun did not recover within 90s — rolling back to ${old_country:-default}"

        # Rollback: restore previous country and recreate gluetun
        if [ -n "${old_country}" ]; then
            export MULLVAD_COUNTRY="${old_country}"
        else
            unset MULLVAD_COUNTRY
        fi
        compose up -d --force-recreate gluetun 2>&1 \
            | while IFS= read -r line; do log "rollback: ${line}"; done

        if ! wait_gluetun_healthy; then
            log "ERROR: rollback also failed — force-recreating dependents with --no-deps"
            # Bypass depends_on health conditions so containers at least start
            # shellcheck disable=SC2086
            compose up -d --force-recreate --no-deps ${GLUETUN_DEPENDENTS} 2>&1 \
                | while IFS= read -r line; do log "force: ${line}"; done
            compose restart dnsmasq 2>&1 \
                | while IFS= read -r line; do log "force: ${line}"; done
            echo "err rollback-failed" > "${RESULT_FILE}"
            ntfy_reply "Switch Failed" "⚠️ Switch to ${country} failed AND rollback to ${old_country:-default} failed. Manual intervention needed." "urgent"
            return
        fi
        log "Rollback successful — gluetun healthy with ${old_country:-default}"
    fi

    log "Gluetun healthy. Recreating namespace-dependent containers..."
    # shellcheck disable=SC2086
    compose up -d --force-recreate ${GLUETUN_DEPENDENTS} 2>&1 \
        | while IFS= read -r line; do log "compose: ${line}"; done

    # Restart dnsmasq so it re-reads company DNS IP (may have changed
    # if L2TP reconnected during the switch) and refreshes its routes.
    log "Restarting dnsmasq to refresh company DNS config..."
    compose restart dnsmasq 2>&1 \
        | while IFS= read -r line; do log "compose: ${line}"; done

    if [ "${switch_ok}" = "0" ]; then
        local rollback_ip
        rollback_ip=$(get_vpn_ip)
        echo "err timeout" > "${RESULT_FILE}"
        ntfy_reply "Switch Failed — Rolled Back" "⚠️ Switch to ${country} timed out. Rolled back to ${old_country:-default}. IP: ${rollback_ip:-unavailable}" "urgent"
        return
    fi

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

WATCHDOG_INTERVAL=30
_watchdog_ticks=0

# Check if all gluetun-namespace containers are attached to the current
# gluetun container. If any are stale (pointing to a dead container ID),
# recreate them all. This heals namespace desync caused by gluetun being
# recreated outside the normal country-switch flow (e.g. manual restart).
check_namespace_desync() {
    local gluetun_id
    gluetun_id=$(docker inspect --format='{{.Id}}' "${GLUETUN_CONTAINER}" 2>/dev/null)
    [ -z "${gluetun_id}" ] && return  # gluetun itself is down, skip

    local stale=0
    for svc in ${GLUETUN_DEPENDENTS}; do
        local net_mode peer_id
        net_mode=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "${svc}" 2>/dev/null)
        peer_id="${net_mode#container:}"
        if [ "${peer_id}" != "${gluetun_id}" ]; then
            log "WATCHDOG: ${svc} has stale namespace ref (${peer_id:-missing}), gluetun is ${gluetun_id}"
            stale=1
            break
        fi
    done

    if [ "${stale}" = "1" ]; then
        log "WATCHDOG: namespace desync detected — recreating gluetun-namespace containers"
        ntfy_reply "Namespace Desync" "⚠️ Gluetun namespace desync detected — auto-healing containers" "high"
        # shellcheck disable=SC2086
        compose up -d --force-recreate ${GLUETUN_DEPENDENTS} 2>&1 \
            | while IFS= read -r line; do log "watchdog: ${line}"; done
        log "WATCHDOG: heal complete"
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

    _watchdog_ticks=$((_watchdog_ticks + 1))
    if [ $((_watchdog_ticks * 2)) -ge ${WATCHDOG_INTERVAL} ]; then
        _watchdog_ticks=0
        check_namespace_desync
    fi

    sleep 2
done
