#!/bin/sh
set -e

NTFY_URL="http://172.29.0.10:80"
NTFY_TOPIC="${NTFY_TOPIC:-vpn-alerts}"
INSTANCE="${VPN_INSTANCE_NAME:-l2tp}"
BACKOFF_STEP=0
CONSECUTIVE_FAILURES=0
DISCONNECT_TS=""

: "${BOOTSTRAP_DNS_PRIMARY:=1.1.1.1}"
: "${BOOTSTRAP_DNS_SECONDARY:=8.8.8.8}"
: "${BOOTSTRAP_DNS_RETRIES:=5}"
: "${BOOTSTRAP_DNS_BACKOFF:=5 10 20 40 60}"
GATEWAY_IP=""

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

resolve_via() {
    local host="$1" resolver="$2"
    nslookup "${host}" "${resolver}" 2>/dev/null \
        | awk '
            /^Name:/ { in_answer = 1; next }
            in_answer && /^Address: / {
                ip = $2
                sub(/#.*/, "", ip)
                if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print ip; exit }
            }
        '
}

write_hosts_entry() {
    local ip="$1" host="$2"
    local filtered
    filtered=$(grep -v "[[:space:]]${host}\$" /etc/hosts || true)
    {
        printf '%s\n' "${filtered}"
        printf '%s\t%s\n' "${ip}" "${host}"
    } > /etc/hosts
}

resolve_gateway() {
    local host="${L2TP_SERVER}"
    local attempt=0 ip=""
    while [ "${attempt}" -lt "${BOOTSTRAP_DNS_RETRIES}" ]; do
        attempt=$((attempt + 1))

        log "Resolving ${host} via ${BOOTSTRAP_DNS_PRIMARY} (attempt ${attempt}/${BOOTSTRAP_DNS_RETRIES})"
        ip=$(resolve_via "${host}" "${BOOTSTRAP_DNS_PRIMARY}")
        if [ -n "${ip}" ]; then
            GATEWAY_IP="${ip}"
            write_hosts_entry "${ip}" "${host}"
            log "Gateway ${host} -> ${ip} (via ${BOOTSTRAP_DNS_PRIMARY})"
            return 0
        fi

        log "Resolving ${host} via ${BOOTSTRAP_DNS_SECONDARY} (attempt ${attempt}/${BOOTSTRAP_DNS_RETRIES})"
        ip=$(resolve_via "${host}" "${BOOTSTRAP_DNS_SECONDARY}")
        if [ -n "${ip}" ]; then
            GATEWAY_IP="${ip}"
            write_hosts_entry "${ip}" "${host}"
            log "Gateway ${host} -> ${ip} (via ${BOOTSTRAP_DNS_SECONDARY})"
            return 0
        fi

        local delay
        delay=$(echo "${BOOTSTRAP_DNS_BACKOFF}" | tr ' ' '\n' | sed -n "${attempt}p")
        [ -z "${delay}" ] && delay=60
        if [ "${attempt}" -lt "${BOOTSTRAP_DNS_RETRIES}" ]; then
            log "Both resolvers failed; sleeping ${delay}s before next attempt"
            sleep "${delay}"
        fi
    done

    log "FATAL: cannot resolve ${host} after ${BOOTSTRAP_DNS_RETRIES} attempts"
    return 1
}

