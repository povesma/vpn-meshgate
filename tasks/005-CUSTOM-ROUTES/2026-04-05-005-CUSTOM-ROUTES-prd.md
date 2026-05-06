# 005-CUSTOM-ROUTES: Custom Address Routing via Company VPN - PRD

**Status**: Complete
**Created**: 2026-04-05
**Author**: Claude (via dev workflow analysis)

---

## Context

Currently, only private corporate subnets defined in `COMPANY_CIDRS`
(e.g. `10.11.0.0/16`) are routed through the L2TP/IPsec company VPN.
Public IP addresses that belong to company services hosted outside the
corporate network (e.g. `company.example.com` subdomains resolving to
`198.51.100.34`) are routed through Mullvad like regular internet
traffic. This means company web services that require VPN access are
unreachable.

### Current State

- `COMPANY_CIDRS` env var drives routing in two scripts:
  - `gluetun/init-routes.sh` (route-init sidecar): routes CIDRs via
    L2TP container (172.29.0.20) over Docker bridge, adds iptables
    ACCEPT rules and policy routing (`ip rule ... lookup main`)
  - `l2tp/entrypoint.sh`: routes CIDRs over `ppp0`, adds MASQUERADE
    and MSS clamping
- Both scripts iterate `COMPANY_CIDRS` with identical `IFS=','` loop
  pattern
- Bot (`bot/bot.sh`) has no route management commands

## Problem Statement

**Who**: VPN user (developer)
**What**: Cannot reach company-hosted public IP services through the
VPN tunnel
**Why**: Only RFC 1918 corporate subnets are routed via L2TP; public
IPs used by company services go through Mullvad which has no access
**When**: When accessing company web services, CI/CD, or other
resources hosted on public IPs that require company VPN connectivity

## Goals

### Primary Goal
Route arbitrary user-defined IP addresses and CIDRs through the
company L2TP VPN tunnel alongside the existing corporate subnets.

### Secondary Goals
- Keep `COMPANY_CIDRS` unchanged for clean separation of intent
- Enable runtime route management via bot commands (Phase 2)
- Support DNS-based routing for company domains (Phase 3)

## User Stories

### Phase 1: Static Custom Routes (MVP)

1. **As a** VPN user
   **I want** to define extra IP addresses/CIDRs in `.env` that route
   through the company VPN
   **So that** I can reach company services on public IPs without
   changing `COMPANY_CIDRS`

   **Acceptance Criteria**:
   - [ ] New `EXTRA_VPN_CIDRS` env var accepts comma-separated
     IPs/CIDRs (e.g. `198.51.100.34/32,203.0.113.0/24`)
   - [ ] `route-init` routes `EXTRA_VPN_CIDRS` through L2TP container
     with same iptables/policy rules as `COMPANY_CIDRS`
   - [ ] `l2tp-vpn` routes `EXTRA_VPN_CIDRS` over `ppp0` with same
     MASQUERADE as `COMPANY_CIDRS`
   - [ ] Traffic to `198.51.100.34` from Mac via Tailscale exit node
     goes through L2TP tunnel (verified with traceroute)
   - [ ] Empty `EXTRA_VPN_CIDRS` (or unset) is a no-op — no errors,
     no behaviour change
   - [ ] `.env.example` documents the new variable
   - [ ] Existing `COMPANY_CIDRS` routing is unaffected

### Phase 2: Bot Route Management

2. **As a** VPN user
   **I want** to add and remove custom routes at runtime via ntfy bot
   commands
   **So that** I don't need to redeploy the stack for route changes

   **Acceptance Criteria**:
   - [ ] `route list` — shows current extra routes
   - [ ] `route add <CIDR>` — adds a route through company VPN at
     runtime (both route-init namespace and L2TP container)
   - [ ] `route del <CIDR>` — removes a custom route
   - [ ] Runtime routes survive L2TP reconnection (persisted to a
     shared file)
   - [ ] Runtime routes do NOT survive full stack redeploy (`.env`
     is the source of truth for persistent routes)

### Phase 3: DNS-Based Routing (Future)

3. **As a** VPN user
   **I want** all IPs resolved from `company.example.com` subdomains to
   be automatically routed through the company VPN
   **So that** I don't need to manually track and add IPs when company
   DNS records change

   **Acceptance Criteria**:
   - [ ] New env var (e.g. `VPN_ROUTE_DOMAINS`) accepts
     comma-separated domain suffixes
   - [ ] DNS responses for matching domains trigger automatic route
     addition for resolved IPs
   - [ ] Routes are updated when DNS records change (TTL-aware)
   - [ ] Stale routes are cleaned up when IPs change

## Requirements

### Functional Requirements

1. **FR-1**: `EXTRA_VPN_CIDRS` env var parsed identically to
   `COMPANY_CIDRS` (comma-separated, whitespace-tolerant)
   - **Priority**: High
   - **Phase**: 1

2. **FR-2**: Routes applied in both `init-routes.sh` and
   `l2tp/entrypoint.sh` with same treatment (ip route, ip rule,
   iptables ACCEPT, MASQUERADE, MSS clamping)
   - **Priority**: High
   - **Phase**: 1

3. **FR-3**: Bot commands `route list`, `route add`, `route del`
   - **Priority**: Medium
   - **Phase**: 2

4. **FR-4**: DNS-based route resolution for configured domains
   - **Priority**: Low
   - **Phase**: 3

### Non-Functional Requirements

1. **NFR-1**: Zero impact on startup time — extra CIDRs processed in
   same loop, no additional waits
2. **NFR-2**: No new containers or images for Phase 1
3. **NFR-3**: Route cleanup on L2TP reconnect must include extra CIDRs

### Technical Constraints

- Must work within existing shared network namespace architecture
- `route-init` and `l2tp-vpn` are separate containers on `bridge_vpn`
  — both need the env var
- Bot commands (Phase 2) need `docker exec` into gluetun namespace
  to modify routes at runtime
- DNS-based routing (Phase 3) likely requires a custom DNS
  interception layer or dnsmasq post-hook

## Out of Scope

- Changing how `COMPANY_CIDRS` works
- Per-route VPN selection (all custom routes go through L2TP)
- IPv6 support
- Automatic discovery of company IPs (beyond Phase 3 DNS)

## Success Metrics

1. **Phase 1**: `curl` to `198.51.100.34` from Mac via Tailscale
   exit node succeeds through L2TP tunnel
2. **Phase 2**: Route added via bot is immediately usable without
   redeploy
3. **Phase 3**: All `company.example.com` subdomains reachable without
   manual IP management

## References

### From Codebase
- `gluetun/init-routes.sh` — route-init sidecar, lines 32-57
  (COMPANY_CIDRS routing loop)
- `l2tp/entrypoint.sh` — L2TP container, lines 116-119
  (cleanup_stale_state), lines 199-207 (setup_routing)
- `docker-compose.yml` — env var definitions for route-init and
  l2tp-vpn services
- `.env.example` — env var documentation
- `bot/bot.sh` — bot command handlers (Phase 2 integration point)

---

**Next Steps**:
1. Review and refine this PRD
2. Run `/dev:tech-design` to create technical design
3. Run `/dev:tasks` to break down into tasks
