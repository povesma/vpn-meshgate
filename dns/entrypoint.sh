#!/bin/sh
set -e

MULLVAD_DNS="${DEFAULT_DNS:-1.1.1.1}"
INSTANCES_JSON="/shared/vpn-instances.json"
CONF="/etc/dnsmasq.conf"
GLUETUN_DNS_API="${GLUETUN_DNS_API:-http://172.29.0.10:8000/v1/dns/status}"

log() { echo "[dnsmasq] $*"; }

flush_gluetun_dns() {
    curl -sf --max-time 3 -X PUT \
        -H 'Content-Type: application/json' \
        -d '{"status":"stopped"}' "${GLUETUN_DNS_API}" >/dev/null 2>&1 || return 1
    sleep 1
    curl -sf --max-time 3 -X PUT \
        -H 'Content-Type: application/json' \
        -d '{"status":"running"}' "${GLUETUN_DNS_API}" >/dev/null 2>&1 || return 1
}

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

generate_dnsmasq_conf() {
    cat > "${CONF}" <<EOF
no-resolv
cache-size=150
server=${MULLVAD_DNS}
EOF

    if [ ! -f "${INSTANCES_JSON}" ]; then
        log "WARNING: No ${INSTANCES_JSON} found. Mullvad-only DNS."
        return 0
    fi

    for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
        local_name=$(echo "$row" | jq -r '.name')
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
}

add_instance_routes() {
    [ -f "${INSTANCES_JSON}" ] || return 0
    for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
        local_ip=$(echo "$row" | jq -r '.ip')
        local_name=$(echo "$row" | jq -r '.name')
        for cidr in $(echo "$row" | jq -r '.cidrs[]'); do
            ip route add "${cidr}" via "${local_ip}" 2>/dev/null && \
                log "  route: ${cidr} via ${local_ip} (${local_name})" || \
                log "  route: ${cidr} already exists or failed"
        done
    done
}

log "Generating dnsmasq.conf"
generate_dnsmasq_conf

log "Adding routes to VPN instances"
add_instance_routes

log "Default DNS: ${MULLVAD_DNS}"
log "Config:"
cat "${CONF}"

RELOAD_FLAG="/run/dnsmasq.reload"
SHUTDOWN_FLAG="/run/dnsmasq.shutdown"
rm -f "${RELOAD_FLAG}" "${SHUTDOWN_FLAG}"

snapshot_dns_files() {
    for f in /shared/*-dns-ip; do
        [ -f "${f}" ] || continue
        printf '%s:%s ' "${f}" "$(stat -c '%Y' "${f}" 2>/dev/null)"
    done
}

# Watcher: just sets a reload flag. The main shell owns dnsmasq.
watch_dns_files() {
    last_state="$(snapshot_dns_files)"
    while [ ! -f "${SHUTDOWN_FLAG}" ]; do
        sleep 5
        new_state="$(snapshot_dns_files)"
        if [ "${new_state}" != "${last_state}" ]; then
            log "DNS-IP file change detected"
            touch "${RELOAD_FLAG}"
            last_state="${new_state}"
        fi
    done
}

watch_dns_files &
WATCHER_PID=$!

trap 'touch "${SHUTDOWN_FLAG}"; kill -TERM "${DNSMASQ_PID}" 2>/dev/null; kill "${WATCHER_PID}" 2>/dev/null; exit 0' TERM INT

# Main loop: run dnsmasq in foreground; respawn on reload-flag or unexpected exit.
while [ ! -f "${SHUTDOWN_FLAG}" ]; do
    log "Starting dnsmasq"
    dnsmasq --no-daemon --log-queries --conf-file="${CONF}" &
    DNSMASQ_PID=$!
    log "dnsmasq PID=${DNSMASQ_PID}"

    # Poll: exit wait if dnsmasq dies OR a reload was requested.
    while kill -0 "${DNSMASQ_PID}" 2>/dev/null; do
        if [ -f "${RELOAD_FLAG}" ]; then
            rm -f "${RELOAD_FLAG}"
            log "Reload requested; regenerating dnsmasq.conf and restarting dnsmasq"
            generate_dnsmasq_conf
            kill -TERM "${DNSMASQ_PID}" 2>/dev/null || true
            wait "${DNSMASQ_PID}" 2>/dev/null || true
            if flush_gluetun_dns; then
                log "Gluetun DNS cache flushed (stop/start cycle)"
            else
                log "WARNING: failed to flush gluetun DNS cache"
            fi
            break
        fi
        sleep 2
    done

    # If shutting down, exit; else loop respawns dnsmasq.
    [ -f "${SHUTDOWN_FLAG}" ] && break

    # If dnsmasq exited on its own (no reload flag), wait briefly to avoid tight loop.
    if [ ! -f "${RELOAD_FLAG}" ] && ! kill -0 "${DNSMASQ_PID}" 2>/dev/null; then
        wait "${DNSMASQ_PID}" 2>/dev/null
        rc=$?
        log "dnsmasq exited (rc=${rc}); respawning in 2s"
        sleep 2
    fi
done

kill "${WATCHER_PID}" 2>/dev/null || true
