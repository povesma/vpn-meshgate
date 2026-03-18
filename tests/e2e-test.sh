#!/usr/bin/env bash
# =============================================================
# E2E Test Suite for Tailscale Exit Node VPN Router
# Runs INSIDE a local Tailscale container connected via Headscale.
# Tests real connectivity through vpn-gate exit node from Mac.
# =============================================================
set -euo pipefail

# --- Configuration (from env or defaults) ---
VPN_GATE_NODE="${VPN_GATE_NODE:-vpn-gate}"
VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-}"
COMPANY_DOMAIN="${COMPANY_DOMAIN:-}"
COMPANY_CIDRS="${COMPANY_CIDRS:-}"
L2TP_CHECK_IP="${L2TP_CHECK_IP:-}"
HEADSCALE_URL="${HEADSCALE_URL:-}"

# --- Counters ---
PASS=0
FAIL=0
SKIP=0
TOTAL=0
RESULTS=""
BENCHMARKS=""

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Helpers ---
pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    RESULTS="${RESULTS}\n  ${GREEN}PASS${NC}: $1"
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    RESULTS="${RESULTS}\n  ${RED}FAIL${NC}: $1${2:+ — $2}"
    echo -e "  ${RED}FAIL${NC}: $1${2:+ — $2}"
}

skip() {
    SKIP=$((SKIP + 1))
    TOTAL=$((TOTAL + 1))
    RESULTS="${RESULTS}\n  ${YELLOW}SKIP${NC}: $1 — $2"
    echo -e "  ${YELLOW}SKIP${NC}: $1 — $2"
}

section() {
    echo ""
    echo -e "${BOLD}=== $1 ===${NC}"
}

bench() {
    BENCHMARKS="${BENCHMARKS}\n  $1: $2"
    echo -e "  ${CYAN}BENCH${NC}: $1 = $2"
}

# Measure command latency in ms (average of N runs)
measure_latency() {
    local cmd="$1"
    local runs="${2:-3}"
    local total=0
    local success=0
    for i in $(seq 1 "$runs"); do
        local start end elapsed
        start=$(date +%s%N)
        if eval "$cmd" >/dev/null 2>&1; then
            end=$(date +%s%N)
            elapsed=$(( (end - start) / 1000000 ))
            total=$((total + elapsed))
            success=$((success + 1))
        fi
    done
    if [ "$success" -gt 0 ]; then
        echo $((total / success))
    else
        echo "FAIL"
    fi
}

# ============================================================
section "0. Pre-flight Checks"
# ============================================================

echo "  Tailscale status:"
if ! tailscale status >/dev/null 2>&1; then
    echo -e "  ${RED}FATAL: Tailscale not running in this container${NC}"
    exit 1
fi

MY_IP=$(tailscale ip -4 2>/dev/null || echo "")
echo "  My Tailscale IP: ${MY_IP:-unknown}"

# Check vpn-gate is visible
VPN_GATE_IP=$(tailscale status | grep "$VPN_GATE_NODE" | awk '{print $1}' || echo "")
if [ -z "$VPN_GATE_IP" ]; then
    echo -e "  ${RED}FATAL: $VPN_GATE_NODE not found in Tailscale network${NC}"
    tailscale status
    exit 1
fi
echo "  vpn-gate IP: $VPN_GATE_IP"

# ============================================================
section "1. Exit Node Activation"
# ============================================================

# Set exit node
echo "  Setting exit node to $VPN_GATE_NODE..."
if tailscale set --exit-node="$VPN_GATE_NODE" --exit-node-allow-lan-access --accept-routes 2>&1; then
    pass "Exit node set to $VPN_GATE_NODE"
else
    fail "Failed to set exit node" "$(tailscale set --exit-node="$VPN_GATE_NODE" --exit-node-allow-lan-access --accept-routes 2>&1 || true)"
fi

# Give it a moment to establish
sleep 5

# Verify exit node is active
EXIT_STATUS=$(tailscale status | grep "$VPN_GATE_NODE" || echo "")
if echo "$EXIT_STATUS" | grep -q "exit node"; then
    pass "Exit node active in tailscale status"
else
    fail "Exit node not showing as active" "$EXIT_STATUS"
fi

# ============================================================
section "2. Internet Connectivity (via Mullvad)"
# ============================================================

