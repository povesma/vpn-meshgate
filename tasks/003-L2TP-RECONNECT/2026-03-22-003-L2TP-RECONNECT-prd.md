# 003-L2TP-RECONNECT: L2TP Auto-Reconnect with ntfy Notifications — PRD

**Status**: Complete
**Created**: 2026-03-22
**Author**: Claude (via dev workflow analysis)

---

## Context

The L2TP/IPsec tunnel to the company network silently dies when the remote
peer terminates the connection (typically after ~3.5 hours of inactivity with
a "Link inactive" LCP TermReq). The container stays running but unhealthy —
`ppp0` disappears, company subnet routing breaks, and no one is notified.
Recovery requires manual `docker restart l2tp-vpn`.

### Current State

- `l2tp/entrypoint.sh` runs a linear startup sequence: configure strongSwan
  IPsec → start xl2tpd → connect L2TP → wait for ppp0 → add routes →
  `sleep infinity`. No reconnection logic exists.
- strongSwan DPD is configured (`dpdaction=restart`) but does not recover
  from peer-initiated "Link inactive" terminations — the xl2tpd/PPP layer
  terminates cleanly and the entrypoint is already past the connection stage.
- Docker healthcheck (`ip link show ppp0`) detects the failure and marks
  the container unhealthy, but `restart: unless-stopped` only restarts on
  container exit — not on unhealthy status.
