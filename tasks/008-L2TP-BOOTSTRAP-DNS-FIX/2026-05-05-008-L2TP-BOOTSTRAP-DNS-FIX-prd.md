# 008-L2TP-BOOTSTRAP-DNS-FIX: Resolve L2TP Gateway Hostname Bypassing Split-DNS - PRD

**Status**: Complete
**Created**: 2026-05-05
**Author**: Claude (via dev workflow analysis)

---

## Context

vpn-meshgate uses split-DNS: dnsmasq sends queries for corporate
domains (e.g., `corp.example.com`) to the corporate DNS server
reachable only through the corresponding VPN tunnel. This is correct
behavior for normal traffic AFTER tunnels are up.

The L2TP tunnel container (`vpn-artec-vpn`) needs to resolve its OWN
gateway hostname (e.g., `gw.corp.example.com`) to dial the
IPsec/L2TP endpoint. The container's only resolver is dnsmasq
(172.29.0.30). Under split-DNS, that query is forwarded to the
corporate DNS at `10.11.232.1`, which is reachable only through the
tunnel that hasn't come up yet. Result: bring-up deadlock.

### Current State (observed 2026-05-05)

- L2TP container has been retrying for 1168+ attempts; ppp0 never
  comes up
  — verified via: `./rdocker.sh compose logs vpn-artec-vpn`,
  2026-05-05
- Failure log: `Host name lookup failed for
  gw.corp.example.com` and `unable to resolve
  gw.corp.example.com, initiate aborted`
  — verified via: `./rdocker.sh compose logs vpn-artec-vpn`,
  2026-05-05
- dnsmasq config contains `server=/corp.example.com/10.11.232.1`
  — verified via: `./rdocker.sh compose exec dnsmasq cat
  /etc/dnsmasq.conf`, 2026-05-05
- Corporate DNS `10.11.232.1` is inside `10.11.0.0/16` which is
  routed `via 172.29.0.101` (artec-vpn) — only reachable through
  the very tunnel being brought up
  — verified via: `./rdocker.sh compose exec dnsmasq ip route` and
  `/shared/vpn-instances.json`, 2026-05-05
- The same hostname resolves successfully on public DNS:
  `gw.corp.example.com → 198.51.100.34` via 1.1.1.1
  — verified via: `./rdocker.sh compose exec dnsmasq nslookup
  gw.corp.example.com 1.1.1.1`, 2026-05-05
- Downstream effect: from a Mac client via Tailscale exit node,
  internal corporate names return "No answer" via dnsmasq because
  forwards to `10.11.232.1` time out (`communications error to
  10.11.232.1#53: timed out`) — the corp resolver is unreachable
  with the L2TP tunnel down
  — verified via: user-reported nslookup output, 2026-05-05
- L2TP entrypoint currently passes the gateway hostname directly
  into IPsec/xl2tpd config without pre-resolution
  — [assumption based on log message format, verify in tech-design]

### Past Similar Features (from claude-mem)

- **006-MULTI-INSTANCE-VPN** rewrote `l2tp/entrypoint.sh` for
  per-instance operation. The split-DNS + per-instance L2TP
  combination originates here, but the deadlock only manifests when
  a deployment uses split-DNS for the same zone the L2TP gateway
  hostname lives under.
- **007-DOMAIN-ROUTING** (commit `13be442`) disabled gluetun's
  internal DNS server and pointed it at dnsmasq to bypass rebinding
  protection on CNAME chains. Established the pattern that
  bootstrap-time DNS needs special handling distinct from
  steady-state resolution.

## Problem Statement

**Who**: Operators of vpn-meshgate deployments where any L2TP
instance has a gateway hostname under a zone listed in that
instance's `dns_domains` (split-DNS).

**What**: The L2TP tunnel cannot bring itself up because its gateway
hostname is resolved via the corporate DNS that is only reachable
through the tunnel itself.

