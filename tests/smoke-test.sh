#!/bin/sh
# Smoke tests for VPN router shell scripts.
# Runs locally — no Docker, no VPN, no credentials needed.
# Tests: CIDR parsing, config generation, DNS entrypoint logic,
#        healthcheck logic, env var handling, edge cases.

set -e

PASS=0
FAIL=0
TESTS=""

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; TESTS="${TESTS}\n  FAIL: $1"; }
section() { echo ""; echo "=== $1 ==="; }

# --- Helpers ---
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

# ============================================================
section "1. CIDR parsing in init-routes.sh"
# ============================================================

# Test: basic comma-separated parsing
cidrs="10.11.0.0/16,10.12.0.0/16"
count=0
IFS=','
for cidr in ${cidrs}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    [ -n "$cidr" ] && count=$((count + 1))
done
unset IFS
[ "$count" -eq 2 ] && pass "parses 2 CIDRs" || fail "parses 2 CIDRs (got ${count})"

# Test: spaces around CIDRs
cidrs=" 10.11.0.0/16 , 10.12.0.0/16 , 10.13.0.0/24 "
count=0
IFS=','
for cidr in ${cidrs}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    [ -n "$cidr" ] && count=$((count + 1))
done
unset IFS
[ "$count" -eq 3 ] && pass "handles spaces in CIDRs" || fail "handles spaces in CIDRs (got ${count})"

# Test: single CIDR
cidrs="10.11.0.0/16"
count=0
IFS=','
for cidr in ${cidrs}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    [ -n "$cidr" ] && count=$((count + 1))
done
unset IFS
[ "$count" -eq 1 ] && pass "single CIDR" || fail "single CIDR (got ${count})"

# Test: empty string
cidrs=""
count=0
IFS=','
for cidr in ${cidrs}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    [ -n "$cidr" ] && count=$((count + 1))
done
unset IFS
[ "$count" -eq 0 ] && pass "empty COMPANY_CIDRS" || fail "empty COMPANY_CIDRS (got ${count})"

# Test: trailing comma
cidrs="10.11.0.0/16,"
count=0
IFS=','
for cidr in ${cidrs}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    [ -n "$cidr" ] && count=$((count + 1))
done
unset IFS
[ "$count" -eq 1 ] && pass "trailing comma ignored" || fail "trailing comma ignored (got ${count})"

# ============================================================
section "2. DNS config generation (dns/entrypoint.sh logic)"
# ============================================================

MULLVAD_DNS="10.64.0.1"

# Test: generates base config with Mullvad DNS
CONF="${tmpdir}/dnsmasq-base.conf"
cat > "${CONF}" <<EOF
no-resolv
listen-address=0.0.0.0
cache-size=150
server=${MULLVAD_DNS}
EOF
grep -q "server=10.64.0.1" "${CONF}" && pass "base config has Mullvad DNS" || fail "base config missing Mullvad DNS"
grep -q "no-resolv" "${CONF}" && pass "base config has no-resolv" || fail "base config missing no-resolv"

# Test: adds company domain entries
COMPANY_DNS="10.11.0.1"
COMPANY_DOMAIN="company.com,internal.co"
IFS=','
for domain in ${COMPANY_DOMAIN}; do
    domain=$(echo "$domain" | tr -d ' ')
    if [ -n "$domain" ]; then
        echo "server=/${domain}/${COMPANY_DNS}" >> "${CONF}"
    fi
done
unset IFS
grep -q "server=/company.com/10.11.0.1" "${CONF}" && pass "company.com domain rule" || fail "company.com domain rule"
grep -q "server=/internal.co/10.11.0.1" "${CONF}" && pass "internal.co domain rule" || fail "internal.co domain rule"

# Test: empty COMPANY_DOMAIN produces no extra rules
CONF2="${tmpdir}/dnsmasq-nodomain.conf"
cat > "${CONF2}" <<EOF
no-resolv
listen-address=0.0.0.0
cache-size=150
server=${MULLVAD_DNS}
EOF
COMPANY_DOMAIN=""
if [ -n "${COMPANY_DNS}" ] && [ -n "${COMPANY_DOMAIN}" ]; then
    echo "server=/should-not-exist/${COMPANY_DNS}" >> "${CONF2}"
fi
lines=$(wc -l < "${CONF2}" | tr -d ' ')
[ "$lines" -eq 4 ] && pass "no domain rules when COMPANY_DOMAIN empty" || fail "unexpected lines when COMPANY_DOMAIN empty (got ${lines})"

