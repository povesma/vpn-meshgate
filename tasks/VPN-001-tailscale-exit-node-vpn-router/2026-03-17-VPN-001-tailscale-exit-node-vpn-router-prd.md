# Tailscale Exit Node VPN Router - Product Requirements Document

## Introduction/Overview

A self-hosted Docker Compose stack that runs on a Linux VPS and
acts as a Tailscale exit node with policy-based routing. When a
macOS client selects this node as its Tailscale exit node, traffic
is automatically split:

- **Company traffic** (CIDRs from `COMPANY_CIDRS` env var,
  e.g. `10.11.0.0/16,10.12.0.0/16`) routes through an L2TP/
  IPsec VPN tunnel to the corporate network.
- **All other traffic** routes through a Mullvad WireGuard tunnel
  for privacy.

The user stays connected to a single Tailscale network (via
Headscale) at all times. No manual VPN switching is needed.

### Problem Statement

Running multiple VPNs simultaneously on macOS is unreliable.
Mullvad and Tailscale fight over the default route, and adding
a corporate L2TP VPN makes things worse. Switching VPNs manually
is inconvenient and creates privacy gaps during transitions.

### Value Proposition

Move all VPN complexity to a server-side Docker stack. The Mac
only runs Tailscale. One click to enable the exit node; policy
routing inside containers handles the rest. The host VPS
networking and routing tables are never modified.

## Objectives & Success Metrics

**Business Objectives:**
- Eliminate manual VPN switching on the client machine
- Maintain 100% privacy coverage (all non-company traffic
  through Mullvad) without interruption
- Provide seamless access to company resources (`COMPANY_CIDRS`)
  without disabling the privacy VPN

**Success Metrics:**
- **Privacy**: `curl ifconfig.me` from the Mac always shows a
  Mullvad exit IP (not the VPS or real IP)
- **Company access**: Resources on `COMPANY_CIDRS` are reachable
  when exit node is active
- **Uptime**: VPN stack recovers automatically after container
  restart or VPS reboot
- **Failover visibility**: User is notified within 60 seconds
  if Mullvad tunnel goes down via ntfy push notification

## User Personas & Use Cases

### User Personas

**Privacy-Conscious Developer** (primary & only persona):
- **Characteristics**: Uses macOS daily for work. Runs own
  Headscale server. Has a Linux VPS. Comfortable with Docker
  and CLI tools.
- **Needs**: Always-on privacy VPN, seamless company network
  access, zero manual VPN juggling.
- **Goals**: Connect once to Tailscale, forget about VPN
  management. All routing decisions happen server-side.

### User Stories

- As a developer, I want to select the VPS as my Tailscale
  exit node so that all my traffic is routed through the
  appropriate VPN automatically.
- As a developer, I want company-bound traffic to reach
  `COMPANY_CIDRS` through the corporate L2TP/IPsec VPN so
  that I can access internal resources without switching VPNs.
- As a developer, I want all non-company traffic to go through
  Mullvad so that my browsing remains private at all times.
- As a developer, I want to be notified if the Mullvad tunnel
  goes down so that I can decide whether to continue without
  privacy or disconnect.
- As a developer, I want the stack to survive VPS reboots and
  container restarts without manual intervention.

### Use Cases

1. **Daily work**: Developer connects Mac to Tailscale (always
   on). Selects VPS exit node. Browses the web (via Mullvad),
   accesses company Jira/GitLab (via L2TP), and manages
   Tailscale nodes (via mesh) — all simultaneously.
2. **Mullvad failure**: Mullvad tunnel drops. Traffic falls
   back to direct VPS internet. A health check detects the
   failure and sends a push notification via ntfy. Developer
   sees it on phone/desktop and can choose to disconnect the
   exit node or wait for recovery.
3. **VPS reboot**: All containers restart automatically.
   Tailscale re-registers as exit node. VPN tunnels
   re-establish. No manual action needed.

## Feature Scope

### In Scope

- Docker Compose stack with:
  - Tailscale container (exit node, connected to Headscale)
  - Mullvad WireGuard container (using gluetun for kill switch
    and provider support)
  - L2TP/IPsec client container (company VPN)
- Policy-based routing inside containers (iptables/nftables):
  - `COMPANY_CIDRS` -> company L2TP tunnel
  - `0.0.0.0/0` (default) -> Mullvad WireGuard tunnel
  - Host VPS networking/routing is never modified
- DNS split routing:
  - Company DNS (obtained via PPP from L2TP connection) for
    company domains (suffix from `COMPANY_DOMAIN` env var)
  - Mullvad/DoT DNS for everything else
