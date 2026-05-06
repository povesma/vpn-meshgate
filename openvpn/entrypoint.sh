#!/bin/sh
set -e

NTFY_URL="http://172.29.0.10:80"
NTFY_TOPIC="${NTFY_TOPIC:-vpn-alerts}"
INSTANCE="${VPN_INSTANCE_NAME:-openvpn}"
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
    log "Starting OpenVPN client"
    log "CIDRs: ${INSTANCE_CIDRS}"

    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || \
        log "WARNING: ip_forward read-only"
    sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true

    if [ -n "${OVPN_USERNAME}" ]; then
        log "Writing auth credentials"
        mkdir -p /etc/openvpn
        printf '%s\n%s\n' "${OVPN_USERNAME}" "${OVPN_PASSWORD}" \
            > /etc/openvpn/auth.txt
        chmod 600 /etc/openvpn/auth.txt
    fi
}

connect() {
    log "Starting openvpn"
    local auth_args=""
    if [ -f /etc/openvpn/auth.txt ]; then
        auth_args="--auth-user-pass /etc/openvpn/auth.txt"
    fi

    openvpn --config /etc/openvpn/client.conf \
        ${auth_args} \
        --daemon --log /tmp/openvpn.log \
        --writepid /tmp/openvpn.pid \
        --pull-filter ignore "route" \
        --pull-filter ignore "redirect-gateway"

    log "Waiting for tun0..."
    local i=0
    while [ $i -lt 60 ]; do
        if ip link show tun0 >/dev/null 2>&1; then
            local tun_ip
            tun_ip=$(ip -4 addr show tun0 2>/dev/null \
                | awk '/inet / {print $2; exit}')
            if [ -n "${tun_ip}" ]; then
                log "tun0 is UP with IP ${tun_ip}"
                return 0
            fi
        fi
        sleep 1
        i=$((i + 1))
    done

    log "ERROR: tun0 did not come up within 60s"
    cat /tmp/openvpn.log 2>/dev/null | tail -20
    return 1
}

cleanup_iptables() {
    iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o tun0 \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -i tun0 \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

disconnect() {
    if [ -f /tmp/openvpn.pid ]; then
        kill "$(cat /tmp/openvpn.pid)" 2>/dev/null || true
        rm -f /tmp/openvpn.pid
        sleep 2
    fi
    killall openvpn 2>/dev/null || true
}

setup_routing() {
    cleanup_iptables
    log "Adding routes for INSTANCE_CIDRS"
    IFS=','
    for cidr in ${INSTANCE_CIDRS}; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if [ -n "$cidr" ]; then
            log "  route add ${cidr} dev tun0"
            ip route add "${cidr}" dev tun0 2>/dev/null || log "  (route exists)"
        fi
    done
    unset IFS

    log "Adding MASQUERADE for forwarded traffic on tun0"
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

    log "Adding MSS clamping on tun0"
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o tun0 \
        -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i tun0 \
        -j TCPMSS --clamp-mss-to-pmtu

    log "Pinning OpenVPN remote route via eth0 and setting default via tun0"
    local remote_ip
    remote_ip=$(awk '/^remote / {print $2; exit}' /etc/openvpn/client.conf 2>/dev/null)
    if [ -n "${remote_ip}" ]; then
        # If remote is a hostname, resolve it
        case "${remote_ip}" in
            *[!0-9.]*)
                remote_ip=$(getent hosts "${remote_ip}" 2>/dev/null | awk '{print $1; exit}')
                ;;
        esac
    fi
    if [ -n "${remote_ip}" ]; then
        ip route add "${remote_ip}/32" via 172.29.0.1 dev eth0 2>/dev/null || true
        log "  pinned remote ${remote_ip} via eth0"
    else
        log "  WARNING: could not determine OpenVPN remote IP"
    fi
    ip route replace default dev tun0
    log "  default route → tun0"

    log "OpenVPN client ready"
    ip route
}

monitor_tun0() {
    while ip link show tun0 >/dev/null 2>&1; do
        sleep 10
    done
}

# === Main ===

trap 'log "SIGTERM received, shutting down"; cleanup_iptables; disconnect; exit 0' TERM INT

configure

while true; do
    disconnect

    if connect; then
        setup_routing
        reset_backoff

        if [ -n "${DISCONNECT_TS}" ]; then
            local_downtime=$(( $(date +%s) - DISCONNECT_TS ))
            notify "${INSTANCE} VPN Up" \
                "OpenVPN reconnected. Downtime: ${local_downtime}s."
            DISCONNECT_TS=""
        else
            log "Initial connection established"
        fi

        monitor_tun0

        DISCONNECT_TS=$(date +%s)
        log "tun0 lost — tunnel disconnected"
        notify "${INSTANCE} VPN Down" "OpenVPN tunnel lost. Reconnecting..."
    else
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        log "Connection failed (attempt ${CONSECUTIVE_FAILURES})"

        if [ "${CONSECUTIVE_FAILURES}" -eq 3 ]; then
            notify "${INSTANCE} VPN Failing" \
                "OpenVPN reconnection failing after ${CONSECUTIVE_FAILURES} attempts" "urgent"
        fi

        if [ -z "${DISCONNECT_TS}" ]; then
            DISCONNECT_TS=$(date +%s)
            notify "${INSTANCE} VPN Down" "OpenVPN connection failed. Retrying..."
        fi

        backoff_sleep
    fi
done
