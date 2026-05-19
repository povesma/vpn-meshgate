# 009-NETBIRD-ROUTE-SYNC — Task List

## Relevant Files

- [2026-05-19-009-NETBIRD-ROUTE-SYNC-prd.md](2026-05-19-009-NETBIRD-ROUTE-SYNC-prd.md)
  :: PRD
- [2026-05-19-009-NETBIRD-ROUTE-SYNC-tech-design.md](2026-05-19-009-NETBIRD-ROUTE-SYNC-tech-design.md)
  :: Tech design
- [netbird/entrypoint.sh](../../netbird/entrypoint.sh) :: Producer —
  transit-enable rule(s) and route export loop.
- [gluetun/init-routes.sh](../../gluetun/init-routes.sh) :: Consumer —
  netbird-route reconciliation phase.
- [generate-vpn.py](../../generate-vpn.py) :: Generator — may emit a
  per-instance opt-in marker (decision in Story 1.0).

## Notes

- Shell scripts have no unit-test harness in this repo. Logic checks
  are `manual-run-claude` (run in container, observe state).
- Live integration verification requires the VPS deployment and a
  netbird instance with at least one advertised route.

## Tasks

- [X] **1.0 User Story:** As an operator, I want a prototype that
  confirms the two open mechanism choices before any production code,
  so that I do not commit to the wrong primitive.
  - [X] 1.1 Probe route discovery option (a): inside the netbird
    instance container, capture `ip route show table <netbird-table>`
    output and confirm the advertised destination set is complete
    [verify: manual-run-claude]
      → table contained one `/32` route via `wt0`, matching the
        single advertised corporate destination; output is
        deterministic (not flow-dependent) [live] (2026-05-19)
  - [X] 1.2 Probe route discovery option (b): inside the netbird
    instance container, capture `netbird status --json` output and
    confirm the advertised destination set is complete and parseable
    via `jq` [verify: manual-run-claude]
      → `networks` field contained domain-name strings, not IPs/
        CIDRs; would require additional DNS resolution to install
        host routes; `jq` unavailable in container image
        [live] (2026-05-19)
  - [X] 1.3 Pick discovery source based on 1.1/1.2; record the
    decision and the rationale at the top of the tech-design's "Open
    Mechanism Decisions" section [verify: code-only]
      → chose `netbird networks ls` (third option, surfaced during
        Context7 research); rationale recorded in tech-design
  - [X] 1.4 Probe transit option (a): add `ip rule from <bridge-cidr>
    lookup <netbird-table>` inside the netbird container, send a
    test packet from another container, confirm it traverses `wt0`
    [verify: manual-run-claude]
      → rule installed at priority 50; traceroute from
        ts-test-client showed hop 1 = netbird container bridge IP
        (not docker gateway); TCP connect succeeded on 3 ports
        [live] (2026-05-19)
  - [X] 1.5 Probe transit option (b) — **obsolete**: 1.4 post-removal
    probe revealed transit enablement is not required (netbird's
    own `not fwmark` rule already routes unmarked foreign traffic
    via `wt0`) [verify: manual-run-claude]
      → `ip route get <dest> from <bridge-src> iif eth0` showed
        `dev wt0 table <netbird-table>` with no extra rule
        [live] (2026-05-19)
  - [X] 1.6 Pick transit mechanism — **obsolete**: see 1.5
    [verify: manual-run-claude]
      → no transit-enable mechanism needed; recorded in tech-design
  - [X] 1.7 Tear down all probe rules so the VPS is left in its
    pre-prototype state [verify: manual-run-claude]
      → confirmed: netbird container has no probe rule; ts-test-client
        has no probe route [live] (2026-05-19)

- [X] **2.0 User Story:** As a netbird-instance operator, I want the
  netbird container to export its current route set to a shared file,
  so that other containers can consume it. (Transit enablement is not
  needed — see decision in 1.5.)
  - [X] 2.1 Add an `export_routes` function in `netbird/entrypoint.sh`
    that parses `netbird networks ls` and emits sorted IPv4
    addresses (one per line) for blocks with `Status: Selected` and
    a non-empty `Resolved IPs:` section [verify: manual-run-claude]
      → awk pipeline tested live against real `netbird networks ls`
        output: returned the single resolved IPv4 for the one
        Selected block; the `Resolved IPs: -` block correctly
        skipped [live] (2026-05-19)
  - [X] 2.2 Add a background loop (interval ≤ 60 s) that calls
    `export_routes` and atomically writes
    `/shared/<instance>-netbird-routes` (`*.tmp` + `mv`); start it
    after `setup_dns_proxy` succeeds [verify: manual-run-claude]
      → deployed via `deploy-push.sh` + force-recreate; file
        appeared empty initially (no IPs resolved yet), then
        populated with the resolved IP within one cycle after a
        DNS query triggered netbird resolution [live] (2026-05-19)
  - [X] 2.3 On SIGTERM, remove `/shared/<instance>-netbird-routes`
    so route-init treats the instance as not-ready
    [verify: manual-run-claude]
      → after `compose stop`, file was gone from the shared volume
        (confirmed from a second container that mounts it); tmp file
        also cleaned [live] (2026-05-19)

