#!/bin/sh
set -e

MULLVAD_DNS="${DEFAULT_DNS:-1.1.1.1}"
INSTANCES_JSON="/shared/vpn-instances.json"
CONF="/etc/dnsmasq.conf"

log() { echo "[dnsmasq] $*"; }

log "Waiting for VPN instance DNS files..."
sleep 10

log "Generating dnsmasq.conf"
cat > "${CONF}" <<EOF
no-resolv
cache-size=150
server=${MULLVAD_DNS}
EOF

if [ -f "${INSTANCES_JSON}" ]; then
    for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
        local_name=$(echo "$row" | jq -r '.name')
        local_ip=$(echo "$row" | jq -r '.ip')
        local_domains=$(echo "$row" | jq -r '.dns_domains[]' 2>/dev/null)
        local_dns_file="/shared/${local_name}-dns-ip"

        [ -z "${local_domains}" ] && continue

        local_dns=""
        if [ -f "${local_dns_file}" ]; then
            local_dns=$(cat "${local_dns_file}" | tr -d '[:space:]')
        fi

        if [ -z "${local_dns}" ]; then
            log "WARNING: No DNS IP for instance '${local_name}', skipping domains"
            continue
        fi

        for domain in ${local_domains}; do
            echo "server=/${domain}/${local_dns}" >> "${CONF}"
            log "  ${domain} -> ${local_dns} (via ${local_name})"
        done
    done

    log "Adding routes to VPN instances"
    for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
        local_ip=$(echo "$row" | jq -r '.ip')
        local_name=$(echo "$row" | jq -r '.name')
        for cidr in $(echo "$row" | jq -r '.cidrs[]'); do
            ip route add "${cidr}" via "${local_ip}" 2>/dev/null && \
                log "  route: ${cidr} via ${local_ip} (${local_name})" || \
                log "  route: ${cidr} already exists or failed"
        done
    done
else
    log "WARNING: No ${INSTANCES_JSON} found. Mullvad-only DNS."
fi

log "Default DNS: ${MULLVAD_DNS}"
log "Config:"
cat "${CONF}"

log "Starting dnsmasq"
exec dnsmasq --no-daemon --log-queries --conf-file="${CONF}"
