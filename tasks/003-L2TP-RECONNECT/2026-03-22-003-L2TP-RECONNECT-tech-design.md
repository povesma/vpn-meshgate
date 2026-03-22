# 003-L2TP-RECONNECT: L2TP Auto-Reconnect — Technical Design

**Status**: Complete
**PRD**: [2026-03-22-003-L2TP-RECONNECT-prd.md](2026-03-22-003-L2TP-RECONNECT-prd.md)
**Created**: 2026-03-22

---

## Overview

Replace `sleep infinity` at the end of `l2tp/entrypoint.sh` with a monitoring
loop that detects ppp0 loss and re-runs the connection sequence. Add ntfy
notifications on disconnect/recovery. All changes are within the single
entrypoint script.

---

## Current Architecture

`l2tp/entrypoint.sh` has a linear structure:

```
configure_ipsec()      # Write /etc/ipsec.conf, /etc/ipsec.secrets
configure_xl2tpd()     # Write /etc/xl2tpd/xl2tpd.conf, PPP options
configure_ppp_scripts() # Write /etc/ppp/ip-up (DNS extraction)
start_ipsec()          # ipsec start → ipsec up L2TP-PSK
start_xl2tpd()         # xl2tpd -D &
connect_l2tp()         # echo "c company" > /var/run/xl2tpd/l2tp-control
wait_for_ppp0()        # Poll ip -4 addr show ppp0 (60× 1s)
extract_dns()          # Wait for /shared/company-dns-ip from ip-up script
add_routes()           # ip route add ${COMPANY_CIDRS} dev ppp0
add_masquerade()       # iptables -t nat -A POSTROUTING -o ppp0 -j MASQUERADE
sleep infinity         # ← THE PROBLEM
```

**Key observations**:
- Configuration (IPsec, xl2tpd, PPP) is idempotent — safe to re-run
- `ipsec start` starts the daemon; subsequent calls fail with "already running"
- `xl2tpd -D &` runs in foreground mode as a background process; needs kill/restart
- Routes and iptables rules accumulate if not cleaned before re-adding
- The `ip-up` PPP script writes DNS to `/shared/company-dns-ip` — works on
  every PPP link establishment, no changes needed

