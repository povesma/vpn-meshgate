# 005-CUSTOM-ROUTES: Custom Address Routing via Company VPN - Technical Design

**Status**: Draft
**PRD**: [005-CUSTOM-ROUTES-prd.md](2026-04-05-005-CUSTOM-ROUTES-prd.md)
**Created**: 2026-04-05

## Overview

Add an `EXTRA_VPN_CIDRS` env var that routes arbitrary IP
addresses/CIDRs through the company L2TP tunnel, alongside
existing `COMPANY_CIDRS`. Phase 1 is static configuration via
`.env`; Phase 2 adds runtime bot commands; Phase 3 adds
DNS-based automatic routing.

## Current Architecture

Traffic from the Mac reaches the VPS via Tailscale exit node
mode (all traffic). Inside the gluetun shared network namespace,
routing decides where traffic goes:

```
Mac → Tailscale (exit node) → gluetun namespace
  ├─ COMPANY_CIDRS → eth0 → 172.29.0.20 (l2tp-vpn) → ppp0 → company
  └─ everything else → tun0 (WireGuard) → Mullvad → internet
```

**Routing is configured in two places**:

1. **`gluetun/init-routes.sh`** (route-init container, runs in
   gluetun namespace via `network_mode: service:gluetun`):
   - `ip route replace <CIDR> via 172.29.0.20 dev eth0` — sends
     company traffic to L2TP container over Docker bridge
   - `ip rule add to <CIDR> lookup main priority 100` — prevents
     WireGuard table 51820 from catching company traffic
   - `iptables -A OUTPUT/INPUT -o/-i eth0 -d/-s <CIDR> -j ACCEPT`
     — allows traffic through gluetun's firewall

2. **`l2tp/entrypoint.sh`** (l2tp-vpn container, own network
   namespace on bridge_vpn):
   - `ip route add <CIDR> dev ppp0` — routes company traffic into
     the L2TP tunnel
   - `iptables -t nat -A POSTROUTING -o ppp0 -j MASQUERADE` —
     NATs forwarded traffic (applied once, covers all CIDRs)
   - `iptables -t mangle ... -o/-i ppp0 -j TCPMSS
     --clamp-mss-to-pmtu` — MSS clamping (applied once, covers
     all CIDRs)
   - `cleanup_stale_state()` — removes stale routes on reconnect

**Tailscale `--advertise-routes`**: Currently includes
`COMPANY_CIDRS` but this is irrelevant for exit node mode (all
traffic already routes through the VPS). `EXTRA_VPN_CIDRS` does
NOT need to be added to `--advertise-routes` — doing so would
require Headscale approval on every change, for no benefit in
exit node mode.

## Proposed Design

### Phase 1: Static Custom Routes

#### Approach: Shared Loop Pattern

Both scripts already use the same `IFS=','` loop over
`COMPANY_CIDRS`. The simplest correct approach: combine both env
vars into a single variable at the top of each loop, then iterate
once. No new functions, no abstractions — just prepend/append.

#### Changes to `gluetun/init-routes.sh`

**Current** (lines 32-57):
```sh
if [ -z "${COMPANY_CIDRS}" ]; then
    log "COMPANY_CIDRS empty, nothing to route"
    exit 0
fi

log "Adding company routes via L2TP (${L2TP_IP})"
IFS=','
for cidr in ${COMPANY_CIDRS}; do
    ...
done
```

**Proposed**:
```sh
ALL_VPN_CIDRS="${COMPANY_CIDRS}${EXTRA_VPN_CIDRS:+,${EXTRA_VPN_CIDRS}}"

if [ -z "${ALL_VPN_CIDRS}" ]; then
    log "No CIDRs to route (COMPANY_CIDRS and EXTRA_VPN_CIDRS both empty)"
    exit 0
fi

log "Adding VPN routes via L2TP (${L2TP_IP})"
[ -n "${EXTRA_VPN_CIDRS}" ] && log "  extra CIDRs: ${EXTRA_VPN_CIDRS}"
IFS=','
for cidr in ${ALL_VPN_CIDRS}; do
    ...  # existing loop body unchanged
done
```

The `${EXTRA_VPN_CIDRS:+,${EXTRA_VPN_CIDRS}}` pattern appends a
comma + value only if EXTRA_VPN_CIDRS is non-empty, avoiding a
trailing comma when unset.

#### Changes to `l2tp/entrypoint.sh`

Same pattern in two functions:

**`setup_routing()`** (lines 199-207): merge CIDRs before the
routing loop.

**`cleanup_stale_state()`** (lines 114-120): merge CIDRs before
the cleanup loop so stale extra routes are also removed on
reconnect.

Both use the same merge: `ALL_VPN_CIDRS="${COMPANY_CIDRS}${EXTRA_VPN_CIDRS:+,${EXTRA_VPN_CIDRS}}"`.

