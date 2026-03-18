#!/bin/sh
set -e

MULLVAD_DNS="${DEFAULT_DNS:-1.1.1.1}"
SHARED_DNS_FILE="/shared/company-dns-ip"
CONF="/etc/dnsmasq.conf"

log() { echo "[dnsmasq] $*"; }

log "Waiting for company DNS IP from L2TP container..."
COMPANY_DNS=""
for i in $(seq 1 60); do
    if [ -f "${SHARED_DNS_FILE}" ]; then
        COMPANY_DNS=$(cat "${SHARED_DNS_FILE}" | tr -d '[:space:]')
        if [ -n "${COMPANY_DNS}" ]; then
            log "Got company DNS: ${COMPANY_DNS}"
            break
        fi
    fi
    sleep 2
done

if [ -z "${COMPANY_DNS}" ]; then
    log "WARNING: No company DNS received after 120s. Using Mullvad-only DNS."
fi

log "Generating dnsmasq.conf"
cat > "${CONF}" <<EOF
no-resolv
cache-size=150
server=${MULLVAD_DNS}
EOF

if [ -n "${COMPANY_DNS}" ] && [ -n "${COMPANY_DOMAIN}" ]; then
    IFS=','
    for domain in ${COMPANY_DOMAIN}; do
        domain=$(echo "$domain" | tr -d ' ')
        if [ -n "$domain" ]; then
            echo "server=/${domain}/${COMPANY_DNS}" >> "${CONF}"
            log "  ${domain} -> ${COMPANY_DNS}"
        fi
    done
    unset IFS
fi

L2TP_GW="172.29.0.20"
if [ -n "${COMPANY_CIDRS}" ]; then
    log "Adding routes to company CIDRs via ${L2TP_GW}"
    IFS=','
    for cidr in ${COMPANY_CIDRS}; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if [ -n "$cidr" ]; then
            ip route add "$cidr" via "$L2TP_GW" 2>/dev/null && log "  route: ${cidr} via ${L2TP_GW}" || log "  route: ${cidr} already exists or failed"
        fi
    done
    unset IFS
fi

log "Default DNS: ${MULLVAD_DNS}"
log "Config:"
cat "${CONF}"

log "Starting dnsmasq"
exec dnsmasq --no-daemon --log-queries --conf-file="${CONF}"
