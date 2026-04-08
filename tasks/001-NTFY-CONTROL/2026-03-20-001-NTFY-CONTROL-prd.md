# 001-NTFY-CONTROL: VPN Remote Control via ntfy - PRD

**Status**: Complete
**Created**: 2026-03-20

---

## Introduction/Overview

A command listener that subscribes to a dedicated ntfy topic and
executes VPN management commands sent from the user's phone. The
user types commands like `status`, `ping`, or `restart company`
in the ntfy app, and receives responses as notifications.

### Problem Statement

When the VPN stack has issues (L2TP tunnel drops, Mullvad needs
a restart), the only way to manage it is via SSH to the VPS.
This is inconvenient from a phone and impossible if the VPN
itself is down and blocking SSH access through the exit node.

### Value Proposition

Turn the existing ntfy app into a two-way remote control for
the VPN stack. No additional apps, no SSH — just type a command
in the same app that already shows VPN alerts.

## Objectives & Success Metrics

**Objectives:**
- Enable basic VPN management from the phone via ntfy messages
- Provide instant VPN status visibility without SSH
- Allow safe restart of VPN tunnels remotely

**Success Metrics:**
- `status` command returns accurate state within 5 seconds
- `restart company` recovers L2TP tunnel without manual SSH
- `restart mullvad` recovers Mullvad tunnel with confirmation
  safeguard (acknowledging ~30s full connectivity loss)

## User Personas & Use Cases

### User Persona

**Privacy-Conscious Developer** (same as VPN-001):
Uses macOS for work, manages VPN stack on a remote VPS. Has
the ntfy app installed on Android phone with `vpn-alerts`
topic already subscribed.

### Use Cases

1. **Quick status check**: Developer gets a "Company VPN DOWN"
   alert. Sends `status` to see full picture before deciding
   whether to act.

2. **Remote restart**: L2TP tunnel dropped. Developer sends
   `restart company` from phone. Tunnel reconnects. No laptop
   needed.

3. **Mullvad recovery**: Mullvad tunnel is stuck. Developer
   sends `restart mullvad`, receives confirmation warning about
   30s downtime, sends `confirm`, and gluetun restarts.

4. **Liveness check**: Developer hasn't received alerts in a
   while and wants to verify the system is alive. Sends `ping`,
   gets `pong` back.

5. **DNS troubleshooting**: Developer suspects DNS issues.
   Sends `dns test` and gets split DNS resolution results.

## Feature Scope

### In Scope

- New `vpn-bot` container in gluetun's network namespace
- Subscribes to a dedicated command topic (separate from
  alerts) via ntfy JSON streaming API
- Responds to commands by publishing to the alerts topic
- Commands:
  - `ping` — replies with `pong` and uptime
  - `status` — reports state of Mullvad and Company VPNs
    with named labels (not container names)
  - `ip` — shows current public exit IP
  - `restart company` — restarts l2tp-vpn container
  - `restart mullvad` — requires confirmation, restarts
    gluetun and all namespace-dependent containers
  - `dns test` — tests split DNS resolution
  - `help` — lists available commands
- Rate limiting: ignore duplicate commands within 60 seconds
- Confirmation flow for destructive commands (`restart mullvad`)

### Out of Scope

- Authentication / shared secret (tailnet isolation is
  sufficient — ntfy is only reachable from Tailscale peers,
  not from Mullvad or Company VPN networks)
- Web UI or dashboard
- Automated remediation (auto-restart on failure)
- Custom notification priorities from commands
- Multi-user support

### Future Considerations

- `mute 1h` / `unmute` — suppress alert notifications
- `switch mullvad <country>` — change Mullvad exit country
- `logs <service>` — tail recent logs from a container

## Functional Requirements

### Detailed Requirements

1. **REQ-01 Command Topic**: The vpn-bot subscribes to a
   dedicated ntfy topic (`vpn-cmd` by default, configurable
   via `NTFY_CMD_TOPIC` env var) using the JSON streaming API
   (`/vpn-cmd/json`). This is separate from the alerts topic.

2. **REQ-02 Response Topic**: All command responses are
   published to the existing alerts topic (`NTFY_TOPIC`,
   default `vpn-alerts`). The user sees commands and responses
   in different topics — commands in `vpn-cmd`, responses in
   `vpn-alerts`.

3. **REQ-03 Command: ping**: Replies with `pong` and system
   uptime. Priority: default (3).

4. **REQ-04 Command: status**: Reports:
   - Mullvad VPN: UP/DOWN + current exit IP
   - Company VPN: UP/DOWN + L2TP check IP reachability
   - Container uptime
   Priority: default (3).

5. **REQ-05 Command: ip**: Returns the current public IP as
   seen by `ifconfig.me`. Priority: default (3).

6. **REQ-06 Command: restart company**: Restarts the l2tp-vpn
   container via Docker socket or `docker` CLI. Responds with
   status before and after restart. Priority: high (4).