**Network context**:
- L2TP container is on `bridge_vpn` at `172.29.0.20`
- ntfy is reachable at `172.29.0.10:80` (gluetun's bridge IP) when healthy
- curl is already installed in the container image

---

## Proposed Design

### Entrypoint Restructure

Refactor the linear script into two phases:

**Phase 1 — Configuration (runs once)**:
- Write IPsec/xl2tpd/PPP config files (unchanged from current)
- These are static for the container's lifetime

**Phase 2 — Connect + Monitor (loops on failure)**:
```
while true:
    cleanup_stale_state()
    start_ipsec_daemon()      # ipsec start (if not running)
    establish_ipsec_sa()      # ipsec up L2TP-PSK
    start_xl2tpd()            # xl2tpd -D &
    connect_l2tp()            # echo "c company" > l2tp-control
    wait_for_ppp0()           # poll for IP on ppp0

    if ppp0 failed:
        notify("VPN connect failed")
        backoff_sleep()
        continue

    setup_routing()           # routes + masquerade
    notify("VPN connected")
    monitor_ppp0()            # blocks until ppp0 drops
    notify("VPN disconnected")
    reset_backoff()           # connection was up, so reset
```

### Cleanup Function

Before each reconnection attempt, clean up stale state:

```sh
cleanup_stale_state() {
    # Kill xl2tpd if running (it doesn't recover gracefully)
    killall xl2tpd 2>/dev/null
    sleep 1

    # Tear down stale IPsec SA (ipsec daemon stays running)
    ipsec down L2TP-PSK 2>/dev/null

    # Remove stale routes (ignore errors if already gone)
    for cidr in ${COMPANY_CIDRS}; do
        ip route del "${cidr}" dev ppp0 2>/dev/null
    done

    # Remove stale masquerade rule
    iptables -t nat -D POSTROUTING -o ppp0 -j MASQUERADE 2>/dev/null

    # Recreate xl2tpd control socket
    rm -f /var/run/xl2tpd/l2tp-control
    mkdir -p /var/run/xl2tpd
    touch /var/run/xl2tpd/l2tp-control
}
```

### Monitor Function

Replaces `sleep infinity`:

```sh
monitor_ppp0() {
    while ip link show ppp0 >/dev/null 2>&1; do
        sleep 10
    done
    # ppp0 gone — return to reconnection loop
}
```

### Backoff Strategy

Simple counter-based exponential backoff:

```sh
BACKOFF_STEP=0
BACKOFF_DELAYS="15 30 60 120 300"

backoff_sleep() {
    delay=$(echo "${BACKOFF_DELAYS}" | cut -d' ' -f$((BACKOFF_STEP + 1)))
    [ -z "${delay}" ] && delay=300  # max
    log "Retrying in ${delay}s (attempt $((BACKOFF_STEP + 1)))"
    sleep "${delay}"
    BACKOFF_STEP=$((BACKOFF_STEP + 1))
}

reset_backoff() {
    BACKOFF_STEP=0
}
```

Failure notification is sent once after 3 consecutive failures (not per
attempt) to avoid notification spam:

```sh
CONSECUTIVE_FAILURES=0

# After connect failure:
CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
if [ "${CONSECUTIVE_FAILURES}" -eq 3 ]; then
    notify "Company VPN: reconnection failing after ${CONSECUTIVE_FAILURES} attempts"
fi

# After successful connect:
CONSECUTIVE_FAILURES=0
```

### ntfy Notification

Best-effort notification via the bridge network:

```sh
NTFY_URL="http://172.29.0.10:80"
NTFY_TOPIC="${NTFY_TOPIC:-vpn-alerts}"

notify() {
    local title="$1" msg="$2" priority="${3:-high}"
    curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -d "${msg}" 2>/dev/null || log "WARNING: ntfy unreachable"
}
```

This mirrors the pattern used in `bot/bot.sh:reply()` and
`switcher/switcher.sh:ntfy_reply()`.

### Downtime Tracking

Record disconnect timestamp, report duration on recovery:

```sh
DISCONNECT_TS=""

# On disconnect:
DISCONNECT_TS=$(date +%s)
notify "Company VPN Down" "L2TP tunnel lost. Reconnecting..."

# On recovery:
if [ -n "${DISCONNECT_TS}" ]; then
    DOWNTIME=$(( $(date +%s) - DISCONNECT_TS ))
    notify "Company VPN Up" "L2TP reconnected. Downtime: ${DOWNTIME}s. IP: ${PPP_IP}"
    DISCONNECT_TS=""
fi
```

---

## Sequence Diagram

### Normal reconnection (peer disconnect):
```
ppp0 drops (peer sends LCP TermReq "Link inactive")
  │
  ├─ monitor_ppp0() returns
  ├─ notify → ntfy: "Company VPN Down — L2TP tunnel lost. Reconnecting..."
  ├─ cleanup_stale_state()  [kill xl2tpd, ipsec down, remove routes]
  ├─ ipsec up L2TP-PSK
  ├─ xl2tpd -D &
  ├─ echo "c company" > l2tp-control
  ├─ wait_for_ppp0() → success (ppp0 gets IP within 30s)
  ├─ setup_routing() [routes + masquerade]
  ├─ notify → ntfy: "Company VPN Up — Reconnected. Downtime: 25s"
  └─ monitor_ppp0() → blocks again
```

### Persistent failure (peer unreachable):
```
ppp0 drops
  ├─ notify "Down"
  ├─ cleanup → reconnect → wait_for_ppp0() → TIMEOUT (60s)
  ├─ backoff_sleep(15s)
  ├─ cleanup → reconnect → wait_for_ppp0() → TIMEOUT
  ├─ backoff_sleep(30s)
  ├─ cleanup → reconnect → wait_for_ppp0() → TIMEOUT
  ├─ notify "Reconnection failing after 3 attempts"
  ├─ backoff_sleep(60s)
  ├─ ... continues with 120s, 300s max ...
  │
  │ (peer comes back)
  ├─ cleanup → reconnect → wait_for_ppp0() → success
  ├─ reset_backoff()
  └─ notify "Up — Downtime: 487s"
```

---

## Failure Modes

| Failure | Behaviour |
|---------|-----------|
| Peer sends LCP TermReq | ppp0 drops → cleanup → reconnect |
| IPsec SA fails | ipsec up returns non-zero → backoff → retry |
| xl2tpd connect fails | ppp0 never appears → 60s timeout → backoff → retry |
| ntfy unreachable | curl fails silently, reconnection continues |
| DNS not received from peer | Warning logged, /shared/company-dns-ip cleared |
| Route already exists | `ip route add` ignores with "(route exists)" log |
| ipsec daemon already running | `ipsec start` skipped (check first) |

---

## Files to Modify

- **`l2tp/entrypoint.sh`** — restructure into configure + connect/monitor loop,
  add cleanup, backoff, ntfy notification, downtime tracking

## Files Unchanged

- `l2tp/Dockerfile` — curl already installed, no new dependencies
- `docker-compose.yml` — NTFY_TOPIC already passed to the container
  environment? **No — needs to be added.** L2TP container currently has no
  NTFY_TOPIC env var. Add `NTFY_TOPIC=${NTFY_TOPIC:-vpn-alerts}` to
  l2tp-vpn environment in docker-compose.yml.
- `healthcheck/check.sh` — continues to work alongside; its ping-based
  monitoring is complementary (detects from gluetun's perspective)

---

## Rejected Alternatives

### 1. Docker healthcheck + restart policy

Use Docker's `restart: on-failure` or a custom healthcheck that exits
the container when ppp0 drops, relying on Docker to restart it.

**Rejected because**: Container restart re-runs the full entrypoint including
IPsec/xl2tpd config generation. It's slower (~30s vs ~15s for in-process
reconnect) and loses any runtime state. The current `restart: unless-stopped`
doesn't restart on unhealthy status anyway.

### 2. Separate watchdog sidecar

A monitoring container that watches ppp0 and restarts l2tp-vpn via Docker
socket, similar to mullvad-switcher.

**Rejected because**: Adds complexity for a problem solvable within the
entrypoint. The L2TP container doesn't have the namespace-sharing problem
that required the mullvad-switcher sidecar — it has its own network stack
on bridge_vpn.

### 3. PPP ip-down script triggers reconnect

Use pppd's `ip-down` script to signal the entrypoint to reconnect.

**Rejected because**: The ip-down script runs in pppd's context and exits
quickly. Signaling the entrypoint (e.g., via a file or signal) adds
complexity. Polling ppp0 every 10s is simpler and equally effective.

---

**Next Steps**:
1. Review and approve design
2. Run `/dev:tasks` for task breakdown
