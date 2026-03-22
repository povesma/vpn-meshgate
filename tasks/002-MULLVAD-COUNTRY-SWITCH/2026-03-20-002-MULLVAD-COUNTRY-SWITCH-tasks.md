# Mullvad Country Switcher - Task List

## Relevant Files

- [tasks/002-MULLVAD-COUNTRY-SWITCH/2026-03-20-002-MULLVAD-COUNTRY-SWITCH-prd.md](tasks/002-MULLVAD-COUNTRY-SWITCH/2026-03-20-002-MULLVAD-COUNTRY-SWITCH-prd.md) :: Product Requirements Document
- [tasks/002-MULLVAD-COUNTRY-SWITCH/2026-03-20-002-MULLVAD-COUNTRY-SWITCH-tech-design.md](tasks/002-MULLVAD-COUNTRY-SWITCH/2026-03-20-002-MULLVAD-COUNTRY-SWITCH-tech-design.md) :: Technical Design Document
- [bot/bot.sh](bot/bot.sh) :: Bot command handlers — country lookup, list, switch dispatch
- [switcher/switcher.sh](switcher/switcher.sh) :: Mullvad-switcher sidecar — compose recreate, health poll, IP verify
- [switcher/Dockerfile](switcher/Dockerfile) :: Alpine + docker-cli + docker-cli-compose + curl
- [docker-compose.yml](docker-compose.yml) :: mullvad-switcher service, switcher-data volume, gluetun auth mount
- [gluetun/auth/config.toml.example](gluetun/auth/config.toml.example) :: API key auth template (real file generated on VPS)
- [vps-secrets-init.sh](vps-secrets-init.sh) :: Generates GLUETUN_API_KEY and config.toml on VPS
- [.env.example](.env.example) :: GLUETUN_API_KEY, COMPOSE_PROJECT_DIR variables
- [.gitignore](.gitignore) :: Excludes gluetun/auth/config.toml (contains secret)
- [docs/gluetun-vpn-status-api-bug.md](docs/gluetun-vpn-status-api-bug.md) :: Documents why HTTP API approach was abandoned

## Notes

- TDD is not applicable — deliverables are shell/config files tested by
  manual verification on the live VPS.
- **Implementation pivoted from HTTP API to sidecar approach.** Gluetun's
  `PUT /v1/vpn/status` triggers a full process restart (not just a tunnel
  cycle), destroying the shared network namespace and killing all dependent
  containers. See `docs/gluetun-vpn-status-api-bug.md` for details.
- The mullvad-switcher runs on bridge_vpn (not in gluetun's namespace) so it
  survives gluetun restarts. It uses `docker compose` via the Docker socket
  to recreate gluetun with the new `MULLVAD_COUNTRY` env var, then recreates
  all namespace-dependent containers (ntfy, healthcheck, route-init, tailscale,
  vpn-bot).
- The switcher reads the compose file from `/project/docker-compose.yml`
  (bind-mounted from the host project dir) and uses `--env-file /project/.env`
  for secrets. `--project-directory` points to the host path so the Docker
  daemon resolves relative volume mounts correctly.
- After compose or gluetun changes: `deploy-push.sh` then
  `rdocker.sh compose up -d --force-recreate gluetun vpn-bot`.
- After switcher changes: `deploy-push.sh` then
  `rdocker.sh compose up -d --build --force-recreate mullvad-switcher`.

## Tasks

- [X] 1.0 **User Story:** As a developer, I want a country lookup
  function and list command so that user keywords are safely mapped
  and discoverable [2/2]
  - [X] 1.1 Add `mullvad_country_name()` lookup to `bot/bot.sh`.
  - [X] 1.2 Add `cmd_mullvad_list()` and update `cmd_help()`.

- [X] 2.0 **User Story:** As a developer, I want the mullvad-switcher
  sidecar so that country switches can happen without killing the bot
  or other namespace-dependent containers [4/4]
  - [X] 2.1 Create `switcher/Dockerfile` (Alpine + docker-cli +
    docker-cli-compose + curl) and `switcher/switcher.sh` with
    file-based IPC: watches `/data/switch-request`, performs
    `docker compose up -d --force-recreate gluetun` with
    `MULLVAD_COUNTRY` override, polls health via `docker inspect`,
    recreates dependent containers, reports result.
  - [X] 2.2 Add `mullvad-switcher` service to `docker-compose.yml`:
    bridge_vpn network (172.29.0.40), Docker socket mount,
    switcher-data volume, project dir bind-mount, env vars
    (COMPOSE_PROJECT_NAME, COMPOSE_PROJECT_DIR, NTFY_CMD_TOPIC).
  - [X] 2.3 Add `switcher-data` shared volume between vpn-bot and
    mullvad-switcher for IPC files (switch-request, switch-result).
  - [X] 2.4 Set up gluetun HTTP control server auth: create
    `gluetun/auth/config.toml.example`, mount `./gluetun/auth` into
    gluetun, add `GLUETUN_API_KEY` to `.env.example` and vpn-bot env,
    add `gluetun/auth/config.toml` to `.gitignore`, create
    `vps-secrets-init.sh` for on-VPS key generation.

- [X] 3.0 **User Story:** As a developer, I want the bot to dispatch
  country switch commands to the switcher so that `mullvad uk`
  triggers the full switch flow [2/2]
  - [X] 3.1 Implement `cmd_mullvad_switch()` in `bot/bot.sh`:
    validate keyword via lookup, check /data volume mounted, check
    no switch in progress, write country name to `/data/switch-request`.
  - [X] 3.2 Add `mullvad list` and `mullvad <cc>` to the bot's
    `case` dispatcher.

- [X] 4.0 **User Story:** As a developer, I want the switcher to
  verify country changes and report clearly so that failed switches
  are detected [3/3]
  - [X] 4.1 Capture pre-switch IP before recreating gluetun.
  - [X] 4.2 Compare pre/post IPs: if unchanged, report failure
    ("IP unchanged"); if changed, report success with old → new IP.
  - [X] 4.3 Fix compose path resolution: use `-f /project/docker-compose.yml`
    for the container-side compose file, `--env-file /project/.env` for
    secrets, and `--project-directory` for the host path (daemon-side
    volume resolution).

- [X] 5.0 **User Story:** As a developer, I want end-to-end
  verification so that the feature is production-ready [3/3]
  - [X] 5.1 Deploy and test country switch from ntfy (Ukraine).
    Verified: gluetun recreated with correct SERVER_COUNTRIES,
    dependents recreated, IP changed, success notification sent.
  - [X] 5.2 Verify firewall rules survive gluetun recreate:
    post-rules.txt correctly mounted and applied (tun0 MASQUERADE).
  - [X] 5.3 Committed: `bot/bot.sh`, `docker-compose.yml`,
    `.env.example`, `.gitignore`, `gluetun/auth/config.toml.example`,
    `gluetun/post-rules.txt`, `switcher/Dockerfile`, `switcher/switcher.sh`,
    `deploy-push.sh`, `vps-secrets-init.sh`.