**Why**: Loss of all routing through that VPN instance — including
loss of corporate-DNS resolution for every other name under the
same zone, since dnsmasq cannot reach the corporate resolver.
Cascading failure: one missing route disables an entire split-DNS
zone for all clients.

**When**: At every container start and every reconnect attempt for
L2TP instances whose gateway hostname falls under a configured
split-DNS zone.

## Goals

### Primary Goal

L2TP tunnel bring-up must not depend on the corporate DNS that the
tunnel itself provides access to. Gateway-hostname resolution at
startup must use a resolver that is reachable without the tunnel
being up.

### Secondary Goals

- Preserve existing split-DNS behavior for steady-state traffic —
  corporate names other than the gateway hostname must continue to
  resolve via the corporate DNS server through the tunnel.
- Survive transient public-DNS unavailability at boot without
  requiring operator intervention.
- Re-resolve at every connection attempt so gateway IP rotations
  are picked up automatically.

## User Stories

### Epic

As an operator of vpn-meshgate, I want L2TP tunnels to bootstrap
their gateway hostname against a resolver that is reachable without
the tunnel itself, so that split-DNS configuration covering the
gateway's zone does not deadlock tunnel bring-up.

### User Stories

1. **As an** operator
   **I want** the L2TP entrypoint to resolve the gateway hostname
   via public DNS before invoking IPsec/xl2tpd
   **So that** the tunnel can come up regardless of whether the
   gateway hostname falls under a split-DNS zone

   **Acceptance Criteria**:
   - [ ] L2TP entrypoint resolves the gateway hostname via a public
     resolver, not via the container's default resolver
   - [ ] IPsec/xl2tpd receive a literal IP, not the hostname
   - [ ] Re-resolution happens on every connection attempt (not
     cached across the lifetime of the container) so rotated
     gateway IPs are picked up
   - [ ] If public DNS is unreachable, the entrypoint retries with
     backoff before failing
   - [ ] Existing dnsmasq split-DNS configuration is unchanged;
     non-gateway corporate names continue to resolve via the
     corporate DNS server after the tunnel is up

2. **As an** operator
   **I want** clear log output showing which resolver was used and
   what IP was returned
   **So that** I can diagnose bootstrap failures without re-running
   `nslookup` manually

   **Acceptance Criteria**:
   - [ ] On success: log contains gateway hostname, resolver used,
     resolved IP, and a timestamp
   - [ ] On failure: log contains hostname, resolvers attempted,
     attempt count, and the final error before exit/retry

## Requirements

### Functional Requirements

1. **FR-1**: L2TP entrypoint MUST resolve the gateway hostname via
   a configured public DNS resolver before invoking the IPsec/xl2tpd
   processes that consume the gateway address.
   - **Priority**: High
   - **Rationale**: Eliminates the bootstrap deadlock; this is the
     core fix.
   - **Dependencies**: None new; uses tools already present or
     trivially addable to the L2TP image.

2. **FR-2**: The lookup MUST use one public resolver as primary and
   a second public resolver as fallback. The exact addresses are a
   tech-design decision; the requirement is "two independent
   providers."
   - **Priority**: High
   - **Rationale**: Single-resolver outages are real and would
     otherwise prevent tunnel bring-up.
   - **Dependencies**: None.

3. **FR-3**: On lookup failure, the entrypoint MUST retry with
   bounded backoff before giving up. Bound and backoff curve are
   tech-design decisions.
   - **Priority**: High
   - **Rationale**: Boot-time and post-host-reboot windows can have
     transient internet unavailability.
   - **Dependencies**: None.

4. **FR-4**: After the bound is exhausted, the entrypoint MUST exit
   non-zero with a clear log line, allowing the container's restart
   policy to take over.
   - **Priority**: High
   - **Rationale**: Surfaces unrecoverable failures to compose-level
     visibility instead of an internal infinite loop.
   - **Dependencies**: Existing `restart: unless-stopped`-style
     policy on the L2TP service.

5. **FR-5**: Re-resolution MUST occur at every connection attempt,
   not be cached across the container lifetime.
   - **Priority**: Medium
   - **Rationale**: Gateway IPs may rotate; cached values would
     break reconnection silently.
   - **Dependencies**: None.