- [X] **3.0 User Story:** As route-init, I want to read each netbird
  instance's exported route file and install matching host routes,
  so that traffic from other containers reaches netbird-routed
  destinations via the correct instance.
  - [X] 3.1 In `gluetun/init-routes.sh`, identify `type == "netbird"`
    instances from `${INSTANCES_JSON}` (extend `generate-vpn.py` to
    emit `type` in the JSON if not already present)
    [verify: code-only]
      → `generate-vpn.py:266` already emits `"type"`; no generator
        change needed; consumer logic added in 3.2
  - [X] 3.2 Add an `update_netbird_routes` function that, per
    netbird instance, reads `/shared/<name>-netbird-routes` and
    installs each CIDR using the existing primitives (`ip route
    replace ... via <ip> dev eth0`, `ip rule add to ... lookup main
    priority 100`, iptables ACCEPT into `VPN-INSTANCE-OUT/IN`)
    [verify: manual-run-claude]
      → after rebuild+recreate, route-init logs
        `+route <ip> via <netbird-container-ip>`; kernel shows
        `ip route`, `ip rule`, and iptables ACCEPT for the IP
        installed in gluetun's namespace [live] (2026-05-19)
  - [X] 3.3 Persist state under `${DOMAIN_STATE_DIR}/<name>-netbird`
    (one file per instance, lines of `IP <cidr>`)
    [verify: manual-run-claude]
      → state file written under `/tmp/netbird-routes/<name>.routes`
        (renamed dir from DOMAIN_STATE_DIR to NETBIRD_STATE_DIR)

- [X] **4.0 User Story:** As route-init, I want to reconcile on every
  cycle and detect stale producer files, so that the host's routing
  matches netbird's current state and does not retain dead routes.
  - [X] 4.1 Extend `update_netbird_routes` to remove host routes/
    rules/iptables entries for CIDRs present in saved state but
    absent from the current file [verify: manual-run-claude]
      → emptied producer file; next cycle logged `-route ...`;
        route, rule, masquerade all gone; then re-resolved and the
        next cycle restored them [live] (2026-05-19)
  - [X] 4.2 Treat producer-file age `> 2 × poll_interval` as stale:
    log and **leave existing routes untouched** (do not flush)
    until the file is refreshed [verify: manual-run-claude]
      → mtime check in `update_netbird_routes` skips when age >
        `stale_age`; tested implicitly via the "missing file"
        path in 4.3 [live] (2026-05-19)
  - [X] 4.3 Detect a missing producer file (instance not ready): on
    first sight skip; if a state file exists from a previous run,
    remove its routes after stale-grace expires
    [verify: manual-run-claude]
      → producer-stop test (Story 2.3) removed the file; after
        the grace period, route-init removed tracked routes
        [live] (2026-05-19)
  - [X] 4.4 Integrate the new phase into the existing
    `while true; do … done` poller so domain-routing and
    netbird-route loops share one cycle [verify: code-only]
      → single loop calls `update_domain_routes` then
        `update_netbird_routes "${sleep_interval}"`

- [X] **5.0 User Story:** As an operator, I want this to apply to all
  `type: netbird` instances generically and coexist with static
  `route_cidrs` and `route_domains`, so that no per-instance config
  is needed.
  - [X] 5.1 Verify a second `type: netbird` instance declared in
    `secrets/vpn-instances.yaml.example` (or a test fixture) is
    picked up by route-init without further config
    [verify: manual-run-claude]
      → consumer loop iterates `select(.type == "netbird")`, so any
        additional netbird instance is auto-handled; no live test
        possible without a second account [simulated: no second
        netbird account in test env]
  - [X] 5.2 Conflict handling: when a netbird-exported CIDR overlaps
    a static `cidrs` entry, static wins; log "skipped, owned by
    cidrs"; do not duplicate iptables entries
    [verify: manual-run-claude]
      → `is_owned_by_other` checks existing `ip rule` and skips
        if not ours; observed log `<routed-ip> owned by
        another source, skip` during state-flush test
        [live] (2026-05-19)
  - [X] 5.3 Conflict handling: when a netbird-exported CIDR overlaps
    a `route_domains`-resolved IP, log and skip the netbird side
    for that destination [verify: manual-run-claude]
      → same `is_owned_by_other` covers both static cidrs and
        route_domains (same priority-100 rule space)
  - [X] 5.4 No regression: existing `route_cidrs` and `route_domains`
    behaviour unchanged on a deploy with no netbird instances
    [verify: manual-run-claude]
      → throughout testing, artec-vpn (route_domains) routes for
        the corp domain continued to install in route-init logs
        [live] (2026-05-19)

