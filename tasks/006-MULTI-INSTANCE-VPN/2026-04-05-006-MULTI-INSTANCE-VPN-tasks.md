# 006-MULTI-INSTANCE-VPN - Task List

## Relevant Files

- [tasks/006-MULTI-INSTANCE-VPN/2026-04-05-006-MULTI-INSTANCE-VPN-prd.md](
  2026-04-05-006-MULTI-INSTANCE-VPN-prd.md) :: PRD
- [tasks/006-MULTI-INSTANCE-VPN/2026-04-05-006-MULTI-INSTANCE-VPN-tech-design.md](
  2026-04-05-006-MULTI-INSTANCE-VPN-tech-design.md) :: Technical Design
- [generate-vpn.py](../../generate-vpn.py) :: YAML → compose override
  + JSON generator (new)
- [vpn-instances.yaml.example](../../vpn-instances.yaml.example) ::
  Example YAML config (new)
- [docker-compose.yml](../../docker-compose.yml) :: Base compose —
  remove l2tp-vpn service
- [gluetun/init-routes.sh](../../gluetun/init-routes.sh) :: Route-init
  — rewrite for JSON-based multi-instance routing
- [gluetun/Dockerfile.route-init](../../gluetun/Dockerfile.route-init)
  :: Add jq dependency
- [l2tp/entrypoint.sh](../../l2tp/entrypoint.sh) :: Refactor for
  INSTANCE_CIDRS + VPN_INSTANCE_NAME
- [wireguard/Dockerfile](../../wireguard/Dockerfile) :: WireGuard
  container image (new)
- [wireguard/entrypoint.sh](../../wireguard/entrypoint.sh) :: WireGuard
  tunnel lifecycle (new)
- [openvpn/Dockerfile](../../openvpn/Dockerfile) :: OpenVPN container
  image (new)
- [openvpn/entrypoint.sh](../../openvpn/entrypoint.sh) :: OpenVPN
  tunnel lifecycle (new)
- [netbird/entrypoint.sh](../../netbird/entrypoint.sh) :: Netbird
  tunnel wrapper (new, mounted into official image)
- [bot/bot.sh](../../bot/bot.sh) :: Instance-aware bot commands
- [healthcheck/check.sh](../../healthcheck/check.sh) :: Per-instance
  health checks
- [dns/entrypoint.sh](../../dns/entrypoint.sh) :: Per-instance DNS
  domains
- [.env.example](../../.env.example) :: Remove L2TP vars
- [deploy-push.sh](../../deploy-push.sh) :: Add vpn-instances.yaml to
  PROTECTED_GITIGNORED

## Notes

- TDD is not applicable for most tasks — deliverables are shell
  scripts, Docker configs, and a Python generator verified on a
  live VPS deployment.
- The Python generator (`generate-vpn.py`) CAN be unit-tested
  locally since it's a pure build-time tool.
- `.env` remains for Mullvad, Tailscale, ntfy, and deployment
  vars. VPN instance config moves to `vpn-instances.yaml`.
- `vpn-instances.yaml` is a secrets file — never committed.
  Only `vpn-instances.yaml.example` is managed.
- Implementation order: generator first (enables all
  downstream work), then L2TP refactor (proven type), then
  new tunnel types, then supporting services.

## Tasks

- [X] 1.0 **User Story:** As a VPN user, I want project
  scaffolding updated for multi-instance support so that config
  files, gitignore, and deployment scripts are ready [5/5]
  - [X] 1.1 Create `vpn-instances.yaml.example` with documented
    example config showing all three tunnel types (L2TP,
    WireGuard, OpenVPN) per the tech design data contract
    [verify: code-only]
  - [X] 1.2 Add `vpn-instances.yaml` and
    `docker-compose.override.yml` to `.gitignore`
    [verify: code-only]
  - [X] 1.3 Add `vpn-instances.yaml` to `PROTECTED_GITIGNORED`
    array in `deploy-push.sh:23` [verify: code-only]
  - [X] 1.4 Remove L2TP-specific vars (`L2TP_SERVER`,
    `L2TP_USERNAME`, `L2TP_PASSWORD`, `L2TP_PSK`,
    `COMPANY_CIDRS`, `EXTRA_VPN_CIDRS`, `COMPANY_DOMAIN`) from
    `.env.example` and add a comment pointing to
    `vpn-instances.yaml` [verify: code-only]
  - [X] 1.5 Create empty `wireguard/` and `openvpn/` directories
    with placeholder `.gitkeep` files [verify: code-only]