6. **FR-6**: dnsmasq configuration and the rest of the routing
   pipeline MUST remain unchanged. The fix is local to the L2TP
   entrypoint.
   - **Priority**: High
   - **Rationale**: Minimizes blast radius; preserves verified
     behavior of features 005, 006, 007.
   - **Dependencies**: None.

### Non-Functional Requirements

1. **NFR-1**: Performance — Bootstrap resolution adds at most a
   few seconds to first connection attempt; not measurable in
   steady state since tunnels are long-lived.

2. **NFR-2**: Security — The bootstrap resolver query leaks the
   gateway hostname to the public resolver. This is acceptable
   because the same hostname is already publicly resolvable (it
   must be, for any external client to dial in). Tech-design must
   confirm the query egress path does not bypass gluetun's
   firewall or VPN-shielded outbound.

3. **NFR-3**: Observability — Bootstrap success and failure must
   be visible in `docker compose logs <l2tp-instance>` without
   needing to exec into the container.

### Technical Constraints

- Must integrate with: `l2tp/entrypoint.sh` and the IPsec/xl2tpd
  config files it generates or templates.
- Should follow patterns: existing entrypoint logging style
  (`[<instance>] <message>` prefix), existing use of shell-only
  tooling (no Python in tunnel containers).
- Cannot change: dnsmasq behavior, `generate-vpn.py` schema,
  routing setup in `gluetun/init-routes.sh`, or YAML schema in
  `secrets/vpn-instances.yaml`.

## Out of Scope

- WireGuard, OpenVPN, and Netbird entrypoints. Their endpoint
  resolution paths differ and may have the same latent issue, but
  no user-visible failure is reported. Address in a follow-up
  task if/when reproduced.
- Caching the resolved IP to disk for use across container
  restarts.
- Making the public resolver per-instance configurable via YAML.
  Defaults are sufficient.
- Wiring bootstrap events into the ntfy notification path.
- Documentation updates beyond the task files (README is unaffected
  by this internal fix).

## Success Metrics

1. **Tunnel bring-up succeeds** for an L2TP instance whose
   gateway hostname is under a configured `dns_domains` zone.
   Target: ppp0 acquires an IP within the existing 60s timeout on
   the first attempt after deploy.
2. **Split-DNS regression**: zero. Corporate names other than the
   gateway hostname continue to resolve via the corporate DNS
   after the tunnel is up.
3. **Restart resilience**: an L2TP container restart while the
   internet path is briefly unavailable does not require operator
   intervention — tunnel comes up on its own once public DNS is
   reachable, within the configured retry bound.

## References

### From Codebase (RLM / direct inspection)

- `l2tp/entrypoint.sh` — primary edit target (per task 006 file
  list)
- `dns/entrypoint.sh:54` — split-DNS rule generator
  (`server=/${domain}/${local_dns}`); confirms the mechanism that
  causes the deadlock
- `gluetun/init-routes.sh` — bootstrap-DNS handling for the
  route-init container; precedent for treating bootstrap
  resolution differently from steady-state
- `/shared/vpn-instances.json` (runtime) — confirms instance
  routing layout and corp DNS IPs

### From History (Claude-Mem)

- `006-MULTI-INSTANCE-VPN` — last touched `l2tp/entrypoint.sh`;
  defines the per-instance contract this fix must preserve
- `007-DOMAIN-ROUTING` (obs 9789, 9791) — pattern of disabling
  upstream-dependent DNS at bootstrap and falling back to dnsmasq;
  thematically similar to "bootstrap needs a different resolver"

---

**Next Steps**:
1. Review and refine this PRD
2. Run `/dev:tech-design` to create technical design (needed:
   exact resolver addresses, retry bound and backoff curve, choice
   between literal IP substitution vs. an alternate resolver
   config for IPsec/xl2tpd)
3. Run `/dev:tasks` to break down into tasks
