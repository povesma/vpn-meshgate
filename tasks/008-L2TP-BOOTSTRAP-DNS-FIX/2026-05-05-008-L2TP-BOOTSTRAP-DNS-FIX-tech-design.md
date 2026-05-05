# 008-L2TP-BOOTSTRAP-DNS-FIX: Resolve L2TP Gateway Hostname Bypassing Split-DNS - Technical Design

**Status**: Complete
**PRD**: [2026-05-05-008-L2TP-BOOTSTRAP-DNS-FIX-prd.md](2026-05-05-008-L2TP-BOOTSTRAP-DNS-FIX-prd.md)
**Created**: 2026-05-05

## Overview

Add a bootstrap-DNS step at the top of the L2TP entrypoint's
reconnect loop that resolves `L2TP_SERVER` via a public resolver
(bypassing dnsmasq) and writes the result into `/etc/hosts` for that
hostname. All subsequent libc-based lookups in the container —
including strongSwan's resolution of `right=`, xl2tpd's resolution
of `lns=`, and the existing route-pin `getent hosts` call — pick up
the IP from `/etc/hosts` (NSS files-before-dns) instead of forwarding
to dnsmasq. Re-runs on every loop iteration so gateway IP rotations
are picked up at every reconnect.

## Current Architecture (RLM-verified)

### L2TP entrypoint structure
- `l2tp/entrypoint.sh:264` — `configure()` runs ONCE before the loop;
  generates `/etc/ipsec.conf`, `/etc/ipsec.secrets`,
  `/etc/xl2tpd/xl2tpd.conf`, `/etc/ppp/options.l2tpd.client` from
  template strings using `${L2TP_SERVER}` literally.
  — verified via: `Read l2tp/entrypoint.sh`, 2026-05-05
- `l2tp/entrypoint.sh:266` — `while true` loop; per iteration calls
  `cleanup_stale_state` → `start_ipsec_daemon` → `connect` →
  (success: `setup_routing` + `monitor_ppp0`) / (fail:
  `backoff_sleep`).
  — verified via: `Read l2tp/entrypoint.sh`, 2026-05-05
- `connect()` (line 145) invokes `ipsec up L2TP-PSK`; strongSwan
  resolves `right=${L2TP_SERVER}` via libc at this moment.
  — verified via: `Read l2tp/entrypoint.sh:145-176`, 2026-05-05
- `setup_routing():235` — `getent hosts "${L2TP_SERVER}"` to pin a
  /32 route to the gateway via eth0. Today this hits dnsmasq and
  silently logs a warning if it fails; route-pin then doesn't happen
  (gateway traffic falls through to default — works only because the
  default still points to eth0 at that moment).
  — verified via: `Read l2tp/entrypoint.sh:233-241`, 2026-05-05

### Split-DNS deadlock chain (re-verified from PRD)
- `dns/entrypoint.sh:54` writes `server=/${domain}/${local_dns}` per
  configured `dns_domains` entry. With `corp.example.com` →
  `10.11.232.1`, the L2TP container's libc resolves
  `gw.corp.example.com` via dnsmasq → corp DNS → unreachable
  pre-tunnel.
  — verified via: `Read dns/entrypoint.sh:51-79`, 2026-05-05
- L2TP container's `/etc/resolv.conf` points at dnsmasq
  (172.29.0.30) by virtue of being on the `vpn-net` bridge with
  `dns: [172.29.0.10]`/dnsmasq wired in `docker-compose.yml`.
  — verified via: `grep "dns:" docker-compose.yml`, 2026-05-05
  (line 181 shows `- 172.29.0.10`; full resolution path goes
  through dnsmasq via the route-init / gluetun chain — sufficient
  for design purposes since the symptom is reproduced).

### Image base
- `l2tp/Dockerfile` — Alpine 3.21, installs `strongswan xl2tpd ppp
  iproute2 iptables iputils-ping curl`. No `bind-tools` (proper
  `nslookup`/`dig`); only busybox tools available for DNS by
  default.
  — verified via: `Read l2tp/Dockerfile`, 2026-05-05

### Generator
- `generate-vpn.py:144` — populates `L2TP_SERVER` from
  `inst["server"]` in the YAML; passed via env_file to the
  container. No re-resolution at generation time.
  — verified via: `grep L2TP_SERVER generate-vpn.py`, 2026-05-05

## Past Decisions (Claude-Mem)