- Health monitoring & notifications:
  - Periodic health checks on both VPN tunnels
  - ntfy container for push notifications (self-hosted,
    zero-config, works on phone and desktop via `curl`)
  - Notification on VPN tunnel failure within 60 seconds
- Failover: if Mullvad is down, kill switch blocks traffic
  (fail-closed) with ntfy alert to user
- Auto-restart and recovery after VPS reboot
- Configuration via `.env` file and config templates
  - `.env` is a secrets file — never read, written, or
    accessed by automation tools. Only its expected variable
    names are documented in `.env.example`.

### Out of Scope

- Web UI for management (future phase)
- Mullvad exit node selection UI (future phase)
- Multiple company VPN profiles
- iOS/Android client configuration
- VPS provisioning (Ansible/Terraform)
- Automated Mullvad account management
- High-availability / multi-VPS setups

### Future Considerations

- Web UI to select Mullvad exit node (server/country)
- Dashboard showing current routing status and VPN health
- Support for additional VPN providers
- Automated Mullvad WireGuard key rotation

## Functional Requirements

### Cucumber/Gherkin Scenarios

```gherkin
Feature: VPN Traffic Routing

  Scenario: All internet traffic routes through Mullvad
    Given the Docker stack is running
    And the Mullvad WireGuard tunnel is established
    When the Mac uses the VPS as Tailscale exit node
    And the Mac makes a request to ifconfig.me
    Then the response shows a Mullvad exit IP
    And the response does not show the VPS public IP

  Scenario: Company traffic routes through L2TP VPN
    Given the Docker stack is running
    And the L2TP/IPsec tunnel is established
    When the Mac uses the VPS as Tailscale exit node
    And the Mac makes a request to 10.11.0.1
    Then the request is routed through the L2TP tunnel
    And the request reaches the company network

  Scenario: Mullvad tunnel failure (fail-closed)
    Given the Docker stack is running
    And the Mullvad WireGuard tunnel goes down
    When the Mac makes a request to an external site
    Then the request is blocked by the kill switch
    And a push notification is sent via ntfy within 60 seconds
    And the notification includes tunnel name and failure reason

  Scenario: Stack recovery after VPS reboot
    Given the Docker stack was running
    When the VPS reboots
    Then all containers restart automatically
    And the Tailscale exit node re-registers
    And both VPN tunnels re-establish
    And traffic routing resumes correctly

  Scenario: DNS queries are split correctly
    Given the Docker stack is running
    When the Mac resolves a company domain
    Then the DNS query goes to the company DNS server
    When the Mac resolves a public domain
    Then the DNS query goes through Mullvad DNS
```

### Detailed Requirements

1. **REQ-01 Tailscale Exit Node**: The Tailscale container
   must register as an exit node with the Headscale server
   and advertise the `0.0.0.0/0` route (IPv4 only).

2. **REQ-02 Mullvad WireGuard Tunnel**: The Mullvad container
   (gluetun) must establish a WireGuard tunnel using
   downloaded config files and the user's account number.

3. **REQ-03 L2TP/IPsec Tunnel**: The L2TP container must
   connect to the company VPN using server address, username,
   password, and shared secret (all from `.env`).

4. **REQ-04 Policy Routing**: The system must route packets
   by destination, entirely within container networking (no
   host routing table modifications):
   - `COMPANY_CIDRS` via L2TP tunnel interface
   - All other traffic via Mullvad WireGuard interface

5. **REQ-05 DNS Split**: DNS queries for company domains
   (matching `COMPANY_DOMAIN` suffix) must go to the company
   DNS server (obtained via PPP from the L2TP connection).
   All other DNS queries must use Mullvad-provided DNS or
   DNS-over-TLS.

6. **REQ-06 Failover**: If the Mullvad tunnel drops, the
   kill switch blocks all internet traffic (fail-closed).
   The healthcheck detects this and sends an ntfy alert.
   The user can then disconnect the exit node from their
   Mac to restore direct internet. Fail-open mode is a
   future consideration.

7. **REQ-07 Health Monitoring**: A health check container
   must verify both tunnels are active every 30 seconds. On
   failure, it must send a push notification via ntfy
   (self-hosted ntfy instance running as part of the stack).

8. **REQ-08 Notifications**: An ntfy container runs as part
   of the Docker Compose stack. The health checker sends
   alerts to it via simple HTTP POST (`curl`). The user
   subscribes to the ntfy topic from their phone or desktop.
   No external services, webhooks, or email required.

9. **REQ-09 Auto-Recovery**: All containers must have
   `restart: unless-stopped`. Tailscale state must persist
   across restarts. VPN tunnels must auto-reconnect.

