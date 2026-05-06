#!/bin/sh
set -e

MULLVAD_DNS="${DEFAULT_DNS:-1.1.1.1}"
INSTANCES_JSON="/shared/vpn-instances.json"
CONF="/etc/dnsmasq.conf"

log() { echo "[dnsmasq] $*"; }

DNS_WAIT_TIMEOUT="${DNS_WAIT_TIMEOUT:-60}"

# Wait for VPN instances to write their DNS IP files
if [ -f "${INSTANCES_JSON}" ]; then
    expected=""
    for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
        domains=$(echo "$row" | jq -r '.dns_domains[]' 2>/dev/null)
        if [ -n "${domains}" ]; then
            name=$(echo "$row" | jq -r '.name')
            expected="${expected} ${name}"
        fi
    done

    if [ -n "${expected}" ]; then
        log "Waiting up to ${DNS_WAIT_TIMEOUT}s for DNS files:${expected}"
        elapsed=0
        while [ "${elapsed}" -lt "${DNS_WAIT_TIMEOUT}" ]; do
            all_ready=true
            for name in ${expected}; do
                dns_file="/shared/${name}-dns-ip"
                if [ ! -f "${dns_file}" ] || [ ! -s "${dns_file}" ]; then
                    all_ready=false
                    break
                fi
            done
            if ${all_ready}; then
                log "All DNS files ready after ${elapsed}s"
                break
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done
        if ! ${all_ready}; then
            log "WARNING: Timed out waiting for DNS files. Starting with available data."
        fi
    fi
else
    log "No ${INSTANCES_JSON} found, skipping DNS file wait"
fi

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
dnsmasq --no-daemon --log-queries --conf-file="${CONF}" &
DNSMASQ_PID=$!
log "dnsmasq PID=${DNSMASQ_PID}"

trap 'kill -TERM "${DNSMASQ_PID}" 2>/dev/null; exit 0' TERM INT

snapshot_dns_files() {
    for f in /shared/*-dns-ip; do
        [ -f "${f}" ] || continue
        printf '%s:%s ' "${f}" "$(stat -c '%Y' "${f}" 2>/dev/null)"
    done
}

watch_dns_files() {
    last_state="$(snapshot_dns_files)"
    while kill -0 "${DNSMASQ_PID}" 2>/dev/null; do
        sleep 5
        new_state="$(snapshot_dns_files)"
        if [ "${new_state}" != "${last_state}" ]; then
            log "DNS-IP file change detected; flushing dnsmasq cache (SIGHUP)"
            kill -HUP "${DNSMASQ_PID}" 2>/dev/null || true
            last_state="${new_state}"
        fi
    done
}

watch_dns_files &
wait "${DNSMASQ_PID}"
