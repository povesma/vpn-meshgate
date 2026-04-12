# 007-DOMAIN-ROUTING: Domain-Based VPN Routing - Technical Design

**Status**: Complete
**PRD**: [007-DOMAIN-ROUTING-prd.md](2026-04-08-007-DOMAIN-ROUTING-prd.md)
**Created**: 2026-04-08

## Overview

Extend route-init with a periodic DNS resolver that resolves
`route_domains` from `vpn-instances.json` and manages /32 host
routes in the gluetun namespace. Each resolved IP gets a route
to the designated VPN instance container, using the same routing
primitives as existing CIDR routing.

## Current Architecture

```
gluetun namespace (route-init, tailscale, healthcheck, bot, ntfy)
  │
  ├─ instance CIDRs ──→ 172.29.0.101 (vpn-company-a)  [ip route + ip rule]
  ├─ instance CIDRs ──→ 172.29.0.102 (vpn-company-b)  [ip route + ip rule]
  └─ default ──→ tun0 (Mullvad)

dnsmasq (172.29.0.30, separate namespace on bridge_vpn)
  ├─ dns_domains ──→ company DNS (split resolution)
  └─ default ──→ Mullvad DNS
```

**Key constraint**: dnsmasq and route-init are in different
network namespaces. Kernel ipsets and iptables rules are
per-namespace — dnsmasq cannot create routing state visible to
route-init.

**Relevant components**:
- `gluetun/init-routes.sh` — CIDR routing setup, custom iptables
  chains (VPN-INSTANCE-OUT/IN), then `sleep infinity`
- `gluetun/Dockerfile.route-init` — Alpine + iproute2, iptables,
  wget, jq (no DNS tools)
- `dns/entrypoint.sh` — dnsmasq config generation from
  `vpn-instances.json`
- `generate-vpn.py` — YAML validation, JSON + override generation

## Proposed Design

### Architecture (Target State)

```
gluetun namespace
  │
  ├─ instance CIDRs ──→ vpn-company-a    [ip route, static]
  ├─ instance CIDRs ──→ vpn-company-b    [ip route, static]
  ├─ git.company.com (198.51.100.34/32) ──→ vpn-company-a  [ip route, dynamic]
  ├─ ci.company.com  (203.0.113.10/32)  ──→ vpn-company-a  [ip route, dynamic]
  └─ default ──→ tun0 (Mullvad)

route-init:
  1. Setup CIDR routes (existing, runs once)
  2. Domain routing loop (NEW, TTL-aware):
     dig @127.0.0.1 (gluetun DNS) → compare → add/remove /32 routes
     → sleep until shortest TTL expires (re-resolve early)
```

### Component: `generate-vpn.py` (Modified)

**Changes**: Add `route_domains` to validation and JSON output.

**Validation rules**:
- `route_domains`: optional list of strings per instance
- Each entry: valid domain name or wildcard (`*.company.com`)
- No duplicate domains across instances (same as `cidrs`
  overlap check)
- Wildcards: only leading `*.` prefix, no mid-string wildcards

**JSON output** — add `route_domains` field:
```json
{
  "name": "company-a",
  "type": "l2tp",
  "ip": "172.29.0.101",
  "cidrs": ["10.11.0.0/16"],
  "route_domains": ["company-a.com", "*.company-a.com"],
  "check_ip": "10.11.0.1",
  "dns_domains": ["company-a.com"],
  "container": "vpn-company-a"
}
```

### Component: `gluetun/init-routes.sh` (Modified)

**Changes**: Replace `exec sleep infinity` with a domain routing
loop when `route_domains` are configured.

**Domain routing loop (TTL-aware)**:

