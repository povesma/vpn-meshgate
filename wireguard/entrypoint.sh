#!/bin/sh
set -e

NTFY_URL="http://172.29.0.10:80"
NTFY_TOPIC="${NTFY_TOPIC:-vpn-alerts}"
INSTANCE="${VPN_INSTANCE_NAME:-wireguard}"
BACKOFF_STEP=0
CONSECUTIVE_FAILURES=0
DISCONNECT_TS=""
HANDSHAKE_TIMEOUT=180

log() { echo "[vpn-${INSTANCE}] $*"; }

notify() {
    local title="$1" msg="$2" priority="${3:-high}"
    log "NOTIFY: ${title} — ${msg}"
    curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -d "${msg}" 2>/dev/null || log "WARNING: ntfy unreachable"
}

backoff_sleep() {
    local delays="15 30 60 120 300"
    local delay
    delay=$(echo "${delays}" | tr ' ' '\n' | sed -n "$((BACKOFF_STEP + 1))p")
    [ -z "${delay}" ] && delay=300
    log "Retrying in ${delay}s (attempt $((BACKOFF_STEP + 1)))"
    sleep "${delay}"
    BACKOFF_STEP=$((BACKOFF_STEP + 1))
}

reset_backoff() {
    BACKOFF_STEP=0
    CONSECUTIVE_FAILURES=0
}

configure() {
    log "Starting WireGuard client"
    log "CIDRs: ${INSTANCE_CIDRS}"

    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || \
        log "WARNING: ip_forward read-only"
    sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true
}

connect() {
    log "Bringing up wg0"
    if ! wg-quick up wg0 2>&1; then
        log "ERROR: wg-quick up failed"
        return 1
    fi

    if ip link show wg0 >/dev/null 2>&1; then
        log "wg0 is UP"
        return 0
    fi

    log "ERROR: wg0 did not come up"
    return 1
}

disconnect() {
    wg-quick down wg0 2>/dev/null || true
}

setup_routing() {
    log "Adding routes for INSTANCE_CIDRS"
    IFS=','
    for cidr in ${INSTANCE_CIDRS}; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if [ -n "$cidr" ]; then
            log "  route add ${cidr} dev wg0"
            ip route add "${cidr}" dev wg0 2>/dev/null || log "  (route exists)"
        fi
    done
    unset IFS

    log "Adding MASQUERADE for forwarded traffic on wg0"
    iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

    log "Adding MSS clamping on wg0"
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o wg0 \
        -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i wg0 \
        -j TCPMSS --clamp-mss-to-pmtu

    log "WireGuard client ready"
    ip route
}

monitor_wg0() {
    while ip link show wg0 >/dev/null 2>&1; do
        sleep 10
        local handshake
        handshake=$(wg show wg0 latest-handshakes 2>/dev/null \
            | awk '{print $2}' | head -1)
        if [ -n "${handshake}" ] && [ "${handshake}" != "0" ]; then
            local now age
            now=$(date +%s)
            age=$((now - handshake))
            if [ "${age}" -gt "${HANDSHAKE_TIMEOUT}" ]; then
                log "WARNING: Last handshake ${age}s ago (threshold: ${HANDSHAKE_TIMEOUT}s)"
                return 1
            fi
        fi
    done
}

# === Main ===

configure

while true; do
    disconnect

    if connect; then
        setup_routing
        reset_backoff

        if [ -n "${DISCONNECT_TS}" ]; then
            local_downtime=$(( $(date +%s) - DISCONNECT_TS ))
            notify "${INSTANCE} VPN Up" \
                "WireGuard reconnected. Downtime: ${local_downtime}s."
            DISCONNECT_TS=""
        else
            log "Initial connection established"
        fi

        monitor_wg0

        DISCONNECT_TS=$(date +%s)
        log "wg0 lost or stale — tunnel disconnected"
        notify "${INSTANCE} VPN Down" "WireGuard tunnel lost. Reconnecting..."
    else
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        log "Connection failed (attempt ${CONSECUTIVE_FAILURES})"

        if [ "${CONSECUTIVE_FAILURES}" -eq 3 ]; then
            notify "${INSTANCE} VPN Failing" \
                "WireGuard reconnection failing after ${CONSECUTIVE_FAILURES} attempts" "urgent"
        fi

        if [ -z "${DISCONNECT_TS}" ]; then
            DISCONNECT_TS=$(date +%s)
            notify "${INSTANCE} VPN Down" "WireGuard connection failed. Retrying..."
        fi

        backoff_sleep
    fi
done
