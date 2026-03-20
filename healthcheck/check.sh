#!/bin/sh

INTERVAL="${CHECK_INTERVAL:-30}"
NTFY_URL="http://127.0.0.1:80"
TOPIC="${NTFY_TOPIC:-vpn-alerts}"
IP_CHECK_URL="https://ifconfig.me"
STATE_FILE="/tmp/vpn-health-state"

log() { echo "[healthcheck] $(date '+%H:%M:%S') $*"; }

notify() {
    local title="$1"
    local msg="$2"
    local priority="${3:-high}"
    log "NOTIFY: ${title} - ${msg}"
    curl -sf -X POST "${NTFY_URL}/${TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -d "${msg}" 2>/dev/null || log "WARNING: Failed to send notification"
}

mullvad_prev="unknown"
l2tp_prev="unknown"

echo "mullvad=unknown" > "${STATE_FILE}"
echo "l2tp=unknown" >> "${STATE_FILE}"

log "Starting health check loop (interval: ${INTERVAL}s)"
log "VPS public IP: ${VPS_PUBLIC_IP}"
log "L2TP check IP: ${L2TP_CHECK_IP}"

sleep 10

while true; do
    mullvad_status="up"
    public_ip=$(curl -sf --max-time 10 "${IP_CHECK_URL}" 2>/dev/null | grep -o '[0-9.]*' | head -1)

    if [ -z "${public_ip}" ]; then
        mullvad_status="down"
    elif [ -n "${VPS_PUBLIC_IP}" ] && [ "${public_ip}" = "${VPS_PUBLIC_IP}" ]; then
        mullvad_status="down"
    fi

    if [ "${mullvad_status}" != "${mullvad_prev}" ]; then
        if [ "${mullvad_status}" = "down" ]; then
            notify "Mullvad VPN DOWN" "Mullvad tunnel is down. Kill switch active — internet blocked. Current IP: ${public_ip:-timeout}"
        elif [ "${mullvad_prev}" != "unknown" ]; then
            notify "Mullvad VPN RECOVERED" "Mullvad tunnel is back up. Exit IP: ${public_ip}" "default"
        fi
        mullvad_prev="${mullvad_status}"
        log "Mullvad: ${mullvad_status} (IP: ${public_ip:-none})"
    fi

    l2tp_status="up"
    if [ -n "${L2TP_CHECK_IP}" ]; then
        if ! ping -c 1 -W 5 "${L2TP_CHECK_IP}" >/dev/null 2>&1; then
            l2tp_status="down"
        fi

        if [ "${l2tp_status}" != "${l2tp_prev}" ]; then
            if [ "${l2tp_status}" = "down" ]; then
                notify "Company VPN DOWN" "L2TP tunnel is down. Cannot reach ${L2TP_CHECK_IP}."
            elif [ "${l2tp_prev}" != "unknown" ]; then
                notify "Company VPN RECOVERED" "L2TP tunnel is back. ${L2TP_CHECK_IP} reachable." "default"
            fi
            l2tp_prev="${l2tp_status}"
            log "L2TP: ${l2tp_status}"
        fi
    fi

    sleep "${INTERVAL}"
done