```
State: /tmp/domain-routes/<instance>/<domain>.state
       (per domain: resolved IPs + TTL + timestamp)

MIN_POLL = 30        # floor: never poll faster than 30s
MAX_POLL = 300       # ceiling: re-resolve at least every 5min
TTL_MARGIN = 0.8     # re-resolve at 80% of TTL (before expiry)

loop:
  min_sleep = MAX_POLL

  for each instance with route_domains:
    for each domain:
      # dig with answer section to get both IPs and TTLs
      dig_output = dig @127.0.0.1 <domain> +noall +answer
      resolved_ips = extract A record IPs
      min_ttl = MIN(all A record TTLs) or MAX_POLL if none
      previous_ips = read state file

      for ip in (resolved_ips - previous_ips):  # new IPs
        ip route replace <ip>/32 via <instance_ip> dev eth0
        ip rule del to <ip>/32 ... 2>/dev/null  # idempotent
        ip rule add to <ip>/32 lookup main priority 100
        iptables -A VPN-INSTANCE-OUT -o eth0 -d <ip>/32 -j ACCEPT
        iptables -A VPN-INSTANCE-IN -i eth0 -s <ip>/32 -j ACCEPT

      for ip in (previous_ips - resolved_ips):  # stale IPs
        ip route del <ip>/32 via <instance_ip> dev eth0
        ip rule del to <ip>/32 lookup main priority 100
        iptables -D VPN-INSTANCE-OUT -o eth0 -d <ip>/32 -j ACCEPT
        iptables -D VPN-INSTANCE-IN -i eth0 -s <ip>/32 -j ACCEPT

      write resolved_ips + min_ttl + now to state file

      # Track the soonest re-resolve time across all domains
      next_resolve = min_ttl * TTL_MARGIN
      min_sleep = MIN(min_sleep, next_resolve)

  sleep CLAMP(min_sleep, MIN_POLL, MAX_POLL)
```

**TTL behavior**:
- Each `dig` response includes per-record TTL values
- The loop sleeps until the shortest TTL is 80% expired,
  so routes are refreshed just before DNS records go stale
- Floor of 30s prevents spinning on very short TTLs
- Ceiling of 300s ensures re-resolution even for long TTLs
  (catches out-of-band DNS changes)
- On first run (no state), all domains resolve immediately

**Wildcard handling**: `*.company.com` cannot be resolved with
`dig`. The loop resolves only bare domains. Wildcards work via
a different mechanism: when the user configures
`route_domains: ["*.company-a.com"]`, route-init resolves
`company-a.com` (strip the `*.` prefix). For actual subdomain
IPs (e.g., `git.company-a.com`), the user should list them
explicitly or rely on the wildcard resolving to the same IP
range. Alternatively, wildcards can be combined with
`dns_domains` to ensure all subdomains resolve via the company
DNS, and the resolver can enumerate known subdomains from DNS
query logs — but this adds complexity. For v1, wildcards resolve
the base domain only. Individual subdomains should be listed
explicitly.

**Fallback**: If no instances have `route_domains`, the script
falls back to `exec sleep infinity` (current behavior).

### Component: `gluetun/Dockerfile.route-init` (Modified)

Add `bind-tools` package for `dig`:
```dockerfile
RUN apk add --no-cache iproute2 iptables wget jq bind-tools
```

### Component: `secrets/vpn-instances.yaml.example` (Modified)

Add `route_domains` examples to existing instance definitions.

### Data Contract: `vpn-instances.yaml` (Extended)

```yaml
instances:
  - name: company-a
    type: l2tp
    server: vpn.company-a.com
    cidrs:
      - 10.11.0.0/16
    dns_domains:
      - company-a.com
    route_domains:              # NEW
      - company-a.com
      - git.company-a.com
      - ci.company-a.com
      - jira.company-a.com
    check_ip: 10.11.0.1
    credentials:
      username: user
      password: pass
      psk: shared-secret
```

**Field interactions**:
- `dns_domains` = which DNS server resolves the domain (split DNS)
- `route_domains` = route resolved IPs through this VPN instance
- `cidrs` = route static IP ranges through this VPN instance
- All three are independent and combinable
- A domain in `route_domains` that requires company DNS for
  resolution should also be in `dns_domains`

### Component: VPN Instance Entrypoints (Modified)

**Problem**: route-init (in the gluetun namespace) creates /32
routes that send domain-resolved traffic to the correct VPN
instance container. The packet arrives at the container on
`eth0`. But the container's routing table only sends
`INSTANCE_CIDRS` (e.g., `10.11.0.0/16`) through the tunnel
interface (`ppp0`/`wg0`/`tun0`/`wt0`). A public IP like
`18.239.18.127` doesn't match any CIDR, so the container sends
it back out the default route (`172.29.0.1`, Docker bridge) →
VPS internet, bypassing the tunnel entirely.

**Fix**: After the tunnel interface is up, change the default
route inside the VPN instance container from Docker bridge to
the tunnel interface. This makes ALL non-bridge traffic go
through the tunnel. Since route-init only sends traffic to this
container that should go through the tunnel, this is correct.

