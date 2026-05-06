#!/bin/sh

INTERVAL="${CHECK_INTERVAL:-30}"
NTFY_URL="http://127.0.0.1:80"
TOPIC="${NTFY_TOPIC:-vpn-alerts}"
IP_CHECK_URL="https://ifconfig.me"
STATE_DIR="/state"
STATE_FILE="${STATE_DIR}/vpn-health-state"
INSTANCES_JSON="/shared/vpn-instances.json"
VPN_STATE_DIR="${STATE_DIR}/vpn-instance-state"

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

mkdir -p "${VPN_STATE_DIR}"

# Restore state from persistent volume (survives container restarts)
mullvad_prev="unknown"
tailscale_prev="unknown"
if [ -f "${STATE_FILE}" ]; then
    saved_mullvad=$(grep '^mullvad=' "${STATE_FILE}" | cut -d= -f2)
    saved_tailscale=$(grep '^tailscale=' "${STATE_FILE}" | cut -d= -f2)
    [ -n "${saved_mullvad}" ] && mullvad_prev="${saved_mullvad}"
    [ -n "${saved_tailscale}" ] && tailscale_prev="${saved_tailscale}"
    log "Restored state: mullvad=${mullvad_prev}, tailscale=${tailscale_prev}"
fi

log "Starting health check loop (interval: ${INTERVAL}s)"
log "VPS public IP: ${VPS_PUBLIC_IP}"

log "Waiting for ntfy to be ready..."
ntfy_attempts=0
while [ $ntfy_attempts -lt 30 ]; do
    if curl -sf --max-time 3 "${NTFY_URL}/v1/health" >/dev/null 2>&1; then
        log "ntfy is ready"
        break
    fi
    sleep 2
    ntfy_attempts=$((ntfy_attempts + 1))
done
if [ $ntfy_attempts -ge 30 ]; then
    log "WARNING: ntfy not ready after 60s, starting checks anyway"
fi

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
        printf 'mullvad=%s\ntailscale=%s\n' "${mullvad_prev}" "${tailscale_prev}" > "${STATE_FILE}"
        log "Mullvad: ${mullvad_status} (IP: ${public_ip:-none})"
    fi

    if [ -f "${INSTANCES_JSON}" ]; then
        for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
            name=$(echo "$row" | jq -r '.name')
            check_ip=$(echo "$row" | jq -r '.check_ip')
            [ -z "${check_ip}" ] || [ "${check_ip}" = "" ] && continue

            inst_status="up"
            if ! ping -c 1 -W 5 "${check_ip}" >/dev/null 2>&1; then
                inst_status="down"
            fi

            prev_status="unknown"
            state_file="${VPN_STATE_DIR}/${name}"
            [ -f "${state_file}" ] && prev_status=$(cat "${state_file}")
            if [ "${inst_status}" != "${prev_status}" ]; then
                if [ "${inst_status}" = "down" ]; then
                    notify "${name} VPN DOWN" "Tunnel is down. Cannot reach ${check_ip}."
                elif [ "${prev_status}" != "unknown" ]; then
                    notify "${name} VPN RECOVERED" "Tunnel is back. ${check_ip} reachable." "default"
                fi
                echo "${inst_status}" > "${state_file}"
                log "${name}: ${inst_status}"
            fi
        done
    fi

    # Check Tailscale exit node: tailscale0 interface must exist in our namespace.
    # If gluetun was recreated but tailscale container wasn't, the interface disappears.
    tailscale_status="up"
    if ! ip link show tailscale0 >/dev/null 2>&1; then
        tailscale_status="down"
    fi

    if [ "${tailscale_status}" != "${tailscale_prev}" ]; then
        if [ "${tailscale_status}" = "down" ]; then
            notify "Tailscale EXIT NODE DOWN" "tailscale0 interface missing — exit node is offline. Namespace containers may need recreating." "urgent"
        elif [ "${tailscale_prev}" != "unknown" ]; then
            notify "Tailscale EXIT NODE RECOVERED" "tailscale0 interface is back. Exit node operational." "default"
        fi
        tailscale_prev="${tailscale_status}"
        printf 'mullvad=%s\ntailscale=%s\n' "${mullvad_prev}" "${tailscale_prev}" > "${STATE_FILE}"
        log "Tailscale: ${tailscale_status}"
    fi

    sleep "${INTERVAL}"
done