- **007-DOMAIN-ROUTING (commit 13be442, 2026-04-12)** — disabled
  gluetun's internal DNS at runtime via its HTTP control API to
  bypass rebinding protection on CNAME chains. Established
  precedent: bootstrap-time DNS handling is distinct from
  steady-state, and adding a single-purpose resolution path for
  one container is acceptable.
- **007-DOMAIN-ROUTING tasks** added `bind-tools` to
  `gluetun/Dockerfile.route-init` to get `nslookup`/`dig` capable
  of taking an explicit resolver argument. Reusing the same package
  here is consistent.
- **006-MULTI-INSTANCE-VPN** — refactored `l2tp/entrypoint.sh` to be
  multi-instance aware via `INSTANCE_CIDRS`/`VPN_INSTANCE_NAME`. The
  per-instance contract (one container per instance, env-driven
  config) is the contract this design must preserve.

## Proposed Design

### Architecture

Add one new function `resolve_gateway` and one call site at the top
of the main loop. No new files. No changes to dnsmasq, the
generator, the YAML schema, the routing layer, or any other tunnel
type.

The function:
1. Looks up `${L2TP_SERVER}` via `nslookup <name> <resolver>`.
   Tries primary resolver first, falls back to secondary.
2. Retries with bounded backoff if both fail.
3. On success, atomically rewrites `/etc/hosts` so the entry for
   `${L2TP_SERVER}` reflects the freshly resolved IP. Sets a shell
   variable `GATEWAY_IP` for in-process reuse.
4. On exhaustion, returns non-zero; main loop treats it as a
   connect failure and falls into `backoff_sleep` — same plumbing
   as any other failed attempt.

### Why `/etc/hosts` rather than substitution

NSS resolution order on Alpine is `files dns` (default
`/etc/nsswitch.conf` behavior; Alpine's musl libc honors `hosts:`
in `/etc/nsswitch.conf` if present, otherwise reads `/etc/hosts`
unconditionally before DNS). Adding the line
`<ip>\t<hostname>` short-circuits all libc lookups of that exact
name to the literal IP without consulting `/etc/resolv.conf`
(dnsmasq).

This works because:
- strongSwan resolves `right=<host>` via libc (`getaddrinfo`).
- xl2tpd resolves `lns=<host>` via libc.
- The existing `getent hosts` at line 235 is libc by definition.
- All three pick up the `/etc/hosts` entry uniformly.

The substitution alternative would require moving the config-file
templates from `configure()` into the loop and re-rendering on each
iteration. Larger diff, more moving parts, and pointlessly couples
template logic to resolution logic.

### Components

**Modified Components**:

1. **`l2tp/entrypoint.sh`**
   - Add function `resolve_gateway` (between existing helpers).
   - Add call to `resolve_gateway` at top of the `while true` loop,
     before `cleanup_stale_state`. On failure, `backoff_sleep` and
     `continue`.
   - Replace the `getent hosts "${L2TP_SERVER}"` at line 235 with
     a use of the `GATEWAY_IP` shell variable populated by
     `resolve_gateway`.
   - Add new env-driven knobs (with defaults): `BOOTSTRAP_DNS_PRIMARY`
     (default `1.1.1.1`), `BOOTSTRAP_DNS_SECONDARY` (default
     `8.8.8.8`), `BOOTSTRAP_DNS_RETRIES` (default `5`),
     `BOOTSTRAP_DNS_BACKOFF` (default delays `5 10 20 40 60`).
     These are not surfaced through `generate-vpn.py` or the YAML
     schema; they exist for operator override only.

2. **`l2tp/Dockerfile`**
   - Add `bind-tools` to the `apk add` list. Provides `nslookup`
     that accepts an explicit resolver argument. Image grows by
     ~2MB.

### Data Contract

The function `resolve_gateway` produces:
- Side effect: `/etc/hosts` contains exactly one line for
  `${L2TP_SERVER}`, mapping it to the freshly resolved IP.
- Process state: shell variable `GATEWAY_IP` set to the resolved
  IPv4.
- Exit code: `0` on success, non-zero after retries exhausted.
- Logs: `[vpn-<inst>] Resolving <host> via <resolver>` on each
  attempt; `[vpn-<inst>] Gateway <host> -> <ip> (via <resolver>)`
  on success; `[vpn-<inst>] FATAL: cannot resolve <host> after N
  attempts` on exhaustion.

### Sequence (per loop iteration)

