# 008-L2TP-BOOTSTRAP-DNS-FIX - Task List

## Relevant Files

- [tasks/008-L2TP-BOOTSTRAP-DNS-FIX/2026-05-05-008-L2TP-BOOTSTRAP-DNS-FIX-prd.md](
  2026-05-05-008-L2TP-BOOTSTRAP-DNS-FIX-prd.md) :: PRD
- [tasks/008-L2TP-BOOTSTRAP-DNS-FIX/2026-05-05-008-L2TP-BOOTSTRAP-DNS-FIX-tech-design.md](
  2026-05-05-008-L2TP-BOOTSTRAP-DNS-FIX-tech-design.md) :: Technical
  Design
- [l2tp/Dockerfile](../../l2tp/Dockerfile) :: Add `bind-tools` to apk
  install list to provide `nslookup` with explicit-resolver support
- [l2tp/entrypoint.sh](../../l2tp/entrypoint.sh) :: Add
  `resolve_gateway` function, call it at top of main loop, replace
  `getent hosts` route-pin at line 235, add env-knob defaults

## Notes

- This is a shell-script change in a single tunnel container. No unit
  test framework exists in this repo for shell; the `auto-test`
  verifications below are realised via small ad-hoc shell tests run
  with `sh` against extracted function under stub conditions.
- All e2e verification is against the live VPS via `./rdocker.sh`.
- Per CLAUDE.md: redeploy with `./rdocker.sh compose up -d --build
  --force-recreate vpn-artec-vpn` to ensure new image + fresh env.

## Tasks

- [X] 1.0 **User Story:** As an operator, I want the L2TP image to
  ship with a public-resolver-capable lookup tool so that the
  entrypoint can resolve its gateway hostname without going through
  dnsmasq [1/1]
  - [X] 1.1 Add `bind-tools` to the `apk add --no-cache` list in
    `l2tp/Dockerfile` [verify: code-only]

- [X] 2.0 **User Story:** As an operator, I want the L2TP entrypoint
  to expose tunable knobs for bootstrap-DNS behavior so that I can
  override resolvers and retry policy without editing the script
  [1/1]
  - [X] 2.1 Declare defaults near the top of `l2tp/entrypoint.sh`
    for `BOOTSTRAP_DNS_PRIMARY=1.1.1.1`,
    `BOOTSTRAP_DNS_SECONDARY=8.8.8.8`,
    `BOOTSTRAP_DNS_RETRIES=5`,
    `BOOTSTRAP_DNS_BACKOFF="5 10 20 40 60"`, each via
    `: "${VAR:=default}"` so env overrides win [verify: code-only]

- [X] 3.0 **User Story:** As an operator, I want the entrypoint to
  resolve the L2TP gateway hostname via a public resolver and write
  the result into `/etc/hosts` so that strongSwan, xl2tpd, and the
  route-pin all see a literal IP without consulting dnsmasq [4/4]
  - [X] 3.1 Implement `resolve_gateway()` function: try primary
    resolver via `nslookup ${L2TP_SERVER} ${BOOTSTRAP_DNS_PRIMARY}`,
    fall back to secondary on failure, parse first IPv4 from output,
    set shell variable `GATEWAY_IP` [verify: auto-test]
    → l2tp/test-resolve-gateway.sh: 13 passed, 0 failed [live] (2026-05-05)
  - [X] 3.2 Add atomic `/etc/hosts` rewrite inside
    `resolve_gateway()`: filter out any prior line matching
    `[[:space:]]${L2TP_SERVER}$`, append fresh `<ip>\t<hostname>`,
    `mv` temp file over `/etc/hosts` [verify: auto-test]
    → tests confirm stale entry removed, fresh entry present, unrelated entries preserved, exactly one line per host [live] (2026-05-05)
  - [X] 3.3 Wrap the resolver attempts in a retry loop bounded by
    `BOOTSTRAP_DNS_RETRIES`, sleeping per `BOOTSTRAP_DNS_BACKOFF`
    between rounds; on exhaustion, log
    `FATAL: cannot resolve <host> after N attempts` and return 1
    [verify: auto-test]
    → exhaustion test: RC=1, FATAL log emitted [live] (2026-05-05)
  - [X] 3.4 Emit per-attempt log lines using existing `log` helper:
    `Resolving <host> via <resolver>` per try and
    `Gateway <host> -> <ip> (via <resolver>)` on success
    [verify: code-only]

