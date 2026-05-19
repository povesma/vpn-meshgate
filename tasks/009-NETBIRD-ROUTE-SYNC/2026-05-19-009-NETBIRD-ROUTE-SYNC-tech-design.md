# 009-NETBIRD-ROUTE-SYNC — Tech Design

**Status**: Draft
**PRD**: `2026-05-19-009-NETBIRD-ROUTE-SYNC-prd.md`
**Created**: 2026-05-19

## Overview

Mirror the set of destinations a netbird-type VPN instance routes via
its `wt0` interface into the host's policy routing so other containers
(Tailscale exit, dnsmasq, other VPN instances) reach those destinations
through the netbird container — converging on netbird's dynamic route
set the same way `route_domains` converges on DNS answers today.

## Current Architecture (verified)

- **Route pipeline** lives in `gluetun/init-routes.sh` (route-init
  container). Two phases: static `cidrs` (one-shot) and `route_domains`
  (TTL-driven loop). Verified: `gluetun/init-routes.sh:55-86, 91-197`,
  2026-05-19.
- **Per-destination install pattern**: `ip route replace <dest> via
  <instance-ip> dev eth0` + `ip rule add to <dest> lookup main priority
  100` + iptables ACCEPT in custom `VPN-INSTANCE-OUT` / `VPN-INSTANCE-IN`
  chains. Verified: `gluetun/init-routes.sh:73-84, 156-163`, 2026-05-19.
- **Netbird instance container** writes its bridge IP to
  `/shared/<instance>-dns-ip`, runs masquerade on `wt0`, enables
  `ip_forward`, and pins the management server route via `eth0`.
  Verified: `netbird/entrypoint.sh:63-101, 121-122`, 2026-05-19.
- **Netbird policy rule** `not from all fwmark <netbird-mark> lookup
  <netbird-table>` — the `not` qualifier means **unmarked traffic
  IS routed via the netbird table**; marked traffic is excluded. The
  netbird container therefore already accepts and forwards foreign
  transit packets. Verified: `ip route get <dest> from <bridge-src>
  iif eth0` returned `dev wt0 table <netbird-table>`, 2026-05-19.
- **Generator**: `generate-vpn.py` emits `vpn-instances.json` consumed by
  route-init; `type: netbird` is a recognised type with fields
  `credentials.setup_key`, `management_url`, `cidrs`. Verified:
  `generate-vpn.py:20, 219-246, 261-274`, 2026-05-19.
- **Shared volume** `shared-config:/shared` is mounted in both
  route-init and instance containers — natural channel for
  instance→route-init data. Verified: `generate-vpn.py:162, 181, 209,
  237`, 2026-05-19.

## Proposed Design

### Components

**Modified — `netbird/entrypoint.sh`** (per-instance, runs inside
netbird container):

- Add a background loop that periodically writes the current set of
  destinations netbird routes via `wt0` to
  `/shared/<instance>-netbird-routes`. File format: one CIDR per line,
  sorted, atomic replace (write tmp + rename). Empty file is valid
  (means no routes).
- Apply transit-enable rule(s) so traffic *not* originated inside the
  container (i.e. forwarded from the bridge) can use netbird's
  installed routes on `wt0`. Mechanism is left to implementation
  (see "Open Mechanism Decisions" below); the **contract** is: a
  packet entering the netbird container with destination ∈ exported
  set must be forwarded out `wt0` and masqueraded.

**Modified — `gluetun/init-routes.sh`** (single route-init):

- Add a third phase: `update_netbird_routes`. For each `type: netbird`
  instance in `vpn-instances.json`, read
  `/shared/<instance>-netbird-routes`, diff against previous state,
  and install/remove host routes using the **same primitives** as the
  domain-routing loop (`ip route replace`, `ip rule add to ... lookup
  main`, iptables ACCEPT in `VPN-INSTANCE-OUT/IN`).
- Loop interval: fixed (no TTL signal available); ≤ 60 s per PRD
  NFR-4. State stored under the same `DOMAIN_STATE_DIR` pattern.
- Coexists with the existing domain-routing loop. The two loops touch
  disjoint state files; both can run in the same `while true` if a
  unified poller is simpler than two threads in shell.

