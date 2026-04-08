#!/bin/sh

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
iptables -C OUTPUT -m mark --mark 0x80000/0xff0000 -o eth0 -j ACCEPT 2>/dev/null || {
    iptables -A OUTPUT -m mark --mark 0x80000/0xff0000 -o eth0 -j ACCEPT && \
        log "  iptables: fwmark 0x80000 -> ACCEPT on eth0" || \
        log "  WARNING: failed to add fwmark iptables rule"
}

log "Waiting for gluetun VPN to be ready..."
for i in $(seq 1 60); do
    if wget -q -O /dev/null http://127.0.0.1:9999/v1/publicip/ip 2>/dev/null; then
        log "Gluetun VPN is up"
        break
    fi
    sleep 2
done

INSTANCES_JSON="/shared/vpn-instances.json"

if [ ! -f "${INSTANCES_JSON}" ]; then
    log "No ${INSTANCES_JSON} found, nothing to route"
    log "Route init complete. Sleeping to maintain routes on restart."
    exec sleep infinity
fi

instance_count=$(jq length "${INSTANCES_JSON}")
log "Routing ${instance_count} VPN instance(s) from ${INSTANCES_JSON}"

# Use custom chains so we can flush-and-rebuild on restart without
# touching gluetun's own OUTPUT/INPUT rules.
iptables -N VPN-INSTANCE-OUT 2>/dev/null || iptables -F VPN-INSTANCE-OUT
iptables -N VPN-INSTANCE-IN 2>/dev/null || iptables -F VPN-INSTANCE-IN
iptables -C OUTPUT -j VPN-INSTANCE-OUT 2>/dev/null || \
    iptables -A OUTPUT -j VPN-INSTANCE-OUT
iptables -C INPUT -j VPN-INSTANCE-IN 2>/dev/null || \
    iptables -A INPUT -j VPN-INSTANCE-IN
log "Custom iptables chains ready (flushed)"

for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
    name=$(echo "$row" | jq -r '.name')
    ip=$(echo "$row" | jq -r '.ip')
    log "Instance '${name}' -> ${ip}"

    for cidr in $(echo "$row" | jq -r '.cidrs[]'); do
        ip route replace "${cidr}" via "${ip}" dev eth0 && \
            log "  route: ${cidr} -> ${ip}" || \
            log "  WARNING: failed route for ${cidr}"
        ip rule del to "${cidr}" lookup main priority 100 2>/dev/null || true
        ip rule add to "${cidr}" lookup main priority 100 && \
            log "  rule: ${cidr} -> main table (priority 100)" || \
            log "  WARNING: failed rule for ${cidr}"
        iptables -A VPN-INSTANCE-OUT -o eth0 -d "${cidr}" -j ACCEPT && \
            log "  iptables OUTPUT: allow ${cidr}" || true
        iptables -A VPN-INSTANCE-IN -i eth0 -s "${cidr}" -j ACCEPT && \
            log "  iptables INPUT: allow ${cidr}" || true
    done
done

log "Final routing table:"
ip route
log "Route init complete. Sleeping to maintain routes on restart."
exec sleep infinity