7. **REQ-07 Command: restart mullvad**: Dangerous — restarts
   gluetun which kills all namespace-dependent containers
   (tailscale, ntfy, vpn-bot itself) for ~30s. Flow:
   1. User sends `restart mullvad`
   2. Bot replies: "This will restart Mullvad and cause ~30s
      total connectivity loss. Send `confirm` within 30s."
   3. User sends `confirm` within 30s → bot initiates restart
   4. If no `confirm` within 30s → bot replies "Cancelled"
   Priority: urgent (5) for the warning.

8. **REQ-08 Command: dns test**: Resolves a company domain and
   a public domain, reports which DNS server answered each.
   Priority: default (3).

9. **REQ-09 Command: help**: Lists all available commands with
   brief descriptions. Priority: low (2).

10. **REQ-10 Rate Limiting**: Ignore duplicate identical
    commands received within 60 seconds. Respond with
    "Command already processed, please wait" if repeated.

11. **REQ-11 Unknown Commands**: Reply with "Unknown command:
    {input}. Send `help` for available commands."
    Priority: default (3).

12. **REQ-12 Container Restart Mechanism**: The vpn-bot needs
    the ability to restart other containers. Options:
    - Mount Docker socket (`/var/run/docker.sock`)
    - Use `docker` CLI via the host
    This requires the vpn-bot container to have Docker socket
    access. Acceptable since the container is only reachable
    via the private tailnet.

## Non-Functional Requirements

### Security

- **Tailnet isolation**: ntfy (and thus the command topic) is
  only reachable from Tailscale peers. Not accessible from:
  - The public internet (no ports exposed on VPS public IP)
  - Mullvad VPN tunnel (traffic goes outbound only)
  - Company VPN network (L2TP is a separate namespace)
- **No authentication needed**: The tailnet IS the auth
  boundary. Only devices on the user's Headscale network can
  reach ntfy.
- **Docker socket access**: vpn-bot needs Docker socket to
  restart containers. This is a privileged operation but
  acceptable given the single-user, private tailnet context.

### Reliability

- vpn-bot must reconnect to the ntfy JSON stream if the
  connection drops (ntfy sends keepalive events)
- After gluetun restart (which kills vpn-bot), vpn-bot must
  auto-restart and resubscribe
- `restart: unless-stopped` on the container

### Performance

- Command response time: < 5 seconds for non-restart commands
- Restart commands: response before restart is immediate,
  post-restart confirmation after container recovery

## Architecture

### Container: vpn-bot

- **Image**: Custom Alpine + curl + docker CLI
- **Network**: `network_mode: service:gluetun` (shares
  namespace with ntfy, tailscale, healthcheck)
- **Volumes**: Docker socket mount for container management
- **Dependencies**: gluetun (healthy), ntfy (healthy)

### Communication Flow

```
Phone (ntfy app)
  │
  ├── publishes to: vpn-cmd topic
  │         │
  │         ▼
  │    vpn-bot (subscribes via JSON stream)
  │         │
  │         ├── executes command
  │         │
  │         ▼
  │    vpn-bot publishes response to: vpn-alerts topic
  │         │
  └─────────┘ (phone receives response as notification)
```

### Topic Separation

| Topic | Direction | Purpose |
|-------|-----------|---------|
| `vpn-cmd` | Phone → Bot | Commands |
| `vpn-alerts` | Bot → Phone | Responses + health alerts |

The user subscribes to both topics in the ntfy app.

## Dependencies & Risks

### Dependencies

- Docker socket access from within a container
- ntfy JSON streaming API stability
- Existing healthcheck container (for shared monitoring logic
  patterns)

### Risks

1. **Risk: gluetun restart kills vpn-bot**: After `restart
   mullvad`, vpn-bot dies along with everything else. Docker's
   `restart: unless-stopped` brings it back, but the
   confirmation response ("Mullvad restarted successfully")
   cannot be sent until ntfy is also back.
   *Mitigation*: Send "Initiating restart now..." before the
   restart. Post-restart status is sent once vpn-bot recovers.

2. **Risk: Docker socket is powerful**: Mounting the Docker
   socket gives the container full Docker API access, not just
   restart.
   *Mitigation*: The bot script only calls specific `docker
   restart` commands. Tailnet isolation prevents unauthorized
   access. Acceptable for a single-user private setup.

3. **Risk: Command injection via ntfy messages**: A crafted
   message could attempt shell injection if commands are
   passed unsafely to shell.
   *Mitigation*: Whitelist-based command parsing. Only exact
   string matches trigger actions. No shell interpolation of
   user input.

## Resolved Questions

1. **Authentication**: Not needed. Tailnet isolation is the
   auth boundary. ntfy is not reachable from Mullvad or
   Company VPN traffic — only from Tailscale peers.
2. **Separate container vs extend healthcheck**: New container
   (`vpn-bot`). Cleaner separation of concerns.
3. **Restart mullvad safety**: Allowed with confirmation flow
   (30s timeout).

## Open Questions

None — ready for tech design.