```
main-loop iteration
  └── resolve_gateway
        ├── nslookup ${L2TP_SERVER} ${BOOTSTRAP_DNS_PRIMARY}
        │     └── success → parse IP → update /etc/hosts → GATEWAY_IP=<ip> → return 0
        ├── (on fail) nslookup ${L2TP_SERVER} ${BOOTSTRAP_DNS_SECONDARY}
        │     └── success → same as above
        └── (on fail) sleep <backoff[i]>; retry from primary; up to BOOTSTRAP_DNS_RETRIES
              └── exhaust → return 1
  ├── (resolve_gateway returned 1) → backoff_sleep; continue
  └── (returned 0)
        ├── cleanup_stale_state
        ├── start_ipsec_daemon
        ├── connect            ← ipsec/xl2tpd resolve via /etc/hosts
        ├── setup_routing      ← uses GATEWAY_IP for route pin
        └── monitor_ppp0
```

### /etc/hosts management

Atomic update via temp file + rename:

```
grep -v "[[:space:]]${L2TP_SERVER}\$" /etc/hosts > /etc/hosts.new
echo "${GATEWAY_IP}\t${L2TP_SERVER}" >> /etc/hosts.new
mv /etc/hosts.new /etc/hosts
```

This removes any prior entry for the same hostname before adding
the new one, so successive iterations don't accumulate stale lines.
Does not touch other entries (localhost, container hostname).

### Error Handling

Follows existing patterns in the file:
- Per-attempt `log` lines mirror `connect()`'s style.
- Failure path returns to the same `backoff_sleep` used by every
  other loop failure, so notification (`notify "VPN Failing"` after
  3 consecutive failures) and downtime tracking
  (`DISCONNECT_TS`) work without modification.
- The very first iteration's failure also goes through
  `backoff_sleep`, which is acceptable: `BOOTSTRAP_DNS_BACKOFF`
  bounds resolution-only retries within an iteration; the outer
  `backoff_sleep` bounds retries across iterations.

### Verification Approach

| Requirement | Method | Scope | Expected Evidence |
|-------------|--------|-------|-------------------|
| FR-1: pre-resolve via public DNS | `manual-run-claude` | integration | logs show `Gateway <host> -> <ip>` line; `/etc/hosts` contains the entry |
| FR-2: primary + fallback resolver | `auto-test` | unit (shellcheck + function-level) | unit test stubs `nslookup` to fail primary, succeeds fallback; function returns 0 with secondary IP |
| FR-3: retry with backoff | `code-only` | — | inspect script: loop bound = `BOOTSTRAP_DNS_RETRIES`, sleeps from `BOOTSTRAP_DNS_BACKOFF` |
| FR-4: exit non-zero on exhaustion | `auto-test` | unit | stub both resolvers to fail; function returns non-zero; main loop calls `backoff_sleep` and `continue` |
| FR-5: re-resolve every attempt | `code-only` | — | call site is at top of `while true`, not in `configure()` |
| FR-6: dnsmasq unchanged | `code-only` | — | diff touches only `l2tp/entrypoint.sh` and `l2tp/Dockerfile` |
| AC: tunnel comes up | `manual-run-user` | e2e | `./rdocker.sh compose logs vpn-artec-vpn` shows `ppp0 is UP with IP <x>` after deploy |
| AC: corp DNS resolves post-up | `manual-run-user` | e2e | from dnsmasq: `nslookup <internal-name> 10.11.232.1` succeeds |
| AC: split-DNS not broken | `manual-run-user` | e2e | from dnsmasq: a non-gateway `*.corp.example.com` name resolves to internal IP via dnsmasq |
| Security: query path | `code-only` | — | confirm bootstrap query egresses via container default route (eth0 → docker bridge → host), not a tunnel |

## Trade-offs

### Resolution location

1. **/etc/hosts injection (Recommended)** — keeps configs static,
   refresh is one-line, all libc consumers benefit uniformly.
2. **sed-substitute IP into ipsec.conf and xl2tpd.conf** — explicit
   but couples template generation to the connect loop, larger diff.
3. **Custom resolver shim (e.g., a process-local musl override)** —
   would isolate the bypass to L2TP-internal lookups but adds
   significant complexity for no observable benefit.

### Re-resolution timing

1. **Top of every loop iteration (Recommended)** — covers boot,
   reconnect, gateway IP rotation, and DNS-side flaps with one
   policy.
2. **Once at startup, refresh on disconnect** — fewer queries during
   stable runs, but introduces a "refresh trigger correctness"
   problem.
