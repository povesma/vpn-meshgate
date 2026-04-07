# 006-MULTI-INSTANCE-VPN: Multi-Instance VPN Routing - PRD

**Status**: Draft
**Created**: 2026-04-05
**Author**: Claude (via dev workflow analysis)

---

## Context

The current vpn-meshgate architecture supports exactly one company
VPN tunnel (L2TP/IPsec via `l2tp-vpn` container) and one internet
VPN tunnel (Mullvad WireGuard via `gluetun`). All company CIDRs
route through the single L2TP tunnel. This prevents connecting to
multiple corporate networks simultaneously — e.g., two different
companies or offices that each require their own VPN connection
with distinct credentials and tunnel types.

### Current State

- Single `l2tp-vpn` container on `bridge_vpn` at `172.29.0.20`
- Single `gluetun` container running Mullvad WireGuard
- `route-init` routes all `COMPANY_CIDRS` + `EXTRA_VPN_CIDRS` to
  the one L2TP container IP
- Configuration via flat `.env` file with `L2TP_SERVER`,
  `L2TP_USERNAME`, `L2TP_PASSWORD`, `L2TP_PSK`, `COMPANY_CIDRS`
- Only L2TP/IPsec tunnel type supported for company VPN
- Docker Compose services are statically defined

## Problem Statement

**Who**: VPN user connecting to multiple corporate networks
**What**: Cannot connect to more than one company VPN at a time;
cannot use WireGuard or OpenVPN for company connections
**Why**: Architecture is hardcoded for a single L2TP tunnel; no
mechanism to define multiple VPN instances with different types
**When**: When the user needs simultaneous access to resources on
multiple corporate networks with different VPN requirements

## Goals

### Primary Goal
Support N simultaneous company VPN tunnels, each with its own
tunnel type (L2TP/IPsec, WireGuard, OpenVPN, or Netbird),
credentials, and CIDR-based routing — configured via a
structured YAML file.

### Secondary Goals
- Replace the flat `.env`-based VPN config with a cleaner YAML
  config model
- Support WireGuard, OpenVPN, and Netbird as company tunnel
  types alongside L2TP/IPsec
- Maintain the existing Mullvad internet tunnel (gluetun) as the
  default route for non-company traffic

## User Stories

### 1. YAML-Based VPN Instance Configuration

**As a** VPN user
**I want** to define multiple VPN instances in a YAML config file
**So that** each instance has its own name, tunnel type,
credentials, and CIDRs

**Acceptance Criteria**:
- [ ] A `vpn-instances.yaml` file defines N VPN instances
- [ ] Each instance specifies: name, type (`l2tp`, `wireguard`,
  `openvpn`, `netbird`), server, credentials, and CIDRs
- [ ] Validation rejects duplicate names, overlapping CIDRs,
  and missing required fields
- [ ] Example config provided in `vpn-instances.yaml.example`

### 2. Dynamic Container Provisioning

**As a** VPN user
**I want** each VPN instance to run as its own container
**So that** tunnels are isolated and can be managed independently

**Acceptance Criteria**:
- [ ] Each VPN instance gets a unique container on `bridge_vpn`
  with a deterministic IP address
- [ ] L2TP instances use the existing `l2tp` image
- [ ] WireGuard instances use an appropriate WireGuard client
  image
- [ ] OpenVPN instances use an appropriate OpenVPN client image
  - [ ] Netbird instances use the official `netbirdio/netbird`
    image with a setup key
- [ ] Containers are generated from the YAML config (not
  manually defined in `docker-compose.yml`)
- [ ] Each container can be restarted independently without
  affecting others

### 3. CIDR-Based Multi-Instance Routing

**As a** VPN user
**I want** different CIDRs to route through different VPN
instances
**So that** each corporate network's traffic goes through its
designated tunnel

**Acceptance Criteria**:
- [ ] `route-init` reads the YAML config and creates routes
  per instance: each instance's CIDRs route to that instance's
  container IP