#### Changes to `docker-compose.yml`

Add `EXTRA_VPN_CIDRS` env var to:
- `route-init` service (line 48)
- `l2tp-vpn` service (line 93)

No change to `tailscale` service — exit node mode makes
`--advertise-routes` irrelevant for extra CIDRs, and modifying
it would require Headscale route approval on every change.

#### Changes to `.env.example`

Add documented variable after `COMPANY_CIDRS`:
```
# Extra IPs/CIDRs to route through company VPN (comma-separated)
# Use for company services on public IPs not covered by COMPANY_CIDRS
EXTRA_VPN_CIDRS=
```

### Phase 2: Bot Route Management

**New bot commands** in `bot/bot.sh`:

- `route list` — shows `EXTRA_VPN_CIDRS` from env + any runtime
  routes from `/shared/extra-routes`
- `route add <CIDR>` — validates CIDR format, adds route in both
  namespaces (gluetun via `docker exec gluetun` + l2tp-vpn via
  `docker exec l2tp-vpn`), persists to `/shared/extra-routes`
- `route del <CIDR>` — removes route from both namespaces,
  removes from `/shared/extra-routes`

**Runtime persistence**: `/shared/extra-routes` file (on
`shared-config` volume) survives L2TP reconnects.
`l2tp/entrypoint.sh` reads this file in `setup_routing()` in
addition to env vars. Full stack redeploy recreates the volume,
so only `.env` routes persist across redeploys.

**Bot networking concern**: vpn-bot runs in gluetun namespace
(`network_mode: service:gluetun`) and has Docker socket mounted.
It can `docker exec l2tp-vpn` to manage routes in the L2TP
container. For gluetun namespace routes, it can execute
`ip route`/`iptables` directly (same namespace).

### Phase 3: DNS-Based Routing (Future Sketch)

`VPN_ROUTE_DOMAINS=company.example.com` env var. A periodic resolver
(cron in healthcheck or new sidecar) resolves all known
subdomains, diffs against current route table, and adds/removes
routes. dnsmasq `--ipset` or `--nftset` integration could
automate this at DNS resolution time. Detailed design deferred
to Phase 3 PRD.

## Verification Approach

| Requirement | Method | Scope | Expected Evidence |
|-------------|--------|-------|-------------------|
| FR-1: EXTRA_VPN_CIDRS parsed | `manual-run-user` | integration | route-init logs show extra CIDRs |
| FR-2: Routes applied in both containers | `manual-run-user` | integration | `ip route` in both containers shows 198.51.100.34 via ppp0/L2TP |
| Gluetun firewall allows extra CIDRs | `manual-run-user` | integration | `iptables -L` shows ACCEPT rules for extra CIDRs |
| End-to-end: Mac reaches extra CIDR via L2TP | `manual-run-user` | e2e | `traceroute 198.51.100.34` from Mac shows ppp0 path |
| Empty EXTRA_VPN_CIDRS is no-op | `observation` | — | No errors in logs when var is empty/unset |
| L2TP reconnect restores extra routes | `manual-run-user` | integration | After `docker restart l2tp-vpn`, routes reappear |

## Trade-offs

### Considered: Single merged env var vs separate loop

**Option A**: Merge into `ALL_VPN_CIDRS` at top, single loop
(recommended).
- Pro: No code duplication, existing loop body untouched
- Pro: One-line change per function
- Con: None

**Option B**: Separate loop for `EXTRA_VPN_CIDRS` after
`COMPANY_CIDRS` loop.
- Pro: Clearer separation in logs
- Con: Duplicates 15 lines of loop body in each script
- Con: Bug risk from diverging loop implementations

**Decision**: Option A. The merge pattern
`"${A}${B:+,${B}}"` is a standard POSIX shell idiom.

### Considered: Adding to --advertise-routes

**Rejected**. In exit node mode, all client traffic already
routes through the VPS. Adding extra CIDRs to `--advertise-routes`
would require Headscale `routes approve` on every change, adding
operational friction for zero benefit.

## Files to Create/Modify

**Modify**:
- `gluetun/init-routes.sh` — merge EXTRA_VPN_CIDRS before routing
  loop
- `l2tp/entrypoint.sh` — merge EXTRA_VPN_CIDRS in
  `setup_routing()` and `cleanup_stale_state()`
- `docker-compose.yml` — add EXTRA_VPN_CIDRS to route-init and
  l2tp-vpn services
- `.env.example` — document new variable

**No new files** for Phase 1.

## Rollback Plan

Remove `EXTRA_VPN_CIDRS` from `.env` and redeploy. The code
changes are backward-compatible — empty/unset `EXTRA_VPN_CIDRS`
is a no-op by design.

---

**Next Steps**:
1. Review and approve design
2. Run `/dev:tasks` for task breakdown
