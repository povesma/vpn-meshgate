# 005-CUSTOM-ROUTES - Task List

## Relevant Files

- [tasks/005-CUSTOM-ROUTES/2026-04-05-005-CUSTOM-ROUTES-prd.md](
  2026-04-05-005-CUSTOM-ROUTES-prd.md) :: PRD
- [tasks/005-CUSTOM-ROUTES/2026-04-05-005-CUSTOM-ROUTES-tech-design.md](
  2026-04-05-005-CUSTOM-ROUTES-tech-design.md) :: Technical Design
- [gluetun/init-routes.sh](../../gluetun/init-routes.sh) :: Route-init
  sidecar — company CIDR routing in gluetun namespace
- [l2tp/entrypoint.sh](../../l2tp/entrypoint.sh) :: L2TP container
  entrypoint — routing setup and cleanup
- [docker-compose.yml](../../docker-compose.yml) :: Container env var
  definitions
- [.env.example](../../.env.example) :: Documented env var template

## Notes

- TDD is not applicable — deliverables are shell script and Docker
  config changes verified on a live VPS deployment.
- Phase 1 only (static routes via `.env`). Phase 2 (bot commands)
  and Phase 3 (DNS-based routing) are separate future task lists.
- `.env` is a secrets file — never read or written by automation.
  Only `.env.example` is managed.

## Tasks

- [X] 1.0 **User Story:** As a VPN user, I want `EXTRA_VPN_CIDRS`
  documented in `.env.example` and wired through Docker Compose so
  that both route-init and l2tp-vpn containers receive the
  value [3/3]
  - [X] 1.1 Add `EXTRA_VPN_CIDRS=` with comment to
    `.env.example` after the `COMPANY_CIDRS` line
    [verify: code-only]
  - [X] 1.2 Add `EXTRA_VPN_CIDRS=${EXTRA_VPN_CIDRS}` to
    `route-init` environment in `docker-compose.yml:48`
    [verify: code-only]
  - [X] 1.3 Add `EXTRA_VPN_CIDRS=${EXTRA_VPN_CIDRS}` to
    `l2tp-vpn` environment in `docker-compose.yml:93`
    [verify: code-only]

- [X] 2.0 **User Story:** As a VPN user, I want route-init to
  route `EXTRA_VPN_CIDRS` through the L2TP container so that
  extra CIDRs get the same ip route, ip rule, and iptables
  treatment as `COMPANY_CIDRS` [2/2]
  - [X] 2.1 In `gluetun/init-routes.sh:32-38`, replace the
    `COMPANY_CIDRS` empty check with a merged `ALL_VPN_CIDRS`
    variable using
    `"${COMPANY_CIDRS}${EXTRA_VPN_CIDRS:+,${EXTRA_VPN_CIDRS}}"`
    and update the log messages. Change the `for` loop on
    line 39 to iterate `${ALL_VPN_CIDRS}` instead of
    `${COMPANY_CIDRS}` [verify: code-only]
  - [X] 2.2 Add a log line for extra CIDRs:
    `[ -n "${EXTRA_VPN_CIDRS}" ] && log "  extra: ..."`
    [verify: code-only]

- [X] 3.0 **User Story:** As a VPN user, I want l2tp-vpn to
  route `EXTRA_VPN_CIDRS` over ppp0 and clean them up on
  reconnect so that extra CIDRs are reachable through the L2TP
  tunnel and restored after disconnects [3/3]
  - [X] 3.1 In `l2tp/entrypoint.sh` `setup_routing()` (line
    199), add `ALL_VPN_CIDRS` merge before the routing loop
    and change the `for` loop on line 201 to iterate
    `${ALL_VPN_CIDRS}` [verify: code-only]
  - [X] 3.2 In `l2tp/entrypoint.sh` `cleanup_stale_state()`
    (line 114), add `ALL_VPN_CIDRS` merge before the cleanup
    loop and change the `for` loop on line 116 to iterate
    `${ALL_VPN_CIDRS}` [verify: code-only]
  - [X] 3.3 Add extra CIDRs to the `configure()` log output
    on line 40: `log "Extra:  ${EXTRA_VPN_CIDRS:-none}"`
    [verify: code-only]

- [ ] 4.0 **User Story:** As a VPN user, I want to deploy the
  stack with `EXTRA_VPN_CIDRS=198.51.100.34/32` and verify
  end-to-end routing from my Mac so that the feature is
  confirmed working [4/0]
  - [ ] 4.1 Add `EXTRA_VPN_CIDRS=198.51.100.34/32` to `.env`
    on VPS and redeploy the stack [verify: manual-run-user]
  - [ ] 4.2 Check route-init logs for extra CIDR route/rule/
    iptables entries:
    `docker logs route-init 2>&1 | grep 194.154`
    [verify: manual-run-user]
  - [ ] 4.3 Check l2tp-vpn routing table includes the extra
    CIDR: `docker exec l2tp-vpn ip route | grep 194.154`
    [verify: manual-run-user]
  - [ ] 4.4 From Mac via Tailscale exit node, verify traffic
    to `198.51.100.34` goes through L2TP tunnel:
    `traceroute 198.51.100.34` or `curl` to a service on
    that IP [verify: manual-run-user]

- [ ] 5.0 **User Story:** As a VPN user, I want the PRD and
  tech design marked complete so that the feature is properly
  closed out [2/0]
  - [ ] 5.1 Update PRD status from Draft to Complete
    [verify: code-only]
  - [ ] 5.2 Update tech design status from Draft to Complete
    [verify: code-only]