configure() {
    log "Starting L2TP/IPsec client"
    log "Server: ${L2TP_SERVER}"
    log "User:   ${L2TP_USERNAME}"
    log "CIDRs:  ${INSTANCE_CIDRS}"

    sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true

    cat > /etc/ipsec.conf <<EOF
config setup

conn L2TP-PSK
    keyexchange=ikev1
    authby=secret
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=${L2TP_SERVER}
    rightid=%any
    rightprotoport=17/1701
    auto=add
    rekey=no
    dpddelay=15
    dpdtimeout=60
    dpdaction=restart
    ike=aes128-sha1-modp1024,3des-sha1-modp1024!
    esp=aes128-sha1,3des-sha1!
EOF

    cat > /etc/ipsec.secrets <<EOF
: PSK "${L2TP_PSK}"
EOF
    chmod 600 /etc/ipsec.secrets

    cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[lac company]
lns = ${L2TP_SERVER}
ppp debug = yes
pppoptfile = /etc/ppp/options.l2tpd.client
length bit = yes
; Raise bandwidth cap to 100 Mbps (xl2tpd defaults to 10 Mbps)
tx bps = 100000000
rx bps = 100000000
EOF

    cat > /etc/ppp/options.l2tpd.client <<EOF
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-mschap-v2
noccp
noauth
mtu 1410
mru 1410
nodefaultroute
usepeerdns
debug
logfd 2
connect-delay 5000
name ${L2TP_USERNAME}
password ${L2TP_PASSWORD}
EOF
    chmod 600 /etc/ppp/options.l2tpd.client

    local dns_file="/shared/${INSTANCE}-dns-ip"
    cat > /etc/ppp/ip-up <<IPUP
#!/bin/sh
if [ -n "\$DNS1" ]; then
    echo "\$DNS1" > ${dns_file}
fi
IPUP
    chmod +x /etc/ppp/ip-up
}

cleanup_stale_state() {
    log "Cleaning up stale state..."
    killall xl2tpd 2>/dev/null || true
    sleep 1
    ipsec down L2TP-PSK 2>/dev/null || true

    IFS=','
    for cidr in ${INSTANCE_CIDRS}; do
        cidr=$(echo "$cidr" | tr -d ' ')
        [ -n "$cidr" ] && ip route del "${cidr}" dev ppp0 2>/dev/null || true
    done
    unset IFS

    iptables -t nat -D POSTROUTING -o ppp0 -j MASQUERADE 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o ppp0 \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -i ppp0 \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

    rm -f /var/run/xl2tpd/l2tp-control
    mkdir -p /var/run/xl2tpd
    touch /var/run/xl2tpd/l2tp-control
}

start_ipsec_daemon() {
    if ipsec status >/dev/null 2>&1; then
        log "IPsec daemon already running"
    else
        log "Starting IPsec daemon (strongSwan)"
        ipsec start
        sleep 2
    fi
}

connect() {
    log "Bringing up IPsec SA"
    if ! ipsec up L2TP-PSK; then
        log "ERROR: IPsec SA failed"
        ipsec statusall 2>/dev/null || true
        return 1
    fi

    log "Starting xl2tpd"
    xl2tpd -D -c /etc/xl2tpd/xl2tpd.conf &
    sleep 2

    log "Connecting L2TP tunnel"
    echo "c company" > /var/run/xl2tpd/l2tp-control

    log "Waiting for ppp0 with IP address..."
    PPP_IP=""
    local i=0
    while [ $i -lt 60 ]; do
        PPP_IP=$(ip -4 addr show ppp0 2>/dev/null | awk '/inet / {print $2; exit}')
        if [ -n "${PPP_IP}" ]; then
            log "ppp0 is UP with IP ${PPP_IP}"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    log "ERROR: ppp0 did not get an IP within 60s"
    ip link show ppp0 2>&1 || true
    return 1
}