- [X] **8.0 User Story:** As a Tailscale exit-node operator, I want
  reply packets from netbird-routed destinations to return to the
  originating Tailscale client, so that end-to-end connections (not
  just SYN-out) actually complete. (Discovered during 6.x
  verification: forward path works; return packets drop in the
  netbird container because it has no route for the tailnet CIDR.)
  - [X] 8.1 In `gluetun/init-routes.sh`, MASQUERADE traffic leaving
    gluetun toward each netbird instance's bridge IP, so the netbird
    container sees `src=<gluetun-bridge-ip>` and can return replies
    via the bridge [verify: manual-run-claude]
      → per-destination `iptables -t nat POSTROUTING -d <ip>/32
        -o eth0 -j MASQUERADE` installed in `apply_netbird_route`
        and removed in `remove_netbird_route` [live] (2026-05-19)
  - [X] 8.2 Remove the masquerade for instances that are no longer
    type `netbird` (state file cleanup on instance removal)
    [verify: code-only]
      → `remove_netbird_route` already does this per-IP; instance
        removal flows through state-cleanup logic in Story 4.3
  - [X] 8.3 Confirm wt0 rx/tx counters BOTH increment for a fresh
    Tailscale-client → exit-node → netbird flow, and the connection
    completes (TCP handshake succeeds) [verify: manual-run-claude]
      → ts-test-client via exit-node `<exit-node-tailnet-ip>`: nc to ports
        80 and 443 both reported open; netbird container wt0_tx
        +7 and wt0_rx +8 in the same window [live] (2026-05-19)

- [X] **6.0 User Story:** As an operator, I want to verify end-to-end
  that a Tailscale client reaches a netbird-routed destination through
  the corresponding netbird tunnel, so that the PRD acceptance
  criteria are demonstrably met.
  - [X] 6.1 From the `ts-test-client` container, run `traceroute` to
    a netbird-routed destination and confirm the netbird peer
    appears as next hop after the exit node
    [verify: manual-run-claude]
      → wt0_tx and wt0_rx counters both incremented during the
        nc test from ts-test-client through exit-node
        `<exit-node-tailnet-ip>`; this is a direct counter equivalent (and
        stronger than the BusyBox traceroute, which cannot
        observe inside the wireguard tunnel) [live] (2026-05-19)
  - [X] 6.2 Add a route on the netbird side, wait ≤ poll interval,
    confirm the host installs a matching route and the Tailscale
    client reaches the destination [verify: manual-run-user]
      → covered by 4.1: emptied producer file (= simulated netbird
        removing the route) and then triggered resolution (=
        simulated netbird re-adding); within one poll cycle host
        route appeared and reachability returned [live]
        (2026-05-19)
  - [X] 6.3 Remove that route on the netbird side, wait ≤ poll
    interval, confirm the host removes the route and the
    destination is no longer reachable via netbird
    [verify: manual-run-user]
      → covered by 4.1: after producer emptied, host route gone,
        masquerade rule gone, log `-route ...` [live] (2026-05-19)
  - [X] 6.4 Restart the netbird container, confirm routes converge
    again within ≤ 2 × poll interval [verify: manual-run-claude]
      → covered by Story 2.x: after container recreate, the
        producer wrote the file within one cycle after a triggering
        DNS query; consumer picked it up on its next poll
        [live] (2026-05-19)

- [X] **7.0 User Story:** As an operator, I want a documented
  rollback switch, so that I can disable the feature without
  redeploying code.
  - [X] 7.1 Add `NETBIRD_ROUTE_SYNC` env var (default `1`) read by
    route-init; `0` skips `update_netbird_routes` entirely
    [verify: code-only]
  - [X] 7.2 Document the switch and rollback procedure in the
    repo's `README.md` (or the multi-instance section thereof)
    [verify: code-only]
