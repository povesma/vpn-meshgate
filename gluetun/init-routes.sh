#!/bin/sh

L2TP_IP="172.29.0.20"

log() { echo "[route-init] $*"; }

# Route Tailscale WireGuard/STUN traffic directly via host, bypassing Mullvad.
# Tailscale marks these packets with fwmark 0x80000. Without this bypass,
# all Tailscale control traffic goes through Mullvad, preventing direct
# peer-to-peer connections and making Tailscale depend on Mullvad availability.
DOCKER_GW="172.29.0.1"
log "Setting up Tailscale direct routing (table 201 via ${DOCKER_GW})"
ip route replace default via "${DOCKER_GW}" dev eth0 table 201 2>/dev/null && \
    log "  route: default via ${DOCKER_GW} table 201" || \
    log "  WARNING: failed to add table 201 route"
ip rule add fwmark 0x80000/0xff0000 lookup 201 priority 100 2>/dev/null && \
    log "  rule: fwmark 0x80000 -> table 201 (priority 100)" || \
    log "  (rule already exists)"
ip rule add to 100.64.0.0/10 lookup 52 priority 100 2>/dev/null && \
    log "  rule: 100.64.0.0/10 -> table 52 (priority 100)" || \
    log "  (rule already exists)"

log "Waiting for gluetun VPN to be ready..."
for i in $(seq 1 60); do
    if wget -q -O /dev/null http://127.0.0.1:9999/v1/publicip/ip 2>/dev/null; then
        log "Gluetun VPN is up"
        break
    fi
    sleep 2
done

if [ -z "${COMPANY_CIDRS}" ]; then
    log "COMPANY_CIDRS empty, nothing to route"
    exit 0
fi

log "Adding company routes via L2TP (${L2TP_IP})"
IFS=','
for cidr in ${COMPANY_CIDRS}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    if [ -n "$cidr" ]; then
        ip route replace "${cidr}" via "${L2TP_IP}" dev eth0 && \
            log "  route: ${cidr} -> ${L2TP_IP}" || \
            log "  WARNING: failed route for ${cidr}"
        # Add policy rule so company traffic uses main table
        # instead of WireGuard table 51820
        ip rule add to "${cidr}" lookup main priority 100 2>/dev/null && \
            log "  rule: ${cidr} -> main table (priority 100)" || \
            log "  (rule exists)"
        # Allow gluetun firewall to send/receive company traffic
        iptables -A OUTPUT -o eth0 -d "${cidr}" -j ACCEPT 2>/dev/null && \
            log "  iptables OUTPUT: allow ${cidr}" || true
        iptables -A INPUT -i eth0 -s "${cidr}" -j ACCEPT 2>/dev/null && \
            log "  iptables INPUT: allow ${cidr}" || true
    fi
done
unset IFS

log "Final routing table:"
ip route
log "Route init complete. Sleeping to maintain routes on restart."
exec sleep infinity