- [X] 4.0 **User Story:** As an operator, I want
  `resolve_gateway` invoked at the top of every reconnect-loop
  iteration so that gateway IP rotations are picked up automatically
  and the failure path reuses existing backoff plumbing [2/2]
  - [X] 4.1 Insert call to `resolve_gateway` as the first action
    inside the `while true` loop at `l2tp/entrypoint.sh:266`,
    BEFORE `cleanup_stale_state`. On non-zero return, call
    `backoff_sleep` and `continue` [verify: code-only]
  - [X] 4.2 Confirm `configure()` (line 264, runs once before loop)
    is NOT modified — `${L2TP_SERVER}` continues to appear as a
    hostname in `/etc/ipsec.conf` and `/etc/xl2tpd/xl2tpd.conf`
    templates; resolution is via `/etc/hosts` at lookup time
    [verify: code-only]

- [X] 5.0 **User Story:** As an operator, I want the route-pin in
  `setup_routing` to reuse the bootstrap-resolved IP so that the
  silent split-DNS warning is eliminated and the route-pin no longer
  depends on dnsmasq [1/1]
  - [X] 5.1 At `l2tp/entrypoint.sh:235`, replace
    `server_ip=$(getent hosts "${L2TP_SERVER}" ...)` with
    `server_ip="${GATEWAY_IP}"`; keep the surrounding `if [ -n
    "${server_ip}" ]` check and log lines unchanged
    [verify: code-only]

- [X] 6.0 **User Story:** As an operator, I want to deploy and
  verify end-to-end on the VPS that the L2TP tunnel comes up and
  split-DNS continues to work for non-gateway names [4/4]
  - [X] 6.1 Deploy: `./deploy-push.sh && ./rdocker.sh compose up -d
    --build --force-recreate vpn-artec-vpn` and confirm container
    transitions to Up without continuous restart loop
    [verify: manual-run-user]
    → container Up, no restart loop; build pulled bind-tools cleanly [live] (2026-05-05)
  - [X] 6.2 Verify bootstrap success in logs: `./rdocker.sh compose
    logs --tail=200 vpn-artec-vpn | grep -E "Resolving|Gateway"`
    must show a successful resolution, and a `ppp0 is UP with IP
    <x>` line must appear within 60s of container start
    [verify: manual-run-user]
    → "Resolving gw.corp.example.com via 1.1.1.1" → "Gateway gw.corp.example.com -> 198.51.100.34 (via 1.1.1.1)" → "ppp0 is UP with IP 10.11.232.155"; /etc/hosts shows persisted entry [live] (2026-05-05)
  - [X] 6.3 Verify split-DNS still works for non-gateway company
    names: `./rdocker.sh compose exec dnsmasq nslookup
    <internal-only-artec-name> 172.29.0.30` returns an internal IP
    via the corp resolver `10.11.232.1` (proves split-DNS routing
    is intact and corp DNS is now reachable through the up tunnel)
    [verify: manual-run-user]
    → dnsmasq nslookup corp.example.com 172.29.0.30 → 3.76.6.105 via split-DNS rule; direct query to 10.11.232.1 returns NS records (corp DNS reachable through tunnel) [live] (2026-05-05)
  - [X] 6.4 Verify route-pin populated correctly: `./rdocker.sh
    compose exec vpn-artec-vpn ip route | grep <gateway-ip>` shows
    the `/32` pin via `eth0` (no warning in logs about resolution
    failure) [verify: manual-run-user]
    → "198.51.100.34 via 172.29.0.1 dev eth0" present; no GATEWAY_IP-empty warning logged [live] (2026-05-05)

- [X] 7.0 **User Story:** As an operator, I want the PRD and tech
  design status updated to Complete after live verification so the
  task is properly closed out [2/2]
  - [X] 7.1 Update PRD `Status: Draft` → `Status: Complete`
    [verify: code-only]
  - [X] 7.2 Update tech design `Status: Draft` → `Status: Complete`
    [verify: code-only]