10. **REQ-10 Configuration**: All secrets and settings must
    live in a `.env` file. No hardcoded credentials in
    Docker Compose or scripts. The `.env` file is strictly
    private and must never be read or accessed by automation
    tools. An `.env.example` documents expected variables.

11. **REQ-11 Tailscale Mesh**: Traffic between Tailscale
    nodes (100.64.0.0/10) must continue to use the Tailscale
    mesh directly. The exit node must not interfere with
    node-to-node Tailscale communication.

12. **REQ-12 Container Isolation**: All routing and
    networking configuration must happen inside containers
    using Docker networks and container-level iptables. The
    host VPS networking stack, routing tables, and firewall
    rules must not be modified by the stack.

## Non-Functional Requirements

### Performance

- **Latency overhead**: Exit node routing should add < 10ms
  beyond the inherent VPS latency
- **Throughput**: Must support at least 100 Mbps through the
  Mullvad tunnel (depends on VPS network)

### Security

- **No credential leakage**: All secrets in `.env`, never in
  Docker images or committed to git. `.env` is never read
  by automation tools — only `.env.example` is managed
- **Kill switch**: If Mullvad drops, all internet traffic is
  blocked (fail-closed). No privacy leaks possible.
- **DNS leak prevention**: DNS must always go through the
  appropriate tunnel, never the VPS's default resolver

### Reliability

- **Auto-restart**: All containers use `restart: unless-stopped`
- **State persistence**: Tailscale state dir mounted as volume
- **Tunnel reconnection**: Both VPN clients must auto-reconnect
  on transient failures

### Architecture

- **Simplicity first**: Minimal number of containers, minimal
  custom code. Prefer well-maintained community Docker images
  (gluetun, official tailscale, existing L2TP clients).
- **Container-only networking**: All routing via iptables/
  nftables and iproute2 inside containers. No host-level
  routing changes. No custom networking daemons.
- **Configuration over code**: Routing rules in shell scripts
  or container entrypoints, not compiled binaries.

## Dependencies & Risks

### Dependencies

- **External Services**:
  - Headscale server (user-operated, already running)
  - Mullvad VPN (account required, WireGuard configs)
  - Company L2TP/IPsec VPN server
- **Docker Images**:
  - `tailscale/tailscale` (official)
  - `qmcgaw/gluetun` (Mullvad WireGuard client)
  - L2TP/IPsec client image (e.g.,
    `ubergarm/l2tp-ipsec-vpn-client` or similar)
  - `binwiederhier/ntfy` (push notifications)
- **VPS Requirements**:
  - Linux with Docker and Docker Compose
  - Kernel support for WireGuard, L2TP, IPsec
  - IP forwarding enabled (sysctl, only kernel param)
  - NET_ADMIN capability for containers

### Risks

- **Risk 1: L2TP/IPsec client Docker images may be
  unmaintained** — L2TP is legacy; fewer maintained images
  exist.
  *Mitigation*: Evaluate multiple images during tech design.
  Fall back to a custom Alpine container with strongSwan +
  xl2tpd if needed.

- **Risk 2: Policy routing complexity** — iptables rules for
  split routing inside container namespaces can be tricky to
  get right without touching host networking.
  *Mitigation*: Start with the simplest routing setup. Test
  each route independently before combining. Use Docker
  networks for inter-container communication.

- **Risk 3: Mullvad WireGuard key management** — Keys may
  need rotation; Mullvad may change their API.
  *Mitigation*: Use gluetun which handles Mullvad specifics.
  Document manual key rotation process.

- **Risk 4: DNS leak** — Misconfigured DNS could bypass VPN
  tunnels and leak queries to VPS resolver.
  *Mitigation*: Explicit DNS configuration in each container.
  Test with `dig` and DNS leak test sites.

- **Risk 5: Company VPN auth changes** — If the company
  switches from L2TP/IPsec or adds MFA, the setup breaks.
  *Mitigation*: Document the VPN type dependency. L2TP with
  PSK+password is stable for now; flag if company announces
  changes.

## Resolved Questions

1. **Company DNS server IP**: Obtained dynamically via PPP
   from the L2TP connection. No static IP needed.
2. **Company DNS domain suffix**: Configured via
   `COMPANY_DOMAIN` environment variable in `.env`.
3. **Notification mechanism**: ntfy (self-hosted, part of
   the Docker Compose stack). Push notifications to phone/
   desktop. No external services needed.
4. **Mullvad server preference**: Turkey (default). Server
   selection configurable via `MULLVAD_COUNTRY` env var.
5. **IPv6**: IPv4 only for initial version.

## Open Questions

None — all questions resolved. Ready for tech design.