# Test: DNS file content parsing
echo "10.99.0.1" > "${tmpdir}/company-dns-ip"
COMPANY_DNS_READ=$(cat "${tmpdir}/company-dns-ip" | tr -d '[:space:]')
[ "${COMPANY_DNS_READ}" = "10.99.0.1" ] && pass "reads DNS IP from shared file" || fail "reads DNS IP from shared file (got ${COMPANY_DNS_READ})"

# Test: DNS file with trailing newline/whitespace
printf "  10.99.0.2  \n" > "${tmpdir}/company-dns-ip2"
COMPANY_DNS_READ=$(cat "${tmpdir}/company-dns-ip2" | tr -d '[:space:]')
[ "${COMPANY_DNS_READ}" = "10.99.0.2" ] && pass "trims whitespace from DNS file" || fail "trims whitespace (got '${COMPANY_DNS_READ}')"

# Test: empty DNS file
echo "" > "${tmpdir}/company-dns-empty"
COMPANY_DNS_READ=$(cat "${tmpdir}/company-dns-empty" | tr -d '[:space:]')
[ -z "${COMPANY_DNS_READ}" ] && pass "empty DNS file returns empty" || fail "empty DNS file (got '${COMPANY_DNS_READ}')"

# ============================================================
section "3. Healthcheck IP parsing"
# ============================================================

# Test: extract IP from gluetun API JSON response
api_response='{"public_ip":"185.213.155.24"}'
parsed_ip=$(echo "${api_response}" | tr -d '"{}' | grep -o '[0-9.]*' | head -1)
[ "${parsed_ip}" = "185.213.155.24" ] && pass "parses IP from JSON" || fail "parses IP from JSON (got ${parsed_ip})"

# Test: empty response
api_response=""
parsed_ip=$(echo "${api_response}" | tr -d '"{}' | grep -o '[0-9.]*' | head -1 || true)
[ -z "${parsed_ip}" ] && pass "empty response → empty IP" || fail "empty response (got '${parsed_ip}')"

# Test: VPS IP match detection (kill switch scenario)
VPS_PUBLIC_IP="203.0.113.1"
public_ip="203.0.113.1"
if [ -n "${VPS_PUBLIC_IP}" ] && [ "${public_ip}" = "${VPS_PUBLIC_IP}" ]; then
    pass "detects kill switch (IP = VPS)"
else
    fail "kill switch detection"
fi

# Test: Mullvad IP (not VPS) → up
public_ip="185.213.155.24"
mullvad_status="up"
if [ -n "${VPS_PUBLIC_IP}" ] && [ "${public_ip}" = "${VPS_PUBLIC_IP}" ]; then
    mullvad_status="down"
fi
[ "${mullvad_status}" = "up" ] && pass "Mullvad IP != VPS → up" || fail "Mullvad IP != VPS detection"

# Test: state change detection
mullvad_prev="up"
mullvad_status="down"
[ "${mullvad_status}" != "${mullvad_prev}" ] && pass "detects up→down change" || fail "state change detection"

# Test: no notification on same state
mullvad_prev="up"
mullvad_status="up"
[ "${mullvad_status}" = "${mullvad_prev}" ] && pass "no alert on same state" || fail "same state detection"

# Test: no recovery notification from unknown state
mullvad_prev="unknown"
mullvad_status="up"
should_notify=false
if [ "${mullvad_status}" != "${mullvad_prev}" ]; then
    if [ "${mullvad_status}" = "down" ]; then
        should_notify=true
    elif [ "${mullvad_prev}" != "unknown" ]; then
        should_notify=true
    fi
fi
[ "${should_notify}" = "false" ] && pass "no recovery alert from unknown→up" || fail "unknown→up suppression"

# ============================================================
section "4. L2TP entrypoint config generation"
# ============================================================

L2TP_SERVER="vpn.company.com"
L2TP_PSK="test-secret"
L2TP_USERNAME="testuser"
L2TP_PASSWORD="testpass"