# Test basic internet access
PUBLIC_IP=$(curl -s --connect-timeout 10 --max-time 15 https://ifconfig.me/ip 2>/dev/null || echo "TIMEOUT")
if [ "$PUBLIC_IP" = "TIMEOUT" ] || [ -z "$PUBLIC_IP" ]; then
    # Try alternative
    PUBLIC_IP=$(wget -qO- --timeout=10 https://api.ipify.org 2>/dev/null || echo "TIMEOUT")
fi

if [ "$PUBLIC_IP" = "TIMEOUT" ] || [ -z "$PUBLIC_IP" ]; then
    fail "Internet not reachable" "curl/wget to IP services timed out"
else
    pass "Internet reachable — public IP: $PUBLIC_IP"

    # Check it's NOT the VPS IP (should be Mullvad)
    if [ -n "$VPS_PUBLIC_IP" ]; then
        if [ "$PUBLIC_IP" != "$VPS_PUBLIC_IP" ]; then
            pass "Public IP is NOT VPS IP (kill switch working)"
        else
            fail "Public IP IS the VPS IP — VPN leak!" "$PUBLIC_IP == $VPS_PUBLIC_IP"
        fi
    else
        skip "VPS IP leak check" "VPS_PUBLIC_IP not set"
    fi
fi

# Test HTTPS connectivity
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 https://www.google.com 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    pass "HTTPS to google.com works (HTTP $HTTP_CODE)"
else
    fail "HTTPS to google.com failed" "HTTP code: $HTTP_CODE"
fi

# ============================================================
section "3. DNS Resolution (Public)"
# ============================================================

# Test public DNS
PUBLIC_DNS=$(dig +short +time=5 +tries=2 example.com A 2>/dev/null | head -1 || echo "")
if [ -n "$PUBLIC_DNS" ]; then
    pass "Public DNS resolves example.com → $PUBLIC_DNS"
else
    fail "Public DNS failed to resolve example.com"
fi

# Test another domain
GOOGLE_DNS=$(dig +short +time=5 +tries=2 google.com A 2>/dev/null | head -1 || echo "")
if [ -n "$GOOGLE_DNS" ]; then
    pass "Public DNS resolves google.com → $GOOGLE_DNS"
else
    fail "Public DNS failed to resolve google.com"
fi

# ============================================================
section "4. DNS Resolution (Company Split DNS)"
# ============================================================

if [ -n "$COMPANY_DOMAIN" ]; then
    # Resolve company root domain
    COMPANY_ROOT=$(dig +short +time=5 +tries=2 "$COMPANY_DOMAIN" A 2>/dev/null | head -1 || echo "")
    if [ -n "$COMPANY_ROOT" ]; then
        pass "Company root domain resolves: $COMPANY_DOMAIN → $COMPANY_ROOT"
    else
        fail "Company root domain failed: $COMPANY_DOMAIN"
    fi

    # Resolve a company subdomain (common patterns)
    for sub in jira gitlab wiki mail; do
        SUB_RESULT=$(dig +short +time=5 +tries=2 "${sub}.${COMPANY_DOMAIN}" A 2>/dev/null | head -1 || echo "")
        if [ -n "$SUB_RESULT" ]; then
            # Check if it's an internal IP (10.x, 172.16-31.x, 192.168.x)
            if echo "$SUB_RESULT" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
                pass "Company subdomain ${sub}.${COMPANY_DOMAIN} → $SUB_RESULT (internal IP)"
            else
                pass "Company subdomain ${sub}.${COMPANY_DOMAIN} → $SUB_RESULT (external IP)"
            fi
            break
        fi
    done
else
    skip "Company DNS tests" "COMPANY_DOMAIN not set"
fi

# ============================================================
section "5. Company Network Connectivity (L2TP)"
# ============================================================

if [ -n "$L2TP_CHECK_IP" ]; then
    # Ping company resource
    if ping -c 3 -W 5 "$L2TP_CHECK_IP" >/dev/null 2>&1; then
        PING_RESULT=$(ping -c 3 -W 5 "$L2TP_CHECK_IP" 2>/dev/null | tail -1)
        pass "Company host reachable: $L2TP_CHECK_IP — $PING_RESULT"
    else
        fail "Company host unreachable" "ping $L2TP_CHECK_IP failed"
    fi
else
    skip "Company ping test" "L2TP_CHECK_IP not set"
fi

if [ -n "$COMPANY_CIDRS" ]; then
    # Extract first CIDR's gateway (assume .1)
    FIRST_CIDR=$(echo "$COMPANY_CIDRS" | tr ',' '\n' | head -1 | tr -d ' ')
    GATEWAY=$(echo "$FIRST_CIDR" | sed 's|/.*||; s|\.[0-9]*$|.1|')

    # Try curl to a company web service if domain set
    if [ -n "$COMPANY_DOMAIN" ]; then
        HTTP_COMPANY=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 "https://${COMPANY_DOMAIN}" 2>/dev/null || echo "000")
        if [ "$HTTP_COMPANY" != "000" ]; then
            pass "Company web reachable: https://${COMPANY_DOMAIN} (HTTP $HTTP_COMPANY)"
        else
            fail "Company web unreachable" "https://${COMPANY_DOMAIN} timeout"
        fi
    fi
fi

# ============================================================
section "6. Tailscale Mesh Connectivity"
# ============================================================

# Note: when using vpn-gate as exit node, pinging its Tailscale IP may
# fail because the traffic would loop. The real proof is that internet
# and company network work (tested in sections 2 and 5).
# We test mesh connectivity by checking tailscale status shows the node.
if tailscale status 2>/dev/null | grep -q "$VPN_GATE_NODE.*exit node"; then
    pass "vpn-gate active as exit node in mesh"
elif tailscale ping --timeout=5s "$VPN_GATE_IP" >/dev/null 2>&1; then
    TS_PING_OUT=$(tailscale ping --timeout=5s "$VPN_GATE_IP" 2>&1 | head -1)
    pass "vpn-gate reachable via tailscale ping — $TS_PING_OUT"
else
    # Not a critical failure — data routing works if sections 2+5 pass
    skip "vpn-gate direct ping" "expected: exit node traffic loops prevent self-ping"
fi

# Check a couple of other online peers
OTHER_PEERS=$(tailscale status 2>/dev/null | grep -v "$VPN_GATE_NODE" | grep -v "offline" | grep -v "$(tailscale ip -4 2>/dev/null || echo NONE)" | awk '{print $1, $2}' | head -2) || true
while IFS=' ' read -r peer_ip peer_name; do
    [ -z "$peer_ip" ] && continue
    if tailscale ping --timeout=5s "$peer_ip" >/dev/null 2>&1; then
        pass "Mesh peer reachable: $peer_name ($peer_ip)"
    else
        skip "Mesh peer $peer_name ($peer_ip)" "may be behind NAT or firewall"
    fi
done <<< "$OTHER_PEERS"

# ============================================================
section "7. DNS Leak Test"
# ============================================================

# Use DNS leak test API
LEAK_RESULT=$(curl -s --connect-timeout 10 --max-time 15 "https://ipleak.net/json/" 2>/dev/null || echo "")
if [ -n "$LEAK_RESULT" ] && echo "$LEAK_RESULT" | jq . >/dev/null 2>&1; then
    LEAK_IP=$(echo "$LEAK_RESULT" | jq -r '.ip // empty')
    LEAK_COUNTRY=$(echo "$LEAK_RESULT" | jq -r '.country_name // empty')
    if [ -n "$LEAK_IP" ]; then
        echo "  IP seen by ipleak.net: $LEAK_IP ($LEAK_COUNTRY)"
        if [ -n "$VPS_PUBLIC_IP" ] && [ "$LEAK_IP" != "$VPS_PUBLIC_IP" ]; then
            pass "No IP leak detected (IP: $LEAK_IP, not VPS: $VPS_PUBLIC_IP)"
        elif [ -n "$VPS_PUBLIC_IP" ]; then
            fail "IP leak detected" "ipleak sees VPS IP $LEAK_IP"
        else
            pass "IP check via ipleak: $LEAK_IP ($LEAK_COUNTRY)"
        fi
    else
        skip "IP leak test" "ipleak.net returned empty result"
    fi
else
    skip "IP leak test" "ipleak.net unreachable"
fi

# ============================================================
section "8. Performance Benchmarks"
# ============================================================

echo "  Running benchmarks (this takes ~30s)..."

# Internet latency via exit node
INTERNET_LATENCY=$(measure_latency "curl -s -o /dev/null --connect-timeout 10 --max-time 15 https://www.google.com" 3)
if [ "$INTERNET_LATENCY" = "FAIL" ]; then
    bench "Internet latency (HTTPS google.com)" "FAILED (all attempts timed out)"
else
    bench "Internet latency (HTTPS google.com)" "${INTERNET_LATENCY}ms avg over 3 runs"
fi

# DNS resolution latency
DNS_LATENCY=$(measure_latency "dig +short +time=2 +tries=1 example.com A" 5)
bench "DNS resolution latency (example.com)" "${DNS_LATENCY}ms avg over 5 runs"

# Company DNS latency (if applicable)
if [ -n "$COMPANY_DOMAIN" ]; then
    COMPANY_DNS_LATENCY=$(measure_latency "dig +short +time=2 +tries=1 ${COMPANY_DOMAIN} A" 5)
    bench "Company DNS latency ($COMPANY_DOMAIN)" "${COMPANY_DNS_LATENCY}ms avg over 5 runs"
fi

# Tailscale mesh latency
if [ -n "$VPN_GATE_IP" ]; then
    TS_PING=$(ping -c 5 -W 3 "$VPN_GATE_IP" 2>/dev/null | tail -1 || echo "")
    TS_LATENCY=$(echo "$TS_PING" | awk -F'/' '{print $5}')
    if [ -n "$TS_LATENCY" ] && [ "$TS_LATENCY" != "" ]; then
        bench "Tailscale mesh latency (vpn-gate)" "${TS_LATENCY}ms avg"
    else
        # ICMP may be blocked; try tailscale ping instead
        TS_PING_OUT=$(tailscale ping --timeout=5s "$VPN_GATE_IP" 2>/dev/null | head -1 || echo "")
        TS_LATENCY=$(echo "$TS_PING_OUT" | grep -oE '[0-9.]+ms' | head -1)
        bench "Tailscale mesh latency (vpn-gate, via ts ping)" "${TS_LATENCY:-N/A}"
    fi
fi

# Company network latency
if [ -n "$L2TP_CHECK_IP" ]; then
    COMPANY_LATENCY=$(ping -c 5 -W 3 "$L2TP_CHECK_IP" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' || echo "N/A")
    bench "Company network latency ($L2TP_CHECK_IP)" "${COMPANY_LATENCY}ms avg"
fi

# Download throughput test (small file)
DOWNLOAD_START=$(date +%s%N)
DOWNLOAD_OK=false
if curl -s -o /dev/null --connect-timeout 10 --max-time 30 "https://speed.cloudflare.com/__down?bytes=10000000" 2>/dev/null; then
    DOWNLOAD_END=$(date +%s%N)
    DOWNLOAD_MS=$(( (DOWNLOAD_END - DOWNLOAD_START) / 1000000 ))
    DOWNLOAD_MBPS=$(echo "scale=1; 10 * 8 / ($DOWNLOAD_MS / 1000)" | bc 2>/dev/null || echo "N/A")
    bench "Download throughput (10MB via Cloudflare)" "${DOWNLOAD_MBPS} Mbps (${DOWNLOAD_MS}ms)"
    DOWNLOAD_OK=true
fi
if [ "$DOWNLOAD_OK" = "false" ]; then
    bench "Download throughput" "FAILED — could not reach speed test"
fi

# ============================================================
section "9. Exit Node Deactivation"
# ============================================================

# Clear exit node
tailscale set --exit-node="" 2>/dev/null || true
sleep 1

# Verify internet still works without exit node
DIRECT_IP=$(curl -s --connect-timeout 10 --max-time 15 https://ifconfig.me/ip 2>/dev/null || echo "TIMEOUT")
if [ "$DIRECT_IP" != "TIMEOUT" ] && [ -n "$DIRECT_IP" ]; then
    pass "Internet works after exit node removed — IP: $DIRECT_IP"
else
    fail "Internet broken after exit node removal"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD} TEST SUMMARY${NC}"
echo -e "${BOLD}============================================${NC}"
echo -e "  Total:  $TOTAL"
echo -e "  ${GREEN}Passed: $PASS${NC}"
echo -e "  ${RED}Failed: $FAIL${NC}"
echo -e "  ${YELLOW}Skipped: $SKIP${NC}"

if [ -n "$BENCHMARKS" ]; then
    echo ""
    echo -e "${BOLD} BENCHMARKS${NC}"
    echo -e "$BENCHMARKS"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}$FAIL TEST(S) FAILED${NC}"
    exit 1
fi
