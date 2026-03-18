#!/bin/sh
set -e

log() { echo "[l2tp] $*"; }

log "Starting L2TP/IPsec client"
log "Server: ${L2TP_SERVER}"
log "User:   ${L2TP_USERNAME}"
log "CIDRs:  ${COMPANY_CIDRS}"

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

# ip-up script: pppd calls this after link is established
# pppd passes DNS1/DNS2 env vars when usepeerdns is set
cat > /etc/ppp/ip-up <<'IPUP'
#!/bin/sh
if [ -n "$DNS1" ]; then
    echo "$DNS1" > /shared/company-dns-ip
fi
IPUP
chmod +x /etc/ppp/ip-up

log "Starting IPsec (strongSwan)"
ipsec start
sleep 2

log "Bringing up IPsec SA"
ipsec up L2TP-PSK || {
    log "ERROR: IPsec SA failed"
    ipsec statusall
    sleep infinity
}

log "Starting xl2tpd"
xl2tpd -D -c /etc/xl2tpd/xl2tpd.conf &
sleep 2

log "Connecting L2TP tunnel"
echo "c company" > /var/run/xl2tpd/l2tp-control

log "Waiting for ppp0 with IP address..."
PPP_IP=""
for i in $(seq 1 60); do
    PPP_IP=$(ip -4 addr show ppp0 2>/dev/null | awk '/inet / {print $2; exit}')
    if [ -n "${PPP_IP}" ]; then
        log "ppp0 is UP with IP ${PPP_IP}"
        break
    fi
    sleep 1
done

if [ -z "${PPP_IP}" ]; then
    log "ERROR: ppp0 did not get an IP within 60s"
    ip link show ppp0 2>&1 || true
    sleep infinity
fi

ip addr show ppp0

log "Waiting for DNS from PPP peer..."
COMPANY_DNS=""
for i in $(seq 1 15); do
    # Check ip-up script output first (most reliable)
    if [ -f /shared/company-dns-ip ]; then
        COMPANY_DNS=$(cat /shared/company-dns-ip | tr -d '[:space:]')
        [ -n "${COMPANY_DNS}" ] && break
    fi
    # Fallback: check resolv.conf
    if [ -f /etc/ppp/resolv.conf ]; then
        COMPANY_DNS=$(awk '/^nameserver/ {print $2; exit}' /etc/ppp/resolv.conf)
        [ -n "${COMPANY_DNS}" ] && break
    fi
    sleep 1
done

if [ -n "${COMPANY_DNS}" ]; then
    log "Company DNS from PPP: ${COMPANY_DNS}"
    echo "${COMPANY_DNS}" > /shared/company-dns-ip
    log "Wrote DNS IP to /shared/company-dns-ip"
else
    log "WARNING: No DNS received from PPP peer after 15s"
    echo "" > /shared/company-dns-ip
fi

log "Adding routes for COMPANY_CIDRS"
IFS=','
for cidr in ${COMPANY_CIDRS}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    if [ -n "$cidr" ]; then
        log "  route add ${cidr} dev ppp0"
        ip route add "${cidr}" dev ppp0 2>/dev/null || log "  (route exists)"
    fi
done
unset IFS

log "Enabling IP forwarding"
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || \
    log "WARNING: ip_forward read-only (set via docker-compose)"

log "Adding MASQUERADE for forwarded traffic on ppp0"
iptables -t nat -A POSTROUTING -o ppp0 -j MASQUERADE

log "L2TP/IPsec client ready"
ip route

exec sleep infinity