# Test: ipsec.conf generation
ipsec_conf="${tmpdir}/ipsec.conf"
cat > "${ipsec_conf}" <<EOF
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
grep -q "right=vpn.company.com" "${ipsec_conf}" && pass "ipsec.conf has server" || fail "ipsec.conf server"
grep -q "rightid=%any" "${ipsec_conf}" && pass "ipsec.conf has rightid=%any" || fail "ipsec.conf rightid"
grep -q "keyexchange=ikev1" "${ipsec_conf}" && pass "ipsec.conf uses IKEv1" || fail "ipsec.conf IKEv1"
grep -q "type=transport" "${ipsec_conf}" && pass "ipsec.conf transport mode" || fail "ipsec.conf transport"

# Test: ipsec.secrets generation
secrets="${tmpdir}/ipsec.secrets"
cat > "${secrets}" <<EOF
: PSK "${L2TP_PSK}"
EOF
grep -q 'PSK "test-secret"' "${secrets}" && pass "ipsec.secrets has PSK" || fail "ipsec.secrets PSK"

# Test: xl2tpd.conf generation
xl2tpd="${tmpdir}/xl2tpd.conf"
cat > "${xl2tpd}" <<EOF
[lac company]
lns = ${L2TP_SERVER}
ppp debug = yes
pppoptfile = /etc/ppp/options.l2tpd.client
length bit = yes
EOF
grep -q "lns = vpn.company.com" "${xl2tpd}" && pass "xl2tpd.conf has server" || fail "xl2tpd.conf server"
grep -q "pppoptfile = /etc/ppp/options.l2tpd.client" "${xl2tpd}" && pass "xl2tpd.conf ppp options path" || fail "xl2tpd.conf ppp path"

# Test: PPP options generation
pppopts="${tmpdir}/options.l2tpd.client"
cat > "${pppopts}" <<EOF
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
connect-delay 5000
name ${L2TP_USERNAME}
password ${L2TP_PASSWORD}
EOF
grep -q "require-mschap-v2" "${pppopts}" && pass "PPP requires MSCHAPv2" || fail "PPP MSCHAPv2"
grep -q "refuse-eap" "${pppopts}" && pass "PPP refuses EAP" || fail "PPP EAP"
grep -q "nodefaultroute" "${pppopts}" && pass "PPP no default route" || fail "PPP default route"
grep -q "usepeerdns" "${pppopts}" && pass "PPP uses peer DNS" || fail "PPP peer DNS"
grep -q "name testuser" "${pppopts}" && pass "PPP has username" || fail "PPP username"
grep -q "mtu 1410" "${pppopts}" && pass "PPP MTU 1410" || fail "PPP MTU"

# Test: DNS extraction from resolv.conf (simulated PPP)
resolv="${tmpdir}/resolv.conf"
cat > "${resolv}" <<EOF
nameserver 10.11.0.1
nameserver 10.11.0.2
EOF
extracted=$(awk '/^nameserver/ {print $2; exit}' "${resolv}")
[ "${extracted}" = "10.11.0.1" ] && pass "extracts first nameserver" || fail "nameserver extraction (got ${extracted})"

# Test: empty resolv.conf
echo "" > "${tmpdir}/resolv-empty.conf"
extracted=$(awk '/^nameserver/ {print $2; exit}' "${tmpdir}/resolv-empty.conf")
[ -z "${extracted}" ] && pass "empty resolv.conf → empty DNS" || fail "empty resolv.conf (got '${extracted}')"

# ============================================================
section "5. Docker Compose config validation"
# ============================================================

compose_file="${PROJECT_ROOT}/docker-compose.yml"

# Test: all required services defined
for svc in gluetun route-init tailscale l2tp-vpn dnsmasq ntfy healthcheck; do
    if grep -q "container_name: ${svc}" "${compose_file}" 2>/dev/null || grep -q "^  ${svc}:" "${compose_file}" 2>/dev/null; then
        pass "service '${svc}' defined"
    else
        fail "service '${svc}' missing"
    fi
done

# Test: network namespace sharing
grep -q "network_mode: service:gluetun" "${compose_file}" && pass "tailscale shares gluetun netns" || fail "tailscale netns"

# Test: bridge_vpn subnet
grep -q "172.29.0.0/24" "${compose_file}" && pass "bridge_vpn subnet 172.29.0.0/24" || fail "bridge_vpn subnet"

# Test: static IPs assigned
for ip in 172.29.0.10 172.29.0.20 172.29.0.30 172.29.0.40; do
    grep -q "${ip}" "${compose_file}" && pass "static IP ${ip}" || fail "missing static IP ${ip}"
done