**Modified — `generate-vpn.py`**:

- Emit a `netbird_route_sync: true` marker (or equivalent) for
  `type: netbird` instances in `vpn-instances.json` so route-init
  treats it as opt-in by type, not by per-instance config.
  (Alternative: route-init keys off `type == "netbird"` directly,
  no generator change.)

### Data Contract — shared file

```
/shared/<instance>-netbird-routes
```

- Producer: instance container (netbird entrypoint loop).
- Consumer: route-init.
- Format: text, one CIDR (`a.b.c.d/p`) per line, UTF-8, LF, sorted.
- Empty file = "instance is up, currently exports nothing".
- Absent file = "instance not ready / route sync disabled".
- Write atomicity: produce to `*.tmp`, `rename(2)`.

This mirrors the existing `/shared/<instance>-dns-ip` convention
(`netbird/entrypoint.sh:121-122`).

### Sequence

1. Netbird container starts → connects → enables transit-rule(s) →
   begins exporting routes to `/shared/<instance>-netbird-routes`.
2. Route-init poll cycle reads the file → diffs against
   `${DOMAIN_STATE_DIR}/<instance>-netbird/state` → applies adds and
   removes via the existing per-destination primitives.
3. When the netbird container restarts: transit-rule(s) re-applied;
   file is rewritten; route-init converges on next cycle.
4. When netbird removes a route: file shrinks; route-init removes
   matching host routes on next cycle.

### Return Path