3. **Inside `connect()` only** — duplicates retry plumbing.

### Lookup tooling

1. **`bind-tools` (`nslookup`)** — matches the precedent set by
   `gluetun/Dockerfile.route-init` in 007-DOMAIN-ROUTING.
2. **Pure shell over `/dev/udp`** — no dependency, but
   reimplementing DNS framing in shell is fragile.
3. **`dig`** — same package, marginally cleaner output. Either
   works; `nslookup` matches existing precedent.

## Implementation Constraints

**From existing architecture**:
- Must remain a POSIX-`sh` script (no bash-isms); `set -e` in
  effect — every command that may fail needs explicit handling.
- Logging style `[vpn-<INSTANCE>] <message>` is convention; new
  logs must conform.
- Cannot change YAML schema or `generate-vpn.py` (out of scope per
  PRD).
- Cannot add a service or sidecar — fix is in-container.

**From past experience**:
- 007-DOMAIN-ROUTING showed that adding bind-tools to a tunnel-side
  image is uncontroversial and produces clean, debuggable output.
- 006-MULTI-INSTANCE-VPN's healthcheck refactor (commit 28b69f7)
  demonstrated that file-based state is preferable to `eval`-style
  expansion. The `/etc/hosts` write here is the same spirit:
  serialize through a file rather than carry resolution state in
  shell variables across function boundaries.

## Files to Create/Modify

**Modify**:
- `l2tp/entrypoint.sh` — add `resolve_gateway` function; call it at
  top of main loop; replace `getent hosts` at line 235 with
  `GATEWAY_IP` reference; add env-knob defaults near top.
- `l2tp/Dockerfile` — add `bind-tools` to `apk add` list.

**Create**:
- (None.)

## Dependencies

**External**:
- `bind-tools` (Alpine package) — provides `nslookup` accepting an
  explicit resolver. Stable, in main repo.

**Internal**:
- Existing `log`, `backoff_sleep`, `notify` helpers in
  `l2tp/entrypoint.sh`.

## Security Considerations

- The bootstrap lookup leaks `${L2TP_SERVER}` to the public
  resolver. This is acceptable: the same hostname is publicly
  resolvable today (verified: `gw.corp.example.com` returns
  via 1.1.1.1, 2026-05-05), so no information is exposed that an
  external observer couldn't already obtain.
- The query egresses via the container's default route, which is
  the docker bridge → host. Before the tunnel is up the L2TP
  container has no route to anywhere except the bridge gateway and
  whatever other instance routes route-init has installed. This
  means the query goes out the host's normal internet path, not
  through Mullvad/gluetun (the L2TP container is not in gluetun's
  network namespace). Acceptable.
- `/etc/hosts` writes are constrained to the single hostname
  matching `${L2TP_SERVER}`; no user-controlled input is
  interpolated unsafely (the variable comes from `generate-vpn.py`
  which sources from secrets/vpn-instances.yaml — operator-trusted).

## Performance Considerations

- One additional DNS round-trip on each connect attempt. Negligible
  (<50ms typical).
- Image size: +~2MB for `bind-tools`. Acceptable.
- No steady-state cost: function only runs at connect/reconnect
  time, not during the long-lived `monitor_ppp0` loop.

## Rollback Plan

Single-commit revert of changes to `l2tp/entrypoint.sh` and
`l2tp/Dockerfile`. After revert, redeploy with
`./rdocker.sh compose up -d --build --force-recreate vpn-artec-vpn`.
The container returns to its pre-fix behavior (deadlock under
split-DNS for the gateway zone, but functional under any other
config).

## References

### Code (RLM):
- `l2tp/entrypoint.sh:37-109` — `configure()` template generation
  (untouched by this design)
- `l2tp/entrypoint.sh:233-241` — existing `getent hosts` route-pin
  (replaced)
- `l2tp/entrypoint.sh:266-303` — main loop (call site)
- `dns/entrypoint.sh:51-79` — split-DNS rule generator (causes the
  deadlock; not modified)
- `gluetun/Dockerfile.route-init` — precedent for adding
  `bind-tools` to a tunnel-side image

### History (Claude-Mem):
- 007-DOMAIN-ROUTING — bootstrap-vs-steady-state DNS handling
  precedent
- 006-MULTI-INSTANCE-VPN — per-instance L2TP entrypoint contract

---

**Next Steps**:
1. Review and approve design
2. Run `/dev:tasks` for task breakdown