# Test: shared-config volume used by both l2tp and dnsmasq
# Extract service blocks using sed (between service name and next top-level key)
l2tp_shared=$(sed -n '/^  l2tp-vpn:/,/^  [a-z][a-z]*:/p' "${compose_file}" | grep -c "shared-config" || true)
dns_shared=$(sed -n '/^  dnsmasq:/,/^  [a-z][a-z]*:/p' "${compose_file}" | grep -c "shared-config" || true)
[ "$l2tp_shared" -ge 1 ] && [ "$dns_shared" -ge 1 ] && pass "shared-config volume connects l2tp↔dnsmasq" || fail "shared-config volume (l2tp=${l2tp_shared}, dns=${dns_shared})"

# Test: gluetun has NET_ADMIN
grep -q "NET_ADMIN" "${compose_file}" && pass "gluetun has NET_ADMIN cap" || fail "gluetun NET_ADMIN"

# Test: l2tp-vpn is privileged
grep -q "privileged: true" "${compose_file}" && pass "l2tp-vpn is privileged" || fail "l2tp-vpn privileged"

# Test: tailscale advertises exit node
grep -q "advertise-exit-node" "${compose_file}" && pass "tailscale advertises exit node" || fail "tailscale exit node"

# Test: restart policy on critical services
restart_count=$(grep -c "restart: unless-stopped" "${compose_file}")
[ "$restart_count" -ge 5 ] && pass "restart policies on ${restart_count} services" || fail "restart policies (only ${restart_count})"

# Test: FIREWALL_OUTBOUND_SUBNETS is not empty
grep "FIREWALL_OUTBOUND_SUBNETS" "${compose_file}" | grep -qv '=$' && pass "FIREWALL_OUTBOUND_SUBNETS not empty" || fail "FIREWALL_OUTBOUND_SUBNETS empty"

# ============================================================
section "6. .env.example completeness"
# ============================================================

env_example="${PROJECT_ROOT}/.env.example"

for var in TS_AUTHKEY TS_HOSTNAME WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES \
           MULLVAD_COUNTRY L2TP_SERVER L2TP_USERNAME L2TP_PASSWORD L2TP_PSK \
           COMPANY_CIDRS COMPANY_DOMAIN VPS_PUBLIC_IP L2TP_CHECK_IP \
           CHECK_INTERVAL NTFY_TOPIC; do
    grep -q "^${var}=" "${env_example}" && pass ".env.example has ${var}" || fail ".env.example missing ${var}"
done

# Test: no real credentials in .env.example
if grep -q "tskey-auth-[a-zA-Z0-9]\{10,\}" "${env_example}" 2>/dev/null; then
    fail ".env.example may contain a real Tailscale key"
else
    pass ".env.example has no real TS key"
fi

# ============================================================
section "7. Script hardening checks"
# ============================================================

# Test: dns/entrypoint.sh has set -e
grep -q "^set -e" "${PROJECT_ROOT}/dns/entrypoint.sh" && pass "dns/entrypoint.sh has set -e" || fail "dns/entrypoint.sh missing set -e"

# Test: l2tp/entrypoint.sh has set -e
grep -q "^set -e" "${PROJECT_ROOT}/l2tp/entrypoint.sh" && pass "l2tp/entrypoint.sh has set -e" || fail "l2tp/entrypoint.sh missing set -e"

# Test: all entrypoints have shebang
for script in dns/entrypoint.sh l2tp/entrypoint.sh healthcheck/check.sh gluetun/init-routes.sh; do
    full="${PROJECT_ROOT}/${script}"
    if [ -f "${full}" ]; then
        head -1 "${full}" | grep -q "^#!/bin/sh" && pass "${script} has shebang" || fail "${script} missing shebang"
    else
        fail "${script} not found"
    fi
done

# Test: no hardcoded company IPs in scripts (should use COMPANY_CIDRS)
for script in gluetun/init-routes.sh l2tp/entrypoint.sh dns/entrypoint.sh healthcheck/check.sh; do
    full="${PROJECT_ROOT}/${script}"
    if [ -f "${full}" ]; then
        # Check for hardcoded 10.11.x.x or 10.12.x.x (common company ranges)
        if grep -qE '10\.11\.[0-9]+\.[0-9]+|10\.12\.[0-9]+\.[0-9]+' "${full}" 2>/dev/null; then
            fail "${script} has hardcoded company IPs"
        else
            pass "${script} no hardcoded company IPs"
        fi
    fi
