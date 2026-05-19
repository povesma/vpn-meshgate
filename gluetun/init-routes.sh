#!/bin/sh

log() { echo "[route-init] $*" >&2; }

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

# Stop gluetun's built-in DNS server. Its DNS rebinding protection
# silently drops CNAME chain responses (e.g. analytics.google.com).
# With gluetun DNS stopped, port 53 is free and the existing DNAT
# rule on tailscale0 forwards all DNS directly to dnsmasq, which
# has no rebinding protection.
log "Stopping gluetun DNS server (rebinding protection incompatible with CNAME domains)"
curl -sf -X PUT -H 'Content-Type: application/json' \
    -d '{"status":"stopped"}' \
    http://127.0.0.1:8000/v1/dns/status >/dev/null 2>&1 && \
    log "  gluetun DNS stopped" || \
    log "  WARNING: failed to stop gluetun DNS"

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

# --- Domain-based routing ---

DNS_SERVER="172.29.0.30"
DOMAIN_STATE_DIR="/tmp/domain-routes"
MIN_POLL=30
MAX_POLL=300
TTL_MARGIN=80  # percent — re-resolve at 80% of TTL

has_route_domains=$(jq '[.[] | select(.route_domains | length > 0)] | length' "${INSTANCES_JSON}")
if [ "${has_route_domains}" -eq 0 ]; then
    log "No route_domains configured. Sleeping to maintain routes."
    exec sleep infinity
fi

mkdir -p "${DOMAIN_STATE_DIR}"
log "Domain routing enabled for ${has_route_domains} instance(s)"

resolve_domain() {
    local domain="$1"
    # Strip wildcard prefix — *.example.com resolves as example.com
    case "${domain}" in
        \*.*) domain="${domain#\*.}" ;;
    esac
    # Parse A records: extract IPs and TTLs from dig answer section
    # Format: "domain. TTL IN A 1.2.3.4"
    dig @"${DNS_SERVER}" "${domain}" +noall +answer +ttlid 2>/dev/null \
        | awk '/\tIN\tA\t/ { print $2, $NF }'
    # Output: lines of "TTL IP"
}