- [ ] Each VPN container routes its own CIDRs over its tunnel
  interface (ppp0, wg0, tun0, wt0)
- [ ] Gluetun firewall allows traffic to all instance container
  IPs
- [ ] Traffic to CIDRs not assigned to any instance continues
  through Mullvad (default route)

### 4. Health Monitoring Per Instance

**As a** VPN user
**I want** each VPN instance health-checked independently
**So that** I get alerts when a specific tunnel goes down

**Acceptance Criteria**:
- [ ] Each instance can optionally define a `check_ip` for
  health verification
- [ ] Healthcheck reports per-instance status
- [ ] ntfy alerts identify which instance is down

### 5. Bot Integration

**As a** VPN user
**I want** bot commands to manage individual VPN instances
**So that** I can check status, restart, or disable specific
tunnels

**Acceptance Criteria**:
- [ ] `status` command shows per-instance tunnel status
- [ ] `restart <instance-name>` restarts a specific VPN tunnel
- [ ] `disable <instance-name>` stops a specific tunnel

## Requirements

### Functional Requirements

1. **FR-1**: YAML config file (`vpn-instances.yaml`) parsed at
   startup to define N VPN instances
   - **Priority**: High

2. **FR-2**: Container generation from YAML — one container per
   VPN instance with correct image, env vars, and network config
   - **Priority**: High

3. **FR-3**: Per-instance CIDR routing in route-init and per
   container
   - **Priority**: High

4. **FR-4**: Support for L2TP/IPsec, WireGuard, OpenVPN, and
   Netbird tunnel types
   - **Priority**: High (L2TP), Medium (WireGuard), Medium
     (OpenVPN), Medium (Netbird)

5. **FR-5**: Per-instance health monitoring and ntfy alerts
   - **Priority**: Medium

6. **FR-6**: Bot commands for per-instance management
   - **Priority**: Medium

### Non-Functional Requirements

1. **NFR-1**: Startup time scales linearly with number of
   instances (no exponential waits)
2. **NFR-2**: One instance failure must not affect other
   instances or the Mullvad tunnel
3. **NFR-3**: Config validation at startup — fail fast with
   clear error messages

### Technical Constraints

- `bridge_vpn` subnet `172.29.0.0/24` limits total containers
  to ~250 (plenty for VPN instances)
- gluetun shared namespace architecture must be preserved for
  Tailscale exit node functionality
- Each VPN container needs `privileged: true` or `CAP_NET_ADMIN`
  for tunnel creation
- Docker Compose does not natively support dynamic service
  generation — need a wrapper script or template approach

## Out of Scope

- Multiple Mullvad instances (gluetun stays single-instance)
- Per-instance Mullvad country selection (covered by
  002-MULLVAD-COUNTRY-SWITCH)
- DNS-based routing to specific instances (future, builds on
  005-CUSTOM-ROUTES Phase 3)
- Web UI for configuration
- Hot-reloading config without restart (nice-to-have for later)

## Success Metrics

1. Two company VPN instances running simultaneously with
   different CIDRs routing through correct tunnels
2. `traceroute` from Mac confirms traffic to each CIDR set
   exits through the designated tunnel
3. Restarting one instance does not disrupt the other

## References

### From Codebase
- `docker-compose.yml` — current static service definitions
- `l2tp/entrypoint.sh` — L2TP tunnel setup (template for
  multi-type support)
- `gluetun/init-routes.sh` — routing loop (needs multi-instance
  routing)
- `healthcheck/check.sh` — health monitoring (needs
  per-instance checks)
- `bot/bot.sh` — bot commands (needs per-instance management)
- `.env.example` — current flat config (to be replaced by YAML)

---

**Next Steps**:
1. Review and refine this PRD
2. Run `/dev:tech-design` to create technical design
3. Run `/dev:tasks` to break down into tasks