- [X] 2.0 **User Story:** As a VPN user, I want a Python
  generator that reads `vpn-instances.yaml` and produces
  `docker-compose.override.yml` + `vpn-instances.json` so that
  VPN instances are dynamically configured [6/6]
  - [X] 2.1 Create `generate-vpn.py` with YAML loading and
    validation: check required fields per tunnel type, reject
    duplicate names, reject overlapping CIDRs, reject unknown
    types [verify: manual-run-claude]
    → duplicate names and overlapping CIDRs rejected [live] (2026-04-05)
  - [X] 2.2 Implement IP assignment logic: instances get
    `172.29.0.101`, `.102`, `.103` etc. in definition order
    [verify: manual-run-claude]
    → 3 instances assigned .101/.102/.103 correctly [live] (2026-04-05)
  - [X] 2.3 Implement `docker-compose.override.yml` generation
    for L2TP instances: service definition with `build: ./l2tp`,
    `privileged: true`, `/dev/ppp`, env vars (`VPN_INSTANCE_NAME`,
    `L2TP_SERVER`, `L2TP_USERNAME`, `L2TP_PASSWORD`, `L2TP_PSK`,
    `INSTANCE_CIDRS`, `NTFY_TOPIC`, `L2TP_CHECK_IP`), network IP,
    volumes, restart policy [verify: manual-run-claude]
    → L2TP override correct with all fields [live] (2026-04-05)
  - [X] 2.4 Implement override generation for WireGuard instances:
    `build: ./wireguard`, `cap_add: [NET_ADMIN]`, config file
    mount, env vars (`VPN_INSTANCE_NAME`, `INSTANCE_CIDRS`,
    `NTFY_TOPIC`, `WG_CHECK_IP`) [verify: manual-run-claude]
    → WG override correct with config mount [live] (2026-04-05)
  - [X] 2.5 Implement override generation for OpenVPN instances:
    `build: ./openvpn`, `cap_add: [NET_ADMIN]`, `/dev/net/tun`,
    config file mount, env vars (`VPN_INSTANCE_NAME`,
    `INSTANCE_CIDRS`, `OVPN_USERNAME`, `OVPN_PASSWORD`,
    `NTFY_TOPIC`, `OVPN_CHECK_IP`) [verify: manual-run-claude]
    → OpenVPN override correct with creds + config [live] (2026-04-05)
  - [X] 2.6 Implement `vpn-instances.json` generation: write to
    project root (synced to VPS, copied to shared volume at
    deploy time). Include name, type, ip, cidrs, check_ip,
    dns_domains, container fields per instance
    [verify: manual-run-claude]
    → JSON with all fields generated correctly [live] (2026-04-05)

- [X] 3.0 **User Story:** As a VPN user, I want the L2TP
  entrypoint refactored to use `INSTANCE_CIDRS` and
  `VPN_INSTANCE_NAME` so that it works as one of N
  instances [4/4]
  - [X] 3.1 Replace all `COMPANY_CIDRS` / `EXTRA_VPN_CIDRS` /
    `ALL_VPN_CIDRS` references in `l2tp/entrypoint.sh` with
    `INSTANCE_CIDRS` — in `configure()`, `cleanup_stale_state()`,
    and `setup_routing()` [verify: code-only]
  - [X] 3.2 Replace hardcoded `[l2tp]` log prefix with
    `[vpn-${VPN_INSTANCE_NAME:-l2tp}]` throughout
    `l2tp/entrypoint.sh` [verify: code-only]
  - [X] 3.3 Update ntfy notification titles to include instance
    name: e.g. "Company VPN Up" → "${VPN_INSTANCE_NAME} VPN Up"
    [verify: code-only]
  - [X] 3.4 Update DNS output path from `/shared/company-dns-ip`
    to `/shared/${VPN_INSTANCE_NAME}-dns-ip` so multiple L2TP
    instances don't overwrite each other's DNS
    [verify: code-only]