update_domain_routes() {
    local next_sleep="${MAX_POLL}"

    for row in $(jq -c '.[] | select(.route_domains | length > 0)' "${INSTANCES_JSON}"); do
        local name ip
        name=$(echo "$row" | jq -r '.name')
        ip=$(echo "$row" | jq -r '.ip')
        local inst_dir="${DOMAIN_STATE_DIR}/${name}"
        mkdir -p "${inst_dir}"

        for domain in $(echo "$row" | jq -r '.route_domains[]'); do
            local state_file="${inst_dir}/$(echo "${domain}" | tr '.*' '_').state"
            local previous_ips=""
            [ -f "${state_file}" ] && previous_ips=$(grep '^IP ' "${state_file}" | cut -d' ' -f2 | sort)

            local dig_output min_ttl resolved_ips
            dig_output=$(resolve_domain "${domain}")
            if [ -z "${dig_output}" ]; then
                log "  ${name}/${domain}: no A records (DNS failed or NXDOMAIN)"
                continue
            fi

            resolved_ips=$(echo "${dig_output}" | awk '{print $2}' | sort)
            min_ttl=$(echo "${dig_output}" | awk '{print $1}' | sort -n | head -1)
            [ -z "${min_ttl}" ] && min_ttl="${MAX_POLL}"

            # Compute next resolve time from TTL
            local ttl_sleep=$(( min_ttl * TTL_MARGIN / 100 ))
            [ "${ttl_sleep}" -lt "${MIN_POLL}" ] && ttl_sleep="${MIN_POLL}"
            [ "${ttl_sleep}" -gt "${MAX_POLL}" ] && ttl_sleep="${MAX_POLL}"
            [ "${ttl_sleep}" -lt "${next_sleep}" ] && next_sleep="${ttl_sleep}"

            # Add routes for new IPs
            for resolved_ip in ${resolved_ips}; do
                if ! echo "${previous_ips}" | grep -qx "${resolved_ip}"; then
                    ip route replace "${resolved_ip}/32" via "${ip}" dev eth0 && \
                        log "  ${name}/${domain}: +route ${resolved_ip} via ${ip}" || true
                    ip rule del to "${resolved_ip}/32" lookup main priority 100 2>/dev/null || true
                    ip rule add to "${resolved_ip}/32" lookup main priority 100 2>/dev/null || true
                    iptables -C VPN-INSTANCE-OUT -o eth0 -d "${resolved_ip}/32" -j ACCEPT 2>/dev/null || \
                        iptables -A VPN-INSTANCE-OUT -o eth0 -d "${resolved_ip}/32" -j ACCEPT 2>/dev/null || true
                    iptables -C VPN-INSTANCE-IN -i eth0 -s "${resolved_ip}/32" -j ACCEPT 2>/dev/null || \
                        iptables -A VPN-INSTANCE-IN -i eth0 -s "${resolved_ip}/32" -j ACCEPT 2>/dev/null || true
                fi
            done

            # Remove routes for stale IPs
            for old_ip in ${previous_ips}; do
                if ! echo "${resolved_ips}" | grep -qx "${old_ip}"; then
                    ip route del "${old_ip}/32" via "${ip}" dev eth0 2>/dev/null && \
                        log "  ${name}/${domain}: -route ${old_ip}" || true
                    ip rule del to "${old_ip}/32" lookup main priority 100 2>/dev/null || true
                    iptables -D VPN-INSTANCE-OUT -o eth0 -d "${old_ip}/32" -j ACCEPT 2>/dev/null || true
                    iptables -D VPN-INSTANCE-IN -i eth0 -s "${old_ip}/32" -j ACCEPT 2>/dev/null || true
                fi
            done

            # Write state: TTL and IPs
            {
                echo "TTL ${min_ttl}"
                for resolved_ip in ${resolved_ips}; do
                    echo "IP ${resolved_ip}"
                done
            } > "${state_file}"
        done
    done

    echo "${next_sleep}"
}

NETBIRD_ROUTE_SYNC="${NETBIRD_ROUTE_SYNC:-1}"
NETBIRD_STATE_DIR="/tmp/netbird-routes"
NETBIRD_STALE_FACTOR=2

mkdir -p "${NETBIRD_STATE_DIR}"

is_owned_by_other() {
    local ip_cidr="$1" self="$2"
    # Static cidrs and route_domains both lay down rules at priority
    # 100. We detect a clash by checking the existing rule; if one
    # exists and is not our own, treat as foreign-owned and skip.
    local existing
    existing=$(ip rule show to "${ip_cidr}" 2>/dev/null | head -1)
    if [ -n "${existing}" ]; then
        if [ ! -f "${NETBIRD_STATE_DIR}/${self}.routes" ] || \
           ! grep -qxF "${ip_cidr}" "${NETBIRD_STATE_DIR}/${self}.routes"; then
            return 0
        fi
    fi
    return 1
}

apply_netbird_route() {
    local ip="$1" gw="$2"
    local cidr="${ip}/32"
    ip route replace "${cidr}" via "${gw}" dev eth0 2>/dev/null || return 1
    ip rule del to "${cidr}" lookup main priority 100 2>/dev/null || true
    ip rule add to "${cidr}" lookup main priority 100 2>/dev/null || true
    iptables -C VPN-INSTANCE-OUT -o eth0 -d "${cidr}" -j ACCEPT 2>/dev/null || \
        iptables -A VPN-INSTANCE-OUT -o eth0 -d "${cidr}" -j ACCEPT 2>/dev/null || true
    iptables -C VPN-INSTANCE-IN -i eth0 -s "${cidr}" -j ACCEPT 2>/dev/null || \
        iptables -A VPN-INSTANCE-IN -i eth0 -s "${cidr}" -j ACCEPT 2>/dev/null || true
    iptables -t nat -C POSTROUTING -d "${cidr}" -o eth0 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -d "${cidr}" -o eth0 -j MASQUERADE 2>/dev/null || true
    return 0
}