To prevent reconnection failure when the tunnel drops, pin a
static route for the VPN server's IP via `eth0` before changing
the default. This ensures the container can always reach the
VPN server to re-establish the tunnel.

**Routing table inside VPN instance container (after fix)**:

```
<VPN_SERVER_IP>/32  → eth0 (172.29.0.1)   pinned: always reach VPN server via internet
172.29.0.0/24       → eth0                 kernel: Docker bridge (ntfy, dnsmasq, etc.)
10.11.0.0/16        → ppp0                 INSTANCE_CIDRS (existing)
default             → ppp0                 NEW: everything else through tunnel
```

**Changes per entrypoint** (`setup_routing()` function):

- `l2tp/entrypoint.sh`: resolve `L2TP_SERVER` to IP, pin via
  `eth0`, change default to `ppp0`
- `wireguard/entrypoint.sh`: extract endpoint IP from
  `wg show wg0 endpoints`, pin via `eth0`, change default to
  `wg0`
- `openvpn/entrypoint.sh`: extract remote IP from
  `/etc/openvpn/client.conf`, pin via `eth0`, change default
  to `tun0`
- `netbird/entrypoint.sh`: extract management server IP from
  `NB_MANAGEMENT_URL`, pin via `eth0`, change default to `wt0`

**Cleanup**: `cleanup_stale_state()` / `disconnect()` do NOT
need to restore the default route. The pinned VPN server route
ensures reconnection works even with `default → tunnel`.
On container restart, the routing table resets to Docker defaults
automatically (fresh network namespace).

### Route Precedence

Routes are evaluated by specificity (longest prefix match):

1. `/32` routes from `route_domains` (most specific)
2. CIDR routes from `cidrs` (e.g., `/16`)
3. Default route via Mullvad `tun0`

If a resolved IP falls within an existing CIDR, both routes
exist but the CIDR route already handles it — the `/32` is
redundant but harmless. The resolver does NOT skip domains whose
IPs fall within `cidrs`, keeping the logic simple.

## Trade-offs

### Polling resolver vs dnsmasq ipset

**Chose: Polling resolver in route-init.**

dnsmasq supports `--ipset=/<domain>/<setname>` which adds
resolved IPs to kernel ipsets in real-time. However, dnsmasq
and route-init are in different network namespaces — ipsets
created by dnsmasq are invisible to route-init's iptables.

Alternatives to bridge this gap (moving dnsmasq into gluetun
namespace, file-based signaling) all require significant
architectural changes and add complexity.

The polling approach:
- Requires no architectural changes
- Uses the same routing primitives as existing CIDR routing
- Adds one dependency (`bind-tools` in route-init)
- TTL-aware: re-resolves at 80% of TTL, so routes refresh
  just before records expire — not a fixed blind interval
- First connection to a new domain may go via Mullvad until
  the next poll cycle; subsequent connections route correctly

### Wildcard resolution

**Chose: Resolve base domain only for v1.**

Wildcards (`*.company.com`) cannot be resolved with `dig` — they
are a DNS server-side concept. Resolving every possible subdomain
is infeasible. For v1, `*.company.com` resolves `company.com`
(strip prefix). Users should list specific subdomains they need.

A future enhancement could integrate with dnsmasq query logs to
discover and resolve subdomains dynamically.

### Separate route_domains vs extending dns_domains

**Chose: Separate field.**

`dns_domains` controls DNS resolution (which server answers).
`route_domains` controls IP routing (which tunnel carries
traffic). These are orthogonal concerns. A public domain might
need routing but not split DNS. An internal domain might need
split DNS but routing is already handled by CIDRs.

## Verification Approach

| Requirement | Method | Scope | Expected Evidence |
|-------------|--------|-------|-------------------|
| FR-1: route_domains in YAML | `manual-run-claude` | unit | generator accepts and validates |
| FR-2: route_domains in JSON | `manual-run-claude` | unit | JSON output includes field |
| FR-3: /32 routes created | `manual-run-user` | integration | `ip route` in gluetun shows /32 via instance IP |
| FR-4: routes update on DNS change | `manual-run-user` | integration | after DNS TTL, new IP routed |
| FR-5: coexists with CIDRs | `manual-run-user` | integration | both /32 and CIDR routes present |
| E2E: curl reaches via VPN | `manual-run-user` | e2e | traffic to domain exits via VPN instance |