The netbird container receives forwarded packets with the original
source (e.g. a Tailscale client's tailnet IP `100.64.0.x`). After
`MASQUERADE -o wt0` rewrites the source to wt0's IP and the packet
traverses the tunnel, the reply arrives back on wt0 with
`dst=<wt0-ip>`, reverse-NAT restores `dst=<tailnet-ip>` — but the
netbird container has no route for the tailnet CIDR
(`100.64.0.0/10`), so the reply is dropped.

**Resolution**: gluetun's route-init applies `MASQUERADE` to traffic
leaving gluetun toward each netbird container's bridge IP. The
netbird container then sees `src=<gluetun-bridge-ip>` (which it can
route back via the bridge), keeping the round-trip contained between
gluetun and the netbird peer.

Rejected alternative: install a `100.64.0.0/10` route inside the
netbird container pointing back at gluetun. Cleaner topologically
but requires netbird-side changes and assumes the tailnet CIDR is
stable; the gluetun-side MASQUERADE is contained and doesn't depend
on tailnet specifics.

### Reliability / Failure Handling

- **Stale file after netbird crash**: route-init must verify the netbird
  container is up before treating the file as authoritative. Heuristic:
  file mtime within `2 × poll_interval`, OR `docker exec ip link show
  wt0` succeeds (not available from route-init — prefer mtime). If
  stale: leave routes untouched (do not flush) until container
  re-establishes; on re-establish the diff reconverges.
- **Race with domain-routing loop**: both loops modify the same custom
  iptables chains and the same `priority 100` `ip rule` namespace. Each
  destination must be owned by exactly one source (CIDR vs domain vs
  netbird-route). Conflict detection: log + skip when a destination
  already managed by another source.
- **Netbird-routed CIDR overlapping a static `cidrs` entry**: static
  wins (it's already installed at startup); netbird-route sync skips
  overlaps and logs.

### Verification Approach

| Requirement | Method | Scope | Expected Evidence |
|---|---|---|---|
| FR-1 discover routes | `manual-run-claude` | unit | producer writes parsable CIDR file on demand |
| FR-2 host-level install | `auto-test` | integration | `ip route get <dest>` inside Tailscale-client container shows `dev` matching netbird instance bridge IP path |
| FR-3 reconciliation | `manual-run-claude` | integration | adding/removing route on netbird side reflects in host `ip route` within ≤ poll interval |
| FR-4 generic across instances | `code-only` | — | second netbird instance auto-sync without code changes |
| FR-5 coexist with route_cidrs | `auto-test` | integration | static CIDR present at startup; netbird-route add does not perturb it |
| NFR-1 no stale routes | `manual-run-claude` | integration | route removed from netbird disappears from host within ≤ poll interval |
| NFR-3 no over-routing | `code-only` | — | only IPs present in producer file are installed |

Methods per `/dev:test-plan` canonical definitions.

## Mechanism Decisions

1. **Route discovery source** (producer side): **`netbird networks ls`,
   parsed line-based with `awk`**. Resolved 2026-05-19 from prototype
   (subtasks 1.1–1.3) and the NetBird docs.
   - Why: netbird's documented CLI; returns
     `Network → Resolved IPs` mapping directly; survives the daemon
     down/up race that flushes table 7120 routing rules but keeps the
     daemon cache (per docs section "Verify NetBird Client Cache
     Behavior").
   - Rejected: `ip route show table 7120` — table number is documented
     (`0x1BD0`) but the table can be transiently empty while netbird
     still considers the network selected.
   - Rejected: `netbird status --json` — `networks` field is the
     *advertised domains* without IPs; would require duplicate
     resolution.
   - Parser contract: for each block whose `Status:` is `Selected`,
     emit the IPv4 addresses listed under `Resolved IPs:`, one per
     line. Skip blocks with `Resolved IPs: -`.

2. **Transit enablement for foreign packets**: **Not required.**
   Resolved 2026-05-19 from prototype (subtask 1.4 + post-removal
   probe). Netbird's own policy rule
   `not from all fwmark <netbird-mark> lookup <netbird-table>` already
   routes unmarked transit traffic via `wt0`; FORWARD policy is
   ACCEPT; `MASQUERADE -o wt0` is installed by `netbird/entrypoint.sh`
   on every start. The container needs **no additional rules** to
   accept foreign transit. The original symptom (clearnet leak) was
   purely a missing **host-side** route to `<netbird-container-ip>`.

## Trade-offs (architecture-level)

**Option A — Static `route_cidrs` per netbird instance**: zero new
code; immediate. Rejected per PRD NFR-1 (manual upkeep, stale on
netbird changes).

**Option B (chosen) — File-based producer/consumer over `shared/`**:
follows the existing dns-ip convention; reuses the proven
route-install primitives; no new container; survives restarts via
docker volume.

**Option C — Sidecar container per netbird instance**: cleaner
isolation. Rejected: one more service per instance, no functional
benefit over Option B given the shared volume already exists.

**Option D — DNAT-on-host into netbird container**: heavier iptables
footprint, harder to observe, and the netbird container already does
masquerade on `wt0`. Rejected.

## Files to Create / Modify

**Modify**:

- `netbird/entrypoint.sh` — add transit-enable step(s) and the route
  export loop.
- `gluetun/init-routes.sh` — add the netbird-route reconciliation
  phase, reusing the per-destination install primitives.
- `generate-vpn.py` — minor, only if route-init keys off a generated
  flag rather than `type == "netbird"`.

**Create**: none. All new code lives in existing scripts.

## Security Considerations

- Producer must only export destinations actually present on `wt0`;
  consumer must not install routes for arbitrary IPs (PRD NFR-3).
- Shared volume is not a trust boundary — both containers are
  controlled by the same compose stack.
- No credentials cross the producer/consumer file.

## Performance Considerations

- Poll interval ≤ 60 s; per-cycle work bounded by number of routes
  (tens, not thousands in practice).
- File-based diff is O(n log n) on small n; negligible vs. existing
  domain-routing loop.

## Rollback

- Single env flag in route-init (e.g. `NETBIRD_ROUTE_SYNC=0`) skips
  the new phase; container restart restores prior behaviour.
- Transit-enable rules in `netbird/entrypoint.sh` are added with
  `iptables -C ... || -A`; cleanup on container stop matches the
  existing `cleanup_iptables` pattern.

## References

- `gluetun/init-routes.sh:91-197` — domain-routing loop, the
  structural twin of the new phase.
- `netbird/entrypoint.sh:103-123` — DNS proxy pattern, the
  structural twin of the producer.
- `tasks/006-MULTI-INSTANCE-VPN/` — multi-instance architecture.
- `tasks/007-DOMAIN-ROUTING/` — domain-routing pipeline.
- NetBird docs (`/netbirdio/docs`): "How Routing Peers Work",
  "Site-to-VPN" — IP forwarding and gateway-host requirements.

---

**Next**: `/dev:tasks` to break into subtasks.
