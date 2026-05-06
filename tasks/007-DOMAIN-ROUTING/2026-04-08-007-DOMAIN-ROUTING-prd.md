# 007-DOMAIN-ROUTING: Domain-Based VPN Routing - PRD

**Status**: Complete
**Created**: 2026-04-08
**Author**: Claude (via dev workflow analysis)

---

## Context

vpn-meshgate currently routes traffic to VPN instances based on
static CIDR ranges defined in `vpn-instances.yaml`. This works
well for private corporate subnets (e.g., `10.11.0.0/16`) but
fails for company services hosted on public IPs. When a user
accesses `git.company.com` (resolving to `198.51.100.34`), the
traffic exits via Mullvad instead of the company VPN instance —
the company service rejects it because the source IP is Mullvad's,
not the company VPN's.

### Current State

- Each VPN instance defines static `cidrs` for IP-based routing
  and optional `dns_domains` for split DNS resolution
- `dns_domains` controls which DNS server resolves a domain but
  does NOT affect routing of the resolved IP
- Traffic to IPs not matching any instance's CIDRs exits via
  Mullvad (default route)
- Netbird handles domain-based routing natively via its
  management server, but this is Netbird-specific and not
  available to other tunnel types

### Tailscale Exit Node Context

Traffic to public IPs always arrives in the gluetun namespace
when using vpn-meshgate as a Tailscale exit node — no
`--advertise-routes` or Headscale changes are needed. The
routing decision for public IPs happens entirely inside the
namespace. This feature does not require any Tailscale or
Headscale configuration changes.

(Private IPs discovered via DNS that fall outside existing
`cidrs` still require `--advertise-routes` + Headscale approval
— this is a Tailscale limitation, not in scope for this feature.)

## Problem Statement

**Who**: VPN user accessing company services on public IPs
**What**: Cannot route traffic to company services by domain
name — only by static IP ranges
**Why**: Company services like `git.company.com`,
`jira.company.com`, `ci.company.com` are hosted on public IPs
that may change; the VPN instance that should carry this traffic
has no way to claim these domains
**When**: When accessing any company-hosted service whose IP is
not within a static CIDR range defined in `vpn-instances.yaml`

## Goals

### Primary Goal
Allow VPN instances to claim domain names so that traffic to
those domains routes through the designated VPN tunnel
automatically — without manually tracking or configuring IPs.

### Secondary Goals
- Support wildcard subdomains (e.g., `*.company.com`)
- Automatically update routing when DNS records change
- Work alongside existing CIDR routing and split DNS
- Support all tunnel types (L2TP, WireGuard, OpenVPN, Netbird)

## User Stories

### 1. Domain-Based Routing Configuration

**As a** VPN user
**I want** to list domains in `vpn-instances.yaml` that should
route through a specific VPN instance
**So that** company services on public IPs are reachable through
the correct VPN tunnel without manually tracking IPs

**Acceptance Criteria**:
- [ ] `vpn-instances.yaml` supports a `route_domains` field per
  instance, accepting domain names and wildcards (e.g.,
  `company.com`, `*.company.com`)
- [ ] The generator validates `route_domains` entries and
  rejects duplicate domains across instances
- [ ] Example config updated in
  `secrets/vpn-instances.yaml.example`

### 2. Automatic Routing of Resolved IPs

**As a** VPN user
**I want** traffic to `route_domains` IPs to automatically go
through the designated VPN instance
**So that** I don't need to update configuration when DNS records
change

**Acceptance Criteria**:
- [ ] After DNS resolution of a `route_domains` entry, traffic
  to the resolved IP routes through the correct VPN instance
- [ ] When DNS records change (on TTL expiry), routing updates
  to reflect the new IP
- [ ] No manual intervention needed after initial configuration

### 3. Coexistence with Existing Features

**As a** VPN user
**I want** domain routing to work alongside CIDR routing and
split DNS
**So that** I can use all three mechanisms together per instance

**Acceptance Criteria**:
- [ ] `cidrs` continues to work unchanged for static routing
- [ ] `dns_domains` continues to work unchanged for split DNS
- [ ] An instance can have any combination of `cidrs`,
  `dns_domains`, and `route_domains`
- [ ] An instance can have only `route_domains` with no other
  fields
- [ ] Static CIDR routes take precedence over domain-resolved
  routes

## Requirements

### Functional Requirements

1. **FR-1**: New `route_domains` field in `vpn-instances.yaml`
   with domain names and wildcard support per instance
   - **Priority**: High

2. **FR-2**: Generator validates `route_domains` (no duplicates
   across instances, valid domain format) and includes them in
   `vpn-instances.json`
   - **Priority**: High

3. **FR-3**: Traffic to IPs resolved from `route_domains` routes
   through the designated VPN instance automatically
   - **Priority**: High

4. **FR-4**: Routing updates automatically when DNS records
   change, without restart or redeployment
   - **Priority**: High

5. **FR-5**: Domain routing coexists with CIDR routing — static
   routes take precedence
   - **Priority**: Medium

### Non-Functional Requirements

1. **NFR-1**: Routing applies on DNS resolution — no periodic
   polling delay
2. **NFR-2**: No impact on startup time for instances without
   `route_domains`
3. **NFR-3**: No Headscale or Tailscale changes required for
   public IP domain routing

### Technical Constraints

- dnsmasq runs in its own container on `bridge_vpn`, separate
  from the gluetun namespace where routing decisions are made
- Must coexist with gluetun's firewall rules and existing
  CIDR-based routing in route-init
- Current architecture is IPv4-only

## Out of Scope

- Routing private IPs discovered via DNS (use `cidrs` +
  `--advertise-routes` for those)
- Runtime domain management via bot commands (future feature)
- Per-domain TTL override
- IPv6 support
- Modifying Netbird's native domain routing

## Success Metrics

1. `curl git.company.com` from Mac via Tailscale exit node
   reaches the service through the company VPN instance (not
   Mullvad)
2. Changing the DNS A record for `git.company.com` to a new IP
   automatically updates routing within one TTL cycle
3. Existing CIDR routing and split DNS continue to work
   unchanged

## References

### From Codebase
- `dns/entrypoint.sh` — dnsmasq config generation
- `gluetun/init-routes.sh` — CIDR-based routing
- `generate-vpn.py` — config validation and generation
- `secrets/vpn-instances.yaml.example` — config schema

### From Past Features
- **005-CUSTOM-ROUTES Phase 3** — originally sketched DNS-based
  routing as a future feature
- **006-MULTI-INSTANCE-VPN** — established the per-instance
  routing architecture this feature extends

---

**Next Steps**:
1. Review and refine this PRD
2. Run `/dev:tech-design` to create technical design
3. Run `/dev:tasks` to break down into tasks
