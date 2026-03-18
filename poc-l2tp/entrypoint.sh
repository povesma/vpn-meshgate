#!/bin/sh
set -e

echo "=== L2TP/IPsec PoC ==="
echo "Server:  ${L2TP_SERVER}"
echo "User:    ${L2TP_USERNAME}"
echo "Subnet:  ${COMPANY_CIDRS}"

# --- Generate ipsec.conf ---
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

# --- Generate ipsec.secrets ---
cat > /etc/ipsec.secrets <<EOF
: PSK "${L2TP_PSK}"
EOF
chmod 600 /etc/ipsec.secrets

# --- Generate xl2tpd.conf ---
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[lac company]
lns = ${L2TP_SERVER}
ppp debug = yes
pppoptfile = /etc/ppp/options.l2tpd.client
length bit = yes
EOF

# --- Generate PPP options ---
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
connect-delay 5000
name ${L2TP_USERNAME}
password ${L2TP_PASSWORD}
EOF
chmod 600 /etc/ppp/options.l2tpd.client

echo ""
echo "=== Starting IPsec (strongSwan) ==="
ipsec start
sleep 2

echo ""
echo "=== Bringing up IPsec SA ==="
ipsec up L2TP-PSK || {
    echo "!!! IPsec SA failed. Check credentials/server."
    echo "=== IPsec status ==="
    ipsec statusall
    echo ""
    echo "Dropping to sleep so you can debug with:"
    echo "  docker exec -it poc-l2tp sh"
    sleep infinity
}

echo ""
echo "=== Starting xl2tpd ==="
xl2tpd -D -c /etc/xl2tpd/xl2tpd.conf &
sleep 2

echo ""
echo "=== Connecting L2TP tunnel ==="
echo "c company" > /var/run/xl2tpd/l2tp-control

echo "Waiting for ppp0 interface..."
for i in $(seq 1 30); do
    if ip link show ppp0 >/dev/null 2>&1; then
        echo "ppp0 is UP!"
        break
    fi
    sleep 1
done

if ! ip link show ppp0 >/dev/null 2>&1; then
    echo "!!! ppp0 did not come up within 30s"
    echo "=== xl2tpd log ==="
    echo "Check container logs for details."
    echo ""
    echo "Dropping to sleep so you can debug with:"
    echo "  docker exec -it poc-l2tp sh"
    sleep infinity
fi

echo ""
echo "=== ppp0 interface ==="
ip addr show ppp0

echo ""
echo "=== PPP DNS (from peer) ==="
if [ -f /etc/ppp/resolv.conf ]; then
    cat /etc/ppp/resolv.conf
else
    echo "(no DNS received from peer)"
fi

# Add routes for company CIDRs
echo ""
echo "=== Adding routes for COMPANY_CIDRS ==="
IFS=',' ; for cidr in ${COMPANY_CIDRS}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    if [ -n "$cidr" ]; then
        echo "  route add ${cidr} via ppp0"
        ip route add "${cidr}" dev ppp0 || echo "  (route may already exist)"
    fi
done
unset IFS

echo ""
echo "=== Routing table ==="
ip route

echo ""
echo "=== IP forwarding ==="
if cat /proc/sys/net/ipv4/ip_forward 2>/dev/null | grep -q 1; then
    echo "IP forwarding already enabled (via docker-compose sysctls)"
else
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || \
        echo "WARNING: Could not enable ip_forward (read-only). Set via docker-compose sysctls."
fi

# Test connectivity
echo ""
echo "=== Connectivity test ==="
if [ -n "${L2TP_CHECK_IP}" ]; then
    echo "Pinging ${L2TP_CHECK_IP}..."
    ping -c 3 -W 5 "${L2TP_CHECK_IP}" && \
        echo "SUCCESS: Company network reachable!" || \
        echo "FAILED: Cannot reach ${L2TP_CHECK_IP}"
else
    echo "Set L2TP_CHECK_IP to test connectivity"
fi

echo ""
echo "=== PoC running. Use 'docker exec -it poc-l2tp sh' to debug ==="
echo "=== Press Ctrl+C to stop ==="
sleep infinity
