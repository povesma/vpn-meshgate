# 007-DOMAIN-ROUTING - Task List

## Relevant Files

- [tasks/007-DOMAIN-ROUTING/2026-04-08-007-DOMAIN-ROUTING-prd.md](
  2026-04-08-007-DOMAIN-ROUTING-prd.md) :: PRD
- [tasks/007-DOMAIN-ROUTING/2026-04-08-007-DOMAIN-ROUTING-tech-design.md](
  2026-04-08-007-DOMAIN-ROUTING-tech-design.md) :: Technical Design
- [generate-vpn.py](../../generate-vpn.py) :: YAML validation +
  JSON/override generation — add route_domains support
- [gluetun/init-routes.sh](../../gluetun/init-routes.sh) :: Route
  setup in gluetun namespace — add domain routing loop
- [gluetun/Dockerfile.route-init](
  ../../gluetun/Dockerfile.route-init) :: Route-init container
  image — add bind-tools dependency
- [secrets/vpn-instances.yaml.example](
  ../../secrets/vpn-instances.yaml.example) :: Example config —
  add route_domains examples
- [l2tp/entrypoint.sh](../../l2tp/entrypoint.sh) :: L2TP
  entrypoint — change default route to ppp0
- [wireguard/entrypoint.sh](../../wireguard/entrypoint.sh) ::
  WireGuard entrypoint — change default route to wg0
- [openvpn/entrypoint.sh](../../openvpn/entrypoint.sh) ::
  OpenVPN entrypoint — change default route to tun0
- [netbird/entrypoint.sh](../../netbird/entrypoint.sh) ::
  Netbird entrypoint — change default route to wt0

## Notes

- TDD is applicable for `generate-vpn.py` validation logic
  (pure Python, testable locally). Shell script changes are
  verified on live VPS deployment.
- `dns/entrypoint.sh` and `docker-compose.yml` do NOT need
  changes — domain routing is handled entirely in route-init.
- VPN instance entrypoints do NOT need changes — they already
  route any traffic arriving via bridge_vpn.
- Implementation order: config schema first (enables testing),
  then Dockerfile (enables dig), then route-init logic.

## Tasks

- [X] 1.0 **User Story:** As a VPN user, I want `route_domains`
  supported in the config schema so that I can define domains
  per VPN instance [2/2]
  - [X] 1.1 Add `route_domains` field to the L2TP instance
    example in `secrets/vpn-instances.yaml.example` with 2-3
    sample domains (e.g., `git.company-a.com`,
    `ci.company-a.com`). Add a comment explaining the
    difference between `dns_domains` and `route_domains`
    [verify: code-only]
  - [X] 1.2 Add `route_domains` to the Netbird instance example
    in `secrets/vpn-instances.yaml.example` to show it works
    across tunnel types [verify: code-only]

- [X] 2.0 **User Story:** As a VPN user, I want the generator
  to validate and include `route_domains` in the output so
  that downstream components can consume them [4/4]
  - [X] 2.1 Add `route_domains` validation to `generate-vpn.py`
    `validate()`: each entry must be a valid domain name or
    `*.domain` wildcard. Reject duplicates across instances.
    Reject invalid formats (mid-string wildcards, empty
    strings) [verify: manual-run-claude]
  - [X] 2.2 Add `route_domains` to `generate-vpn.py`
    `generate_json()`: include the field in each instance's
    JSON output, defaulting to `[]` when absent
    [verify: manual-run-claude]
  - [X] 2.3 Run `python3 generate-vpn.py` with a test YAML
    containing `route_domains` entries. Verify JSON output
    includes the field correctly
    [verify: manual-run-claude]
    → JSON output includes route_domains arrays correctly [live] (2026-04-08)
  - [X] 2.4 Run `python3 generate-vpn.py` with duplicate
    `route_domains` across instances. Verify the generator
    rejects it with a clear error message
    [verify: manual-run-claude]
    → "route_domain 'git.company.com' duplicates entry from 'test-a'" + exit 1 [live] (2026-04-08)

- [X] 3.0 **User Story:** As a VPN user, I want route-init to
  have DNS resolution tools so that it can resolve domains at
  runtime [1/1]
  - [X] 3.1 Add `bind-tools` to the `apk add` line in
    `gluetun/Dockerfile.route-init` [verify: code-only]