remove_netbird_route() {
    local ip="$1" gw="$2"
    local cidr="${ip}/32"
    ip route del "${cidr}" via "${gw}" dev eth0 2>/dev/null || true
    ip rule del to "${cidr}" lookup main priority 100 2>/dev/null || true
    iptables -D VPN-INSTANCE-OUT -o eth0 -d "${cidr}" -j ACCEPT 2>/dev/null || true
    iptables -D VPN-INSTANCE-IN -i eth0 -s "${cidr}" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -d "${cidr}" -o eth0 -j MASQUERADE 2>/dev/null || true
}

update_netbird_routes() {
    [ "${NETBIRD_ROUTE_SYNC}" = "1" ] || return 0

    local poll_interval="$1"
    local stale_age=$(( poll_interval * NETBIRD_STALE_FACTOR ))
    local now
    now=$(date +%s)

    for row in $(jq -c '.[] | select(.type == "netbird")' "${INSTANCES_JSON}"); do
        local name ip producer_file state_file
        name=$(echo "$row" | jq -r '.name')
        ip=$(echo "$row" | jq -r '.ip')
        producer_file="/shared/${name}-netbird-routes"
        state_file="${NETBIRD_STATE_DIR}/${name}.routes"

        if [ ! -f "${producer_file}" ]; then
            if [ -f "${state_file}" ]; then
                local state_mtime
                state_mtime=$(stat -c %Y "${state_file}" 2>/dev/null || echo "${now}")
                if [ $(( now - state_mtime )) -gt "${stale_age}" ]; then
                    log "  netbird/${name}: producer missing > ${stale_age}s; removing tracked routes"
                    while read -r old_ip; do
                        [ -n "${old_ip}" ] && remove_netbird_route "${old_ip}" "${ip}"
                    done < "${state_file}"
                    rm -f "${state_file}"
                else
                    log "  netbird/${name}: producer missing (grace period)"
                fi
            fi
            continue
        fi

        local file_mtime
        file_mtime=$(stat -c %Y "${producer_file}" 2>/dev/null || echo "${now}")
        if [ $(( now - file_mtime )) -gt "${stale_age}" ]; then
            log "  netbird/${name}: producer stale (age $(( now - file_mtime ))s > ${stale_age}s); leaving routes untouched"
            continue
        fi

        local current_ips previous_ips
        current_ips=$(sort -u "${producer_file}" 2>/dev/null)
        previous_ips=""
        [ -f "${state_file}" ] && previous_ips=$(cat "${state_file}")

        for new_ip in ${current_ips}; do
            if ! echo "${previous_ips}" | grep -qxF "${new_ip}"; then
                if is_owned_by_other "${new_ip}/32" "${name}"; then
                    log "  netbird/${name}: ${new_ip} owned by another source, skip"
                    continue
                fi
                if apply_netbird_route "${new_ip}" "${ip}"; then
                    log "  netbird/${name}: +route ${new_ip} via ${ip}"
                fi
            fi
        done

        for old_ip in ${previous_ips}; do
            if ! echo "${current_ips}" | grep -qxF "${old_ip}"; then
                remove_netbird_route "${old_ip}" "${ip}"
                log "  netbird/${name}: -route ${old_ip}"
            fi
        done

        echo "${current_ips}" > "${state_file}"
    done
}

log "Starting routing loop (domain TTL-aware + netbird poller)"

while true; do
    sleep_interval=$(update_domain_routes)
    update_netbird_routes "${sleep_interval}"
    log "Routes updated. Next cycle in ${sleep_interval}s"
    sleep "${sleep_interval}"
done