## Files to Create/Modify

**Modify**:
- `generate-vpn.py` — add `route_domains` validation and JSON
  output
- `gluetun/init-routes.sh` — add domain routing loop after CIDR
  setup
- `gluetun/Dockerfile.route-init` — add `bind-tools` package
- `secrets/vpn-instances.yaml.example` — add `route_domains`
  examples
- `l2tp/entrypoint.sh` — pin VPN server route via eth0, change
  default route to ppp0 in `setup_routing()`
- `wireguard/entrypoint.sh` — pin endpoint route via eth0,
  change default route to wg0 in `setup_routing()`
- `openvpn/entrypoint.sh` — pin remote IP route via eth0,
  change default route to tun0 in `setup_routing()`
- `netbird/entrypoint.sh` — pin management server route via
  eth0, change default route to wt0 in `setup_routing()`

- `docker-compose.yml` — enable gluetun HTTP control server,
  remove `DNS_REBINDING_PROTECTION_EXEMPT_HOSTNAMES`
- `.env.example` — remove `VPN_DNS_DOMAINS`

**No changes needed**:
- `dns/entrypoint.sh` — dnsmasq config unaffected

## Dependencies

**Build-time** (route-init container):
- `bind-tools` (Alpine package) — provides `dig`

**No new runtime or external dependencies.**

### DNS Architecture: Disable Gluetun DNS, Use Dnsmasq Directly

Gluetun has a built-in DNS server (port 53) with DNS rebinding
protection that silently drops CNAME chain responses (e.g.,
`analytics.google.com` → CNAME → A record). This cannot be
disabled via env var and the exemption list
(`DNS_REBINDING_PROTECTION_EXEMPT_HOSTNAMES`) cannot cover all
possible CNAME domains on the internet.

**Solution**: Disable gluetun's DNS server at startup via its
HTTP control API, so all DNS goes directly to dnsmasq through
the existing DNAT rule on `tailscale0`.

**DNS flow (after fix)**:
```
Mac → Tailscale → tailscale0:53 in gluetun namespace
  → DNAT → dnsmasq (172.29.0.30:53)
  → split DNS (company domains → company DNS, else → Mullvad)
  → response back to Mac

route-init → dig @172.29.0.30 → same dnsmasq
```

Both Mac and route-init use the same dnsmasq instance. No
gluetun DNS in the middle. No rebinding protection. No CNAME
issues. No CDN IP mismatch.

**Changes required**:
1. `docker-compose.yml`: enable gluetun HTTP control server
   (`HTTP_CONTROL_SERVER_ADDRESS=:8000`)
2. `gluetun/init-routes.sh`: at startup, call
   `PUT http://127.0.0.1:8000/v1/dns/status {"status":"stopped"}`
   to stop gluetun's DNS server
3. `gluetun/init-routes.sh`: resolve via dnsmasq directly
   (`DNS_SERVER=172.29.0.30`)
4. `.env.example`: remove `VPN_DNS_DOMAINS` (no longer needed)
5. `docker-compose.yml`: remove
   `DNS_REBINDING_PROTECTION_EXEMPT_HOSTNAMES` (no longer needed)

**Why this is safe**: Gluetun uses hardcoded IPs for VPN server
connections (no DNS needed). Gluetun's health check uses its
HTTP API at `127.0.0.1:9999` (no DNS needed). No container in
the gluetun namespace depends on gluetun's DNS — they all can
use dnsmasq via the Docker bridge.

## Security Considerations

- `dig` queries go to dnsmasq (`172.29.0.30`) on the Docker
  bridge — no external DNS leakage
- Domain names in `vpn-instances.yaml` are not secrets — they
  appear in `vpn-instances.json` which is already synced to VPS
- `/32` routes use the same iptables chains and policy routing
  as existing CIDR routes — no new attack surface

## Rollback Plan

Remove `route_domains` from `vpn-instances.yaml`, re-run
`generate-vpn.py`, redeploy. The domain routing loop is a no-op
when no instances have `route_domains`. Or simply revert the
route-init script — it falls back to `sleep infinity`.

---

**Next Steps**:
1. Review and approve design
2. Run `/dev:tasks` for task breakdown