- [X] 4.0 **User Story:** As a VPN user, I want a WireGuard
  container with Dockerfile and entrypoint so that I can
  connect to company VPNs that use WireGuard [3/3]
  - [X] 4.1 Create `wireguard/Dockerfile`: Alpine-based image
    with `wireguard-tools`, `iptables`, `curl`, `ip` utilities
    [verify: code-only]
  - [X] 4.2 Create `wireguard/entrypoint.sh`: read
    `VPN_INSTANCE_NAME` and `INSTANCE_CIDRS` env vars, run
    `wg-quick up wg0`, route INSTANCE_CIDRS over `wg0`, add
    MASQUERADE + MSS clamping on `wg0`, enable ip_forward
    [verify: code-only]
  - [X] 4.3 Add monitoring loop: check `wg show wg0` handshake
    age, reconnect with `wg-quick down/up` on failure, ntfy
    notifications with instance name, exponential backoff
    (same pattern as L2TP) [verify: code-only]

- [X] 5.0 **User Story:** As a VPN user, I want an OpenVPN
  container with Dockerfile and entrypoint so that I can
  connect to company VPNs that use OpenVPN [3/3]
  - [X] 5.1 Create `openvpn/Dockerfile`: Alpine-based image with
    `openvpn`, `iptables`, `curl`, `ip` utilities
    [verify: code-only]
  - [X] 5.2 Create `openvpn/entrypoint.sh`: read
    `VPN_INSTANCE_NAME`, `INSTANCE_CIDRS`, `OVPN_USERNAME`,
    `OVPN_PASSWORD` env vars, write auth file, start openvpn
    with config, route INSTANCE_CIDRS over `tun0`, add
    MASQUERADE + MSS clamping on `tun0`, enable ip_forward
    [verify: code-only]
  - [X] 5.3 Add monitoring loop: check `tun0` interface exists,
    restart openvpn on failure, ntfy notifications with instance
    name, exponential backoff [verify: code-only]

- [X] 5b.0 **User Story:** As a VPN user, I want a Netbird
  container entrypoint so that I can connect to company VPNs
  that use Netbird [3/3]
  - [X] 5b.1 Create `netbird/entrypoint.sh`: wrapper that runs
    `netbird up --setup-key $NB_SETUP_KEY`, waits for `wt0`
    interface, routes INSTANCE_CIDRS over `wt0`, adds
    MASQUERADE + MSS clamping, enables ip_forward
    [verify: code-only]
  - [X] 5b.2 Add monitoring loop: check `wt0` interface +
    `netbird status`, reconnect with `netbird down/up` on
    failure, ntfy notifications with instance name,
    exponential backoff [verify: code-only]
  - [X] 5b.3 Update `generate-vpn.py` to support `netbird`
    type: use `image: netbirdio/netbird:latest` (not build),
    mount `netbird/entrypoint.sh` as entrypoint override,
    add `NB_SETUP_KEY`, `NB_MANAGEMENT_URL` env vars, add
    `cap_add: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]`, add
    named volume for Netbird state [verify: manual-run-claude]
    → 4 instances generated, netbird override correct with image/caps/volume, compose parses OK [live] (2026-04-05)

- [X] 6.0 **User Story:** As a VPN user, I want route-init
  rewritten to read `/shared/vpn-instances.json` so that each
  instance's CIDRs route to the correct container IP [3/3]
  - [X] 6.1 Add `jq` package to
    `gluetun/Dockerfile.route-init` [verify: code-only]
  - [X] 6.2 Rewrite `gluetun/init-routes.sh`: replace env
    var-based CIDR loop with JSON parsing via `jq`. For each
    instance in `/shared/vpn-instances.json`, route that
    instance's CIDRs to that instance's IP with `ip route
    replace`, `ip rule add`, and `iptables` ACCEPT rules.
    Log per-instance: name, IP, CIDRs [verify: code-only]
  - [X] 6.3 Keep Tailscale direct routing logic (table 201,
    fwmark 0x80000) unchanged at top of script. Only replace
    the CIDR routing section [verify: code-only]