- `healthcheck/check.sh` (running in gluetun's namespace) monitors L2TP
  via `ping` to `L2TP_CHECK_IP` and detects down/recovery transitions, but
  its ntfy notifications often fail because the healthcheck container starts
  before ntfy is fully ready.
- `bot/bot.sh` supports `restart company` command for manual recovery but
  there is no automatic trigger.

### Observed Failure (2026-03-21)

```
L2TP peer at 194.154.196.34 sent LCP TermReq "Link inactive" after 211.6 min.
ppp0 disappeared. Container stayed "Up (unhealthy)" for 4+ hours.
Company subnet 10.11.0.0/16 unreachable. No notification sent.
Manual docker restart l2tp-vpn recovered in 22 seconds.
```

---

## Problem Statement

**Who**: Developer using the VPS as a Tailscale exit node for company access
**What**: L2TP tunnel silently dies, cutting off company network access
**Why**: No reconnection logic; no notifications; container sits unhealthy
**When**: After ~3.5 hours of low activity, or any peer-initiated disconnect

---

## Goals

### Primary Goal
Automatically reconnect the L2TP tunnel when it drops, with ntfy
notifications on disconnect and recovery events.

### Secondary Goals
- Minimize company network downtime to under 60 seconds per disconnect
- Avoid unnecessary reconnection loops if the remote peer is genuinely
  unreachable (backoff)
- Preserve the existing container architecture (no new containers needed)

---

## User Stories

### Epic
As a developer, I want the L2TP tunnel to automatically reconnect when it
drops so that company network access recovers without manual intervention.

### User Story 1 — Auto-Reconnect
**As a** developer using the VPS for company access
**I want** the L2TP container to detect when ppp0 drops and re-establish the
connection automatically
**So that** company network access recovers without SSH or bot commands

**Acceptance Criteria**:
- [ ] When ppp0 disappears, the entrypoint detects it within 15 seconds
- [ ] A full reconnection cycle (IPsec SA + xl2tpd + ppp0 + routes) is
  attempted automatically
- [ ] On successful reconnection, company IPs are reachable again
- [ ] The container remains running throughout (no exit/restart needed)

### User Story 2 — Disconnect Notification
**As a** developer
**I want** to receive an ntfy notification when the L2TP tunnel drops
**So that** I'm aware of connectivity issues even if auto-reconnect succeeds

**Acceptance Criteria**:
- [ ] An ntfy message is sent when ppp0 drops: "Company VPN disconnected.
  Reconnecting..."
- [ ] The notification includes the disconnect reason if available
  (e.g., "Link inactive")
- [ ] Notifications go to the `vpn-alerts` topic (same as healthcheck)

### User Story 3 — Recovery Notification
**As a** developer
**I want** an ntfy notification when the tunnel successfully reconnects
**So that** I know company access is restored

**Acceptance Criteria**:
- [ ] An ntfy message is sent on successful reconnection: "Company VPN
  reconnected. IP: {ppp0_ip}"
- [ ] The notification includes the time the tunnel was down

### User Story 4 — Backoff on Persistent Failure
**As a** developer
**I want** the reconnection logic to back off if the peer is unreachable
**So that** the container doesn't spam reconnection attempts or notifications

**Acceptance Criteria**:
- [ ] After a failed reconnection, wait before retrying (exponential backoff:
  15s, 30s, 60s, 120s, max 300s)
- [ ] After 3 consecutive failures, send one "Company VPN: reconnection
  failing" ntfy notification (not one per attempt)
- [ ] On successful reconnection after failures, reset the backoff timer
- [ ] Backoff state is not persisted across container restarts

---

## Functional Requirements

1. **FR-1**: Monitor ppp0 interface liveness
   - Priority: High
   - Check `ip link show ppp0` every 10 seconds in a loop after initial
     connection succeeds
   - Detect both interface disappearance and IP loss

2. **FR-2**: Full reconnection sequence
   - Priority: High
   - On ppp0 loss: tear down stale xl2tpd/IPsec state, re-establish IPsec SA,
     restart xl2tpd, reconnect L2TP, wait for ppp0, re-add routes, re-add
     iptables MASQUERADE
   - Reuse the same logic as the initial connection in entrypoint.sh

3. **FR-3**: ntfy notifications from L2TP container
   - Priority: High
   - The L2TP container runs on `bridge_vpn` (172.29.0.20), not in gluetun's
     namespace. It can reach ntfy at `172.29.0.10:80` (via gluetun's bridge IP)
     only when gluetun and ntfy are healthy
   - Notification failures should be logged but not block reconnection

4. **FR-4**: Exponential backoff
   - Priority: Medium
   - Prevents tight reconnection loops when the peer is down
   - Resets on success

5. **FR-5**: Downtime tracking
   - Priority: Low
   - Record the timestamp when ppp0 drops, report duration on recovery

---

## Non-Functional Requirements

1. **NFR-1 — Recovery time**: Successful reconnection within 60 seconds of
   detecting ppp0 loss (assuming peer is reachable)
2. **NFR-2 — No container restart**: The reconnection loop runs inside the
   existing container process — no Docker restart needed
3. **NFR-3 — Idempotent cleanup**: Stale IPsec SAs and xl2tpd state must be
   fully cleaned before each reconnection attempt
4. **NFR-4 — No new containers**: All changes are within `l2tp/entrypoint.sh`

---

## Technical Constraints

- L2TP container is on `bridge_vpn` (172.29.0.20), not in gluetun's namespace
- ntfy is accessible at `172.29.0.10:80` but only when gluetun+ntfy are healthy
- strongSwan (`ipsec`) and `xl2tpd` must be properly torn down before
  reconnection — stale state causes "SA already exists" errors
- The `/shared/company-dns-ip` file (consumed by dnsmasq) must be re-written
  on reconnection if the DNS IP changes
- The `ip-up` PPP script writes DNS info — this must continue to work across
  reconnections

---

## Out of Scope

- Changing the L2TP container to run in gluetun's namespace
- Adding a separate watchdog/sidecar container for L2TP monitoring
- Modifying the remote L2TP peer's idle timeout settings
- Sending keepalive traffic to prevent idle disconnects (considered but
  unreliable — peer may disconnect for other reasons)
- Bot command to configure reconnection behavior

---

## Success Metrics

1. **Auto-recovery**: L2TP tunnel recovers automatically after peer disconnect
   within 60 seconds (no manual intervention)
2. **Notification delivery**: ntfy notifications sent on disconnect and
   recovery events
3. **Stability**: No reconnection loops or excessive resource usage during
   extended peer outages (backoff working)
4. **Uptime**: Company network downtime per disconnect event < 60 seconds

---

## References

### From Codebase
- `l2tp/entrypoint.sh` — current linear startup, needs reconnection loop
- `l2tp/Dockerfile` — Alpine + strongswan + xl2tpd + ppp + curl (curl
  already available for ntfy)
- `healthcheck/check.sh` — existing L2TP monitoring (ping-based, runs in
  gluetun namespace)
- `docker-compose.yml` — l2tp-vpn on bridge_vpn:172.29.0.20, healthcheck
  via `ip link show ppp0`

### From History (claude-mem)
- #5769: L2TP connection terminated by peer after 211.6 min ("Link inactive")
- #5772: Entrypoint architecture — DPD configured but doesn't recover from
  peer termination
- #5773: Manual container restart recovered in 22 seconds

---

**Next Steps**:
1. Review and refine this PRD
2. Run `/dev:tech-design` to design the reconnection loop
3. Run `/dev:tasks` to break down into implementation tasks
