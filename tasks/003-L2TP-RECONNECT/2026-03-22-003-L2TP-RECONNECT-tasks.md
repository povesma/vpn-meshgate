# L2TP Auto-Reconnect — Task List

## Relevant Files

- [tasks/003-L2TP-RECONNECT/2026-03-22-003-L2TP-RECONNECT-prd.md](tasks/003-L2TP-RECONNECT/2026-03-22-003-L2TP-RECONNECT-prd.md) :: PRD
- [tasks/003-L2TP-RECONNECT/2026-03-22-003-L2TP-RECONNECT-tech-design.md](tasks/003-L2TP-RECONNECT/2026-03-22-003-L2TP-RECONNECT-tech-design.md) :: Technical Design
- [l2tp/entrypoint.sh](l2tp/entrypoint.sh) :: Main file to modify — add reconnection loop
- [docker-compose.yml](docker-compose.yml) :: Add NTFY_TOPIC env var to l2tp-vpn service

## Notes

- TDD is not applicable — shell script tested by manual verification
  on the live VPS.
- The reconnection loop replaces `sleep infinity` at the end of the
  entrypoint. Configuration (IPsec, xl2tpd, PPP) stays as a one-time
  setup phase at the top.
- ntfy notifications are best-effort — failures must not block
  reconnection.
- After changes: `deploy-push.sh` then
  `rdocker.sh compose up -d --build --force-recreate l2tp-vpn`.
- To test reconnection without waiting for peer timeout, use
  `rdocker.sh exec l2tp-vpn ip link delete ppp0` to simulate
  disconnect.

## Tasks

- [X] 1.0 **User Story:** As a developer, I want the entrypoint
  refactored into configure + connect functions so that the
  connection logic can be re-invoked on disconnect [3/0]
  - [X] 1.1 Extract the config-writing block (lines 11–62) into a
    `configure()` function. This runs once at startup: writes
    `/etc/ipsec.conf`, `/etc/ipsec.secrets`, `/etc/xl2tpd/xl2tpd.conf`,
    `/etc/ppp/options.l2tpd.client`, and `/etc/ppp/ip-up`.
  - [X] 1.2 Extract the connection sequence (lines 74–107) into a
    `connect()` function that returns 0 on success (ppp0 got IP)
    or 1 on failure. Includes: `ipsec up`, `xl2tpd -D &`,
    `echo "c company"`, and the ppp0 wait loop.
  - [X] 1.3 Extract the post-connect setup (lines 109–157) into a
    `setup_routing()` function: DNS extraction, route addition,
    iptables MASQUERADE. Returns the ppp0 IP for use in
    notifications.

- [X] 2.0 **User Story:** As a developer, I want a cleanup function
  that tears down stale IPsec/xl2tpd/routing state so that
  reconnection starts from a clean slate [2/0]
  - [X] 2.1 Implement `cleanup_stale_state()`: kill xl2tpd, run
    `ipsec down L2TP-PSK`, remove company routes from ppp0, delete
    ppp0 MASQUERADE iptables rule, recreate xl2tpd control socket.
    All commands must tolerate "not found" errors (2>/dev/null).
  - [X] 2.2 Implement `start_ipsec_daemon()`: check if ipsec is
    already running (`ipsec status`), start only if not. Needed
    because `ipsec start` fails if daemon is already up.

- [X] 3.0 **User Story:** As a developer, I want a ppp0 monitoring
  loop that detects interface loss so that disconnects are caught
  within 15 seconds [2/0]
  - [X] 3.1 Implement `monitor_ppp0()`: loop `ip link show ppp0`
    every 10 seconds, return when ppp0 disappears.
  - [X] 3.2 Wire the main loop: `configure()` once, then
    `while true: cleanup → connect → if fail: backoff, continue →
    setup_routing → monitor_ppp0 → (loop restarts on disconnect)`.
    Remove `sleep infinity`.

- [X] 4.0 **User Story:** As a developer, I want ntfy notifications
  on disconnect and recovery so that I'm aware of L2TP events
  without checking manually [3/0]
  - [X] 4.1 Implement `notify()` function: POST to
    `http://172.29.0.10:80/${NTFY_TOPIC}` with Title and Priority
    headers. Failure must not block (|| log "WARNING: ...").
  - [X] 4.2 Add disconnect notification: when `monitor_ppp0()`
    returns, record `DISCONNECT_TS=$(date +%s)` and send
    "Company VPN Down — L2TP tunnel lost. Reconnecting...".
  - [X] 4.3 Add recovery notification: after successful `connect()`
    + `setup_routing()`, compute downtime from `DISCONNECT_TS` and
    send "Company VPN Up — Reconnected. Downtime: {N}s. IP: {ip}".
    Skip downtime reporting on initial connect (no prior disconnect).

- [X] 5.0 **User Story:** As a developer, I want exponential backoff
  on reconnection failures so that the container doesn't spam
  attempts when the peer is unreachable [2/0]
  - [X] 5.1 Implement backoff variables and functions:
    `BACKOFF_STEP=0`, delays "15 30 60 120 300",
    `backoff_sleep()` picks delay by step index (max 300s),
    `reset_backoff()` sets step to 0.
  - [X] 5.2 Implement failure notification throttle: track
    `CONSECUTIVE_FAILURES` counter. Send one ntfy alert after 3
    consecutive failures ("Company VPN: reconnection failing").
    Reset counter on success.

- [X] 6.0 **User Story:** As a developer, I want the NTFY_TOPIC env
  var passed to the l2tp-vpn container so that notifications go to
  the correct topic [1/0]
  - [X] 6.1 Add `- NTFY_TOPIC=${NTFY_TOPIC:-vpn-alerts}` to the
    l2tp-vpn `environment` section in `docker-compose.yml`.

- [X] 7.0 **User Story:** As a developer, I want end-to-end
  verification so that reconnection and notifications work in
  production [3/0]
  - [X] 7.1 Deploy to VPS: `deploy-push.sh`, then
    `rdocker.sh compose up -d --build --force-recreate l2tp-vpn`.
    Verify container starts, ppp0 comes up, company IPs reachable.
  - [X] 7.2 Simulate disconnect:
    `rdocker.sh exec l2tp-vpn ip link delete ppp0`. Verify:
    ntfy "Down" notification arrives, container logs show reconnect
    attempt, ppp0 comes back, ntfy "Up" notification with downtime.
  - [X] 7.3 Commit: `l2tp/entrypoint.sh`, `docker-compose.yml`.