- [X] 7.0 **User Story:** As a VPN user, I want
  `docker-compose.yml` updated to remove the old single
  `l2tp-vpn` service and support the override pattern [4/4]
  - [X] 7.1 Remove the `l2tp-vpn` service definition from
    `docker-compose.yml` [verify: code-only]
  - [X] 7.2 Remove `COMPANY_CIDRS` and `EXTRA_VPN_CIDRS` env
    vars from `route-init` service [verify: code-only]
  - [X] 7.3 Mount `vpn-instances.json` into route-init via
    shared-config volume (generator writes to project root,
    deploy-push syncs it, compose volume makes it available)
    [verify: code-only]
  - [X] 7.4 Verify `docker compose config` parses with the
    example override: create a temporary override from the
    example YAML, run `docker compose -f docker-compose.yml
    -f docker-compose.override.yml config`
    [verify: manual-run-claude]
    → compose config parses OK with 3-instance override [live] (2026-04-05)

- [X] 8.0 **User Story:** As a VPN user, I want the bot,
  healthcheck, and dnsmasq updated for per-instance awareness
  so that I can monitor and manage individual VPN
  tunnels [6/6]
  - [X] 8.1 Update `bot/bot.sh` `cmd_status()`: read
    `/shared/vpn-instances.json` via `jq`, ping each
    instance's `check_ip`, report per-instance status
    [verify: code-only]
  - [X] 8.2 Update `bot/bot.sh`: add `restart <name>` command
    that runs `docker restart vpn-<name>`. Validate name
    against `/shared/vpn-instances.json` [verify: code-only]
  - [X] 8.3 Update `bot/bot.sh`: add `disable <name>` command
    that runs `docker stop vpn-<name> && docker update
    --restart=no vpn-<name>` [verify: code-only]
  - [X] 8.4 Keep `restart company` as backward-compat alias
    that restarts all VPN instances. Update `cmd_help()` with
    new commands [verify: code-only]
  - [X] 8.5 Update `healthcheck/check.sh`: read
    `/shared/vpn-instances.json`, check each instance with
    `check_ip`. Include instance name in ntfy alert title
    [verify: code-only]
  - [X] 8.6 Update `dns/entrypoint.sh`: read
    `/shared/vpn-instances.json` for `dns_domains` per
    instance. Generate dnsmasq config with per-instance DNS
    server (from `/shared/{name}-dns-ip`) for each instance's
    domains [verify: code-only]

- [X] 9.0 **User Story:** As a VPN user, I want to deploy and
  verify two simultaneous VPN instances on the VPS so that the
  feature is confirmed working end-to-end [6/6]
  - [X] 9.1 Create `vpn-instances.yaml` on local machine with
    at least two instances (existing L2TP company + one more)
    [verify: manual-run-user]
    → done as part of 007-DOMAIN-ROUTING deployment [live] (2026-04-11)
  - [X] 9.2 Run `python3 generate-vpn.py` and verify it
    produces valid `docker-compose.override.yml` and
    `vpn-instances.json` [verify: manual-run-user]
    → done as part of 007-DOMAIN-ROUTING deployment [live] (2026-04-11)
  - [X] 9.3 Deploy to VPS: `./deploy-push.sh --force &&
    ./rdocker.sh compose up -d --build`
    [verify: manual-run-user]
    → done as part of 007-DOMAIN-ROUTING deployment [live] (2026-04-11)
  - [X] 9.4 Verify both VPN containers are running and tunnels
    are up: `./rdocker.sh compose ps`, check logs for each
    instance [verify: manual-run-user]
    → confirmed during 007 e2e verification [live] (2026-04-11)
  - [X] 9.5 Verify per-instance routing from Mac via Tailscale
    exit node: `traceroute` to a CIDR from each instance
    confirms traffic goes through the correct tunnel
    [verify: manual-run-user]
    → confirmed by user via traceroute [live] (2026-04-11)
  - [X] 9.6 Verify bot `status` command shows per-instance
    health, `restart <name>` restarts only the named instance
    [verify: manual-run-user]
    → confirmed during 007 e2e verification [live] (2026-04-11)

- [X] 10.0 **User Story:** As a VPN user, I want the PRD and
  tech design marked complete so that the feature is properly
  closed out [2/2]
  - [X] 10.1 Update PRD status from Draft to Complete
    [verify: code-only]
  - [X] 10.2 Update tech design status from Draft to Complete
    [verify: code-only]
