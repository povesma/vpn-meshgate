# 009-NETBIRD-ROUTE-SYNC — PRD

**Status**: Draft
**Created**: 2026-05-19

## Context

Netbird-type VPN instances learn routes dynamically from their management
server and install them inside the netbird container (on the `wt0`
interface, in a policy routing table). Other containers behind the
Tailscale exit node have no visibility into these routes and send the
traffic out the host's default path (clearnet) instead of the netbird
tunnel.

### Current State

- A `type: netbird` instance installs routes for advertised destinations
  into a netbird-owned policy routing table on `wt0` — verified via
  `ip route show table <netbird-table>` inside the instance container,
  2026-05-19.
- The netbird container's policy rule excludes unmarked foreign traffic
  from that table — verified via `ip rule show` inside the container,
  2026-05-19.
- Host policy routing (`route-init`) installs only **static** CIDRs from
  `vpn-instances.yaml`; it has no knowledge of netbird's dynamic routes —
  verified via `ip rule show` on host plus repo grep for `route_cidrs`,
  2026-05-19.
- `dnsmasq` split-DNS for netbird-served domains resolves correctly via
  the netbird resolver, but the resolved address is not host-routed
  through the netbird container — verified via `nslookup` against the
  netbird resolver IP and host traceroute, 2026-05-19.

## Problem

**Who**: Tailscale clients of the exit node.
**What**: Traffic to netbird-routed destinations exits clearnet, not the
netbird tunnel.
**Why**: Corporate resources are unreachable or leak through clearnet.
**When**: Always, for any netbird-served domain/IP.

## Goals

**Primary**: Destinations advertised by netbird are reached through the
corresponding netbird instance, automatically and without per-destination
config edits.

**Secondary**:
- Survive netbird route changes (additions, removals, reconnects) without
  human intervention.
- Generic across all netbird-type VPN instances.

## User Stories

**Epic**: As an operator, I want netbird-advertised routes to apply to
all exit-node traffic, so corporate resources behave the same as for
direct netbird peers.

1. **As a** Tailscale client
   **I want** packets to a netbird-routed IP to traverse the matching
   netbird tunnel
   **So that** corporate resources resolve and connect reliably.

   **Acceptance Criteria**:
   - [ ] Traceroute from a Tailscale client to a netbird-routed
     destination shows the netbird peer as the next hop after the exit
     node.
   - [ ] Adding a resource on the netbird side becomes reachable from
     Tailscale clients within the configured sync interval, with no
     repo or VPS file edits.
   - [ ] Removing a resource on the netbird side makes it unreachable
     within the configured sync interval (no stale routes).
   - [ ] Holds across netbird container restart and netbird reconnect.

2. **As an** operator
   **I want** this to work for every netbird-type instance generically
   **So that** I do not maintain per-instance routing config.

   **Acceptance Criteria**:
   - [ ] Declaring a new `type: netbird` instance in `vpn-instances.yaml`
     auto-enables route sync; no other config required.

## Requirements

### Functional
1. **FR-1** (High): Discover the destinations routed by each netbird
   instance at runtime.
2. **FR-2** (High): Reflect that set as host-level routing so traffic
   from other containers reaches those destinations via the matching
   netbird instance.
3. **FR-3** (High): Reconcile periodically; converge after route
   add/remove and after netbird restart.
4. **FR-4** (Medium): Apply to all `type: netbird` instances generically.
5. **FR-5** (Medium): Coexist with static `route_cidrs` without conflict.

### Non-Functional
1. **NFR-1** Reliability: No stale routes after netbird removal; no route
   loss after restart.
2. **NFR-2** Observability: Sync actions and current routed set
   inspectable via container logs.
3. **NFR-3** Security: Must not widen routing for destinations not
   advertised by netbird.
4. **NFR-4** Performance: Reconcile interval ≤ 60 s; cost negligible vs.
   existing `route-init`.

### Constraints
- Integrates with the multi-instance architecture (006) and the existing
  `route-init` / `route_cidrs` pipeline.
- No changes to netbird container images.
- Secrets policy: no credentials in generated configs or scripts.

## Out of Scope

- Non-netbird VPN types — already covered by static `route_cidrs` or
  tunnel-default routing.
- Domain-based routing changes — `dnsmasq` split-DNS already works once
  IP routing is fixed.
- Netbird ACL / peer management.

## Success Metrics

1. `traceroute` from a Tailscale client to any netbird-advertised IP
   shows the netbird peer in the path — 100% of advertised destinations.
2. Convergence after netbird route change ≤ 60 s.
3. Zero manual VPS edits when corporate resources change.

## References

- `tasks/006-MULTI-INSTANCE-VPN/` — multi-instance architecture extended
  here.
- `tasks/007-DOMAIN-ROUTING/` — domain-routing pipeline complemented
  here.
- NetBird docs: routing peers, IP forwarding requirements
  (`/netbirdio/docs`).

---

**Next**: `/dev:tech-design` — choose detection mechanism (CLI vs route
table), component placement (extend `route-init` vs sidecar), and the
host-forwarding implementation.