setup_routing() {
    ip addr show ppp0

    log "Waiting for DNS from PPP peer..."
    local company_dns=""
    local i=0
    while [ $i -lt 15 ]; do
        if [ -f "/shared/${INSTANCE}-dns-ip" ]; then
            company_dns=$(cat "/shared/${INSTANCE}-dns-ip" | tr -d '[:space:]')
            [ -n "${company_dns}" ] && break
        fi
        if [ -f /etc/ppp/resolv.conf ]; then
            company_dns=$(awk '/^nameserver/ {print $2; exit}' /etc/ppp/resolv.conf)
            [ -n "${company_dns}" ] && break
        fi
        sleep 1
        i=$((i + 1))
    done

    if [ -n "${company_dns}" ]; then
        log "Company DNS from PPP: ${company_dns}"
        echo "${company_dns}" > "/shared/${INSTANCE}-dns-ip"
    else
        log "WARNING: No DNS received from PPP peer after 15s"
        echo "" > "/shared/${INSTANCE}-dns-ip"
    fi

    log "Adding routes for INSTANCE_CIDRS"
    IFS=','
    for cidr in ${INSTANCE_CIDRS}; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if [ -n "$cidr" ]; then
            log "  route add ${cidr} dev ppp0"
            ip route add "${cidr}" dev ppp0 2>/dev/null || log "  (route exists)"
        fi
    done
    unset IFS

    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || \
        log "WARNING: ip_forward read-only (set via docker-compose)"

    log "Tuning ppp0 txqueuelen and TCP buffers"
    ip link set ppp0 txqueuelen 100
    sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
    sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
    sysctl -w net.ipv4.tcp_rmem="4096 262144 16777216" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_wmem="4096 262144 16777216" 2>/dev/null || true

    log "Adding MASQUERADE for forwarded traffic on ppp0"
    iptables -t nat -A POSTROUTING -o ppp0 -j MASQUERADE

    log "Adding MSS clamping on ppp0"
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o ppp0 -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i ppp0 -j TCPMSS --clamp-mss-to-pmtu

    log "Pinning VPN server route via eth0 and setting default via ppp0"
    local server_ip="${GATEWAY_IP}"
    if [ -n "${server_ip}" ]; then
        ip route add "${server_ip}/32" via 172.29.0.1 dev eth0 2>/dev/null || true
        log "  pinned ${L2TP_SERVER} (${server_ip}) via eth0"
    else
        log "  WARNING: GATEWAY_IP empty for pinned route"
    fi
    ip route replace default dev ppp0
    log "  default route → ppp0"

    log "L2TP/IPsec client ready"
    ip route
}

monitor_ppp0() {
    local keepalive_count=0
    while ip link show ppp0 >/dev/null 2>&1; do
        sleep 10
        keepalive_count=$((keepalive_count + 1))
        if [ $((keepalive_count % 6)) -eq 0 ] && [ -n "${L2TP_CHECK_IP}" ]; then
            ping -c 1 -W 5 "${L2TP_CHECK_IP}" >/dev/null 2>&1 || true
        fi
    done
}

# === Main ===

trap 'log "SIGTERM received, shutting down"; cleanup_stale_state; exit 0' TERM INT

configure

while true; do
    if ! resolve_gateway; then
        backoff_sleep
        continue
    fi

    cleanup_stale_state
    start_ipsec_daemon

    if connect; then
        setup_routing
        reset_backoff

        if [ -n "${DISCONNECT_TS}" ]; then
            local_downtime=$(( $(date +%s) - DISCONNECT_TS ))
            notify "${INSTANCE} VPN Up" "L2TP reconnected. Downtime: ${local_downtime}s. IP: ${PPP_IP}"
            DISCONNECT_TS=""
        else
            log "Initial connection established"
        fi

        monitor_ppp0

        DISCONNECT_TS=$(date +%s)
        log "ppp0 lost — tunnel disconnected"
        notify "${INSTANCE} VPN Down" "L2TP tunnel lost. Reconnecting..."
    else
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        log "Connection failed (attempt ${CONSECUTIVE_FAILURES})"

        if [ "${CONSECUTIVE_FAILURES}" -eq 3 ]; then
            notify "${INSTANCE} VPN Failing" \
                "L2TP reconnection failing after ${CONSECUTIVE_FAILURES} attempts" "urgent"
        fi

        if [ -z "${DISCONNECT_TS}" ]; then
            DISCONNECT_TS=$(date +%s)
            notify "${INSTANCE} VPN Down" "L2TP connection failed. Retrying..."
        fi

        backoff_sleep
    fi
done