- [X] 4.0 **User Story:** As a VPN user, I want route-init to
  resolve `route_domains` and create /32 routes so that
  traffic to those IPs goes through the correct VPN
  instance [4/4]
  - [X] 4.1 In `gluetun/init-routes.sh`, after the existing
    CIDR routing loop, check if any instance has
    `route_domains`. If none, fall back to
    `exec sleep infinity` (preserve current behavior)
    [verify: code-only]
  - [X] 4.2 Implement the `resolve_domain()` function: run
    `dig @172.29.0.30 <domain> +noall +answer`, parse A
    record IPs and TTL values from the output. For wildcard
    entries (`*.domain`), strip the `*.` prefix and resolve
    the base domain [verify: code-only]
  - [X] 4.3 Implement the `update_domain_routes()` function:
    for each instance with `route_domains`, resolve all
    domains, compare resolved IPs against state files in
    `/tmp/domain-routes/<instance>/<domain>.state`. Add
    new /32 routes (`ip route replace`, `ip rule add`,
    iptables `VPN-INSTANCE-OUT`/`VPN-INSTANCE-IN`). Remove
    stale routes for IPs that no longer resolve
    [verify: code-only]
  - [X] 4.4 Wire the domain routing loop into the main script:
    call `update_domain_routes()` in a `while true` loop
    with a configurable sleep interval (replacing
    `sleep infinity`). Log each route add/remove with
    instance name, domain, and IP [verify: code-only]

- [X] 5.0 **User Story:** As a VPN user, I want domain route
  resolution to be TTL-aware so that routes refresh before
  DNS records expire [2/2]
  - [X] 5.1 Extend `resolve_domain()` to return the minimum
    TTL from all A records. Store TTL + timestamp in the
    per-domain state file alongside resolved IPs
    [verify: code-only]
  - [X] 5.2 Make the sleep interval TTL-driven: compute
    `min_ttl * 0.8` across all domains, clamp between
    `MIN_POLL` (30s) and `MAX_POLL` (300s), use as the
    loop sleep duration. Log the computed sleep interval
    [verify: code-only]

- [ ] 5b.0 **User Story:** As a VPN user, I want VPN instance
  containers to route all received traffic through their
  tunnel so that domain-resolved public IPs exit via the
  company VPN, not via the VPS internet [4/0]
  - [~] 5b.1 In `l2tp/entrypoint.sh` `setup_routing()`: after
    `ppp0` is up, resolve `L2TP_SERVER` to an IP, add a
    pinned route for that IP via `eth0` (`ip route add
    <server_ip>/32 via 172.29.0.1 dev eth0`), then change
    the default route to `ppp0` (`ip route replace default
    dev ppp0`) [verify: code-only]
    → coded, pending VPS deployment verification
  - [~] 5b.2 In `wireguard/entrypoint.sh` `setup_routing()`:
    after `wg0` is up, extract the endpoint IP from
    `wg show wg0 endpoints`, pin it via `eth0`, change
    default route to `wg0` [verify: code-only]
    → coded, pending VPS deployment verification
  - [~] 5b.3 In `openvpn/entrypoint.sh` `setup_routing()`:
    after `tun0` is up, extract the remote server IP from
    `/etc/openvpn/client.conf`, pin it via `eth0`, change
    default route to `tun0` [verify: code-only]
    → coded, pending VPS deployment verification
  - [~] 5b.4 In `netbird/entrypoint.sh` `setup_routing()`:
    after `wt0` is up, resolve `NB_MANAGEMENT_URL` hostname
    to an IP, pin it via `eth0`, change default route to
    `wt0` [verify: code-only]
    → coded, pending VPS deployment verification

- [ ] 6.0 **User Story:** As a VPN user, I want to deploy and
  verify domain-based routing end-to-end so that the feature
  is confirmed working [4/0]
  - [~] 6.1 Add `route_domains` entries to local
    `secrets/vpn-instances.yaml` for at least one instance
    with a real company domain on a public IP
    [verify: manual-run-user]
  - [~] 6.2 Run `python3 generate-vpn.py` and verify
    `vpn-instances.json` includes `route_domains`. Deploy
    to VPS and rebuild route-init:
    `./deploy-push.sh && ./rdocker.sh compose up -d --build
    --force-recreate route-init`
    [verify: manual-run-user]
  - [~] 6.3 Check route-init logs for domain resolution and
    /32 route creation:
    `./rdocker.sh compose logs route-init | grep domain`
    [verify: manual-run-user]
    → domain routing loop runs, /32 routes created, but
      traffic not routed through tunnel (2026-04-11)
  - [ ] 6.4 From Mac via Tailscale exit node, verify traffic
    to the configured domain goes through the VPN instance
    (not Mullvad): `curl` or `traceroute` to the domain
    [verify: manual-run-user]

- [ ] 7.0 **User Story:** As a VPN user, I want the PRD and
  tech design marked complete so that the feature is properly
  closed out [2/0]
  - [ ] 7.1 Update PRD status from Draft to Complete
    [verify: code-only]
  - [ ] 7.2 Update tech design status from Draft to Complete
    [verify: code-only]