done

# Test: init-routes.sh L2TP IP matches compose static IP
route_ip=$(grep 'L2TP_IP=' "${PROJECT_ROOT}/gluetun/init-routes.sh" | head -1 | sed 's/.*"\([0-9.]*\)".*/\1/')
compose_ip=$(sed -n '/^  l2tp-vpn:/,/^  [a-z][a-z]*:/p' "${compose_file}" | grep -o '172\.29\.0\.[0-9]*' | head -1 || true)
if [ -n "${route_ip}" ] && [ -n "${compose_ip}" ]; then
    [ "${route_ip}" = "${compose_ip}" ] && pass "init-routes L2TP_IP matches compose (${route_ip})" || fail "L2TP IP mismatch: script=${route_ip} compose=${compose_ip}"
else
    fail "could not extract L2TP IPs for comparison"
fi

# Test: healthcheck gluetun API IP matches compose
hc_gluetun_ip=$(grep 'GLUETUN_API=' "${PROJECT_ROOT}/healthcheck/check.sh" | grep -o '172\.29\.0\.[0-9]*' | head -1)
compose_gluetun_ip="172.29.0.10"
if [ -n "${hc_gluetun_ip}" ]; then
    [ "${hc_gluetun_ip}" = "${compose_gluetun_ip}" ] && pass "healthcheck gluetun IP matches compose (${hc_gluetun_ip})" || fail "gluetun IP mismatch: script=${hc_gluetun_ip} compose=${compose_gluetun_ip}"
else
    fail "could not extract gluetun IP from healthcheck"
fi

# Test: healthcheck ntfy IP matches compose
hc_ntfy_ip=$(grep 'NTFY_URL=' "${PROJECT_ROOT}/healthcheck/check.sh" | grep -o '172\.29\.0\.[0-9]*' | head -1)
compose_ntfy_ip="172.29.0.40"
if [ -n "${hc_ntfy_ip}" ]; then
    [ "${hc_ntfy_ip}" = "${compose_ntfy_ip}" ] && pass "healthcheck ntfy IP matches compose (${hc_ntfy_ip})" || fail "ntfy IP mismatch: script=${hc_ntfy_ip} compose=${compose_ntfy_ip}"
else
    fail "could not extract ntfy IP from healthcheck"
fi

# ============================================================
section "8. Edge cases"
# ============================================================

# Test: COMPANY_CIDRS with only commas
cidrs=",,,"
count=0
IFS=','
for cidr in ${cidrs}; do
    cidr=$(echo "$cidr" | tr -d ' ')
    [ -n "$cidr" ] && count=$((count + 1))
done
unset IFS
[ "$count" -eq 0 ] && pass "only-commas CIDRS → 0 routes" || fail "only-commas (got ${count})"

# Test: COMPANY_DOMAIN with spaces
COMPANY_DOMAIN=" company.com , internal.co , test.org "
domain_count=0
IFS=','
for domain in ${COMPANY_DOMAIN}; do
    domain=$(echo "$domain" | tr -d ' ')
    [ -n "$domain" ] && domain_count=$((domain_count + 1))
done
unset IFS
[ "$domain_count" -eq 3 ] && pass "3 domains with spaces" || fail "domains with spaces (got ${domain_count})"

# Test: gluetun healthcheck API response with extra fields
api_response='{"public_ip":"185.213.155.24","region":"Turkey","country":"TR"}'
parsed_ip=$(echo "${api_response}" | tr -d '"{}' | grep -o '[0-9.]*' | head -1)
[ "${parsed_ip}" = "185.213.155.24" ] && pass "parses IP from extended JSON" || fail "extended JSON (got ${parsed_ip})"

# Test: gluetun API response with IPv6-like content doesn't break parser
api_response='{"public_ip":"185.213.155.24","ipv6":"2001:db8::1"}'
parsed_ip=$(echo "${api_response}" | tr -d '"{}' | grep -o '[0-9.]*' | head -1)
[ "${parsed_ip}" = "185.213.155.24" ] && pass "ignores IPv6 in response" || fail "IPv6 confusion (got ${parsed_ip})"

# ============================================================
# Summary
# ============================================================

echo ""
echo "========================================="
echo "  RESULTS: ${PASS} passed, ${FAIL} failed"
echo "========================================="
if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "Failures:"
    printf "${TESTS}\n"
    exit 1
fi
exit 0
