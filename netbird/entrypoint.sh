#!/bin/sh
set -e

NTFY_URL="http://172.29.0.10:80"
NTFY_TOPIC="${NTFY_TOPIC:-vpn-alerts}"
INSTANCE="${VPN_INSTANCE_NAME:-netbird}"

log() { echo "[vpn-${INSTANCE}] $*"; }

notify() {
    local title="$1" msg="$2" priority="${3:-high}"
    log "NOTIFY: ${title} — ${msg}"
    curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -d "${msg}" 2>/dev/null || log "WARNING: ntfy unreachable"
}

configure() {
    log "Starting Netbird client (daemon mode)"
    log "CIDRs: ${INSTANCE_CIDRS}"

    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || \
        log "WARNING: ip_forward read-only"
    sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true
}

wait_for_wt0() {
    log "Waiting for wt0 interface..."
    local i=0
    while [ $i -lt 120 ]; do
        if ip link show wt0 >/dev/null 2>&1; then
            local wt_ip
            wt_ip=$(ip -4 addr show wt0 2>/dev/null \
                | awk '/inet / {print $2; exit}')
            if [ -n "${wt_ip}" ]; then
                log "wt0 is UP with IP ${wt_ip}"
                return 0
            fi
        fi
        sleep 1
        i=$((i + 1))
    done
    log "ERROR: wt0 did not come up within 120s"
    return 1
}

cleanup_iptables() {
    iptables -t nat -D POSTROUTING -o wt0 -j MASQUERADE 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o wt0 \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -i wt0 \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    # DNS proxy rules
    iptables -t nat -D PREROUTING -i eth0 -p udp --dport 53 \
        -j DNAT 2>/dev/null || true
    iptables -t nat -D PREROUTING -i eth0 -p tcp --dport 53 \
        -j DNAT 2>/dev/null || true
    iptables -D INPUT -i eth0 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -i eth0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
}

setup_routing() {
    cleanup_iptables
    log "Adding routes for INSTANCE_CIDRS"
    IFS=','
    for cidr in ${INSTANCE_CIDRS}; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if [ -n "$cidr" ]; then
            log "  route add ${cidr} dev wt0"
            ip route replace "${cidr}" dev wt0 2>/dev/null || \
                log "  (route exists or failed)"
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

    log "Pinning Netbird management server route via eth0 and setting default via wt0"
    local mgmt_host mgmt_ip
    mgmt_host=$(echo "${NB_MANAGEMENT_URL:-https://api.netbird.io}" | sed 's|https\?://||;s|:.*||;s|/.*||')
    mgmt_ip=$(getent hosts "${mgmt_host}" 2>/dev/null | awk '{print $1; exit}')
    if [ -n "${mgmt_ip}" ]; then
        ip route add "${mgmt_ip}/32" via 172.29.0.1 dev eth0 2>/dev/null || true
        log "  pinned ${mgmt_host} (${mgmt_ip}) via eth0"
    else
        log "  WARNING: could not resolve ${mgmt_host} for pinned route"
    fi
    ip route replace default dev wt0
    log "  default route → wt0"

    log "Netbird client ready"
    ip route
}

setup_dns_proxy() {
    local wt_ip eth_ip
    wt_ip=$(ip -4 addr show wt0 | awk '/inet / {split($2,a,"/"); print a[1]; exit}')
    eth_ip=$(ip -4 addr show eth0 | awk '/inet / {split($2,a,"/"); print a[1]; exit}')

    if [ -z "${wt_ip}" ] || [ -z "${eth_ip}" ]; then
        log "WARNING: could not determine wt0 or eth0 IP for DNS proxy"
        return
    fi

    log "Exposing Netbird DNS on bridge: ${eth_ip}:53 -> ${wt_ip}:53"
    iptables -t nat -A PREROUTING -i eth0 -p udp --dport 53 \
        -j DNAT --to "${wt_ip}:53"
    iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 53 \
        -j DNAT --to "${wt_ip}:53"
    iptables -A INPUT -i eth0 -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -i eth0 -p tcp --dport 53 -j ACCEPT

    log "Writing DNS IP ${eth_ip} to /shared/${INSTANCE}-dns-ip"
    echo "${eth_ip}" > "/shared/${INSTANCE}-dns-ip"
}

monitor_wt0() {
    while ip link show wt0 >/dev/null 2>&1; do
        sleep 10
    done
}

# === Main ===

trap 'log "SIGTERM received, shutting down"; cleanup_iptables; kill "${NB_PID}" 2>/dev/null || true; exit 0' TERM INT

configure

# Start the official Netbird daemon entrypoint in background.
# This runs 'netbird service run' + 'netbird up' with full
# daemon features: DNS resolver, network routes, management socket.
/usr/local/bin/netbird-entrypoint.sh &
NB_PID=$!

if wait_for_wt0; then
    setup_routing
    setup_dns_proxy
    notify "${INSTANCE} VPN Up" "Netbird connected."
    log "Initial connection established"

    monitor_wt0

    log "wt0 lost — tunnel disconnected"
    notify "${INSTANCE} VPN Down" "Netbird tunnel lost."
fi

# If we get here, the tunnel died. Kill the daemon and exit.
# Docker restart policy will restart the container.
kill "${NB_PID}" 2>/dev/null || true
wait "${NB_PID}" 2>/dev/null || true
exit 1
