#!/bin/sh
set -e

NTFY_URL="http://172.29.0.10:80"
NTFY_TOPIC="${NTFY_TOPIC:-vpn-alerts}"
INSTANCE="${VPN_INSTANCE_NAME:-netbird}"
BACKOFF_STEP=0
CONSECUTIVE_FAILURES=0
DISCONNECT_TS=""

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
    log "Starting Netbird client"
    log "CIDRs: ${INSTANCE_CIDRS}"

    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || \
        log "WARNING: ip_forward read-only"
    sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true
}

connect() {
    log "Running netbird up"
    local mgmt_args=""
    if [ -n "${NB_MANAGEMENT_URL}" ]; then
        mgmt_args="--management-url ${NB_MANAGEMENT_URL}"
    fi

    netbird up --setup-key "${NB_SETUP_KEY}" ${mgmt_args} \
        --foreground-mode 2>&1 &
    NB_PID=$!

    log "Waiting for wt0 interface..."
    local i=0
    while [ $i -lt 60 ]; do
        if ip link show wt0 >/dev/null 2>&1; then
            local wt_ip
            wt_ip=$(ip -4 addr show wt0 2>/dev/null \
                | awk '/inet / {print $2; exit}')
            if [ -n "${wt_ip}" ]; then
                log "wt0 is UP with IP ${wt_ip}"
                return 0
            fi
        fi
        if ! kill -0 "${NB_PID}" 2>/dev/null; then
            log "ERROR: netbird process exited"
            return 1
        fi
        sleep 1
        i=$((i + 1))
    done

    log "ERROR: wt0 did not come up within 60s"
    return 1
}

disconnect() {
    netbird down 2>/dev/null || true
    if [ -n "${NB_PID}" ]; then
        kill "${NB_PID}" 2>/dev/null || true
        wait "${NB_PID}" 2>/dev/null || true
        NB_PID=""
    fi
}

setup_routing() {
    log "Adding routes for INSTANCE_CIDRS"
    IFS=','
    for cidr in ${INSTANCE_CIDRS}; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if [ -n "$cidr" ]; then
            log "  route add ${cidr} dev wt0"
            ip route add "${cidr}" dev wt0 2>/dev/null || log "  (route exists)"
        fi
    done
    unset IFS

    log "Adding MASQUERADE for forwarded traffic on wt0"
    iptables -t nat -A POSTROUTING -o wt0 -j MASQUERADE

    log "Adding MSS clamping on wt0"
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o wt0 \
        -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i wt0 \
        -j TCPMSS --clamp-mss-to-pmtu

    log "Netbird client ready"
    ip route
}

monitor_wt0() {
    while ip link show wt0 >/dev/null 2>&1; do
        sleep 10
        if ! kill -0 "${NB_PID}" 2>/dev/null; then
            log "WARNING: netbird process died"
            return 1
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
                "Netbird reconnected. Downtime: ${local_downtime}s."
            DISCONNECT_TS=""
        else
            log "Initial connection established"
        fi

        monitor_wt0

        DISCONNECT_TS=$(date +%s)
        log "wt0 lost — tunnel disconnected"
        notify "${INSTANCE} VPN Down" "Netbird tunnel lost. Reconnecting..."
    else
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        log "Connection failed (attempt ${CONSECUTIVE_FAILURES})"

        if [ "${CONSECUTIVE_FAILURES}" -eq 3 ]; then
            notify "${INSTANCE} VPN Failing" \
                "Netbird reconnection failing after ${CONSECUTIVE_FAILURES} attempts" "urgent"
        fi

        if [ -z "${DISCONNECT_TS}" ]; then
            DISCONNECT_TS=$(date +%s)
            notify "${INSTANCE} VPN Down" "Netbird connection failed. Retrying..."
        fi

        backoff_sleep
    fi
done
