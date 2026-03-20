# VPN Remote Control via ntfy - Task List

## Relevant Files

- [tasks/001-NTFY-CONTROL/2026-03-20-001-NTFY-CONTROL-prd.md](tasks/001-NTFY-CONTROL/2026-03-20-001-NTFY-CONTROL-prd.md) :: Product Requirements Document
- [tasks/001-NTFY-CONTROL/2026-03-20-001-NTFY-CONTROL-tech-design.md](tasks/001-NTFY-CONTROL/2026-03-20-001-NTFY-CONTROL-tech-design.md) :: Technical Design Document
- [bot/Dockerfile](bot/Dockerfile) :: Alpine image with curl, docker-cli, ping, dig
- [bot/bot.sh](bot/bot.sh) :: Command listener and dispatcher script
- [docker-compose.yml](docker-compose.yml) :: vpn-bot service definition
- [.env.example](.env.example) :: NTFY_CMD_TOPIC variable

## Notes

- TDD is not applicable for this project — deliverables are
  Docker configs and shell scripts. Testing is done via manual
  verification on a real VPS with real VPN credentials.
- The vpn-bot follows the same patterns as `healthcheck/`:
  Alpine image, shell script entrypoint, env var config.
- `.env` is a secrets file — never read or accessed by
  automation tools. Only `.env.example` is managed.
- The vpn-bot must subscribe to a **separate** ntfy topic
  (`vpn-cmd`) from the alerts topic (`vpn-alerts`). The user
  subscribes to both topics in the ntfy app.

## Tasks

- [X] 1.0 **User Story:** As a developer, I want the vpn-bot
  container scaffolding so that the bot can run in gluetun's
  namespace with Docker socket access [4/4]
  - [X] 1.1 Create `bot/Dockerfile`: Alpine 3.21 + curl +
    iputils-ping + bind-tools + docker-cli. Copy `bot.sh`,
    chmod +x, CMD `["/bot.sh"]`.
  - [X] 1.2 Create minimal `bot/bot.sh` stub: logs "vpn-bot
    starting" and sleeps forever (placeholder for real logic).
  - [X] 1.3 Add `vpn-bot` service to `docker-compose.yml`:
    `build: ./bot`, `network_mode: service:gluetun`,
    `volumes: /var/run/docker.sock:/var/run/docker.sock`,
    env vars (`NTFY_CMD_TOPIC`, `NTFY_TOPIC`, `VPS_PUBLIC_IP`,
    `L2TP_CHECK_IP`, `COMPANY_DOMAIN`),
    `depends_on: gluetun: service_healthy, ntfy: service_healthy`,
    `restart: unless-stopped`.
  - [X] 1.4 Add `NTFY_CMD_TOPIC=vpn-cmd` to `.env.example`.
    Verify: `docker compose config` parses without errors.

- [~] 2.0 **User Story:** As a developer, I want the bot to
  subscribe to the ntfy command topic and parse incoming
  messages so that commands can be dispatched [4/4]
  - [~] 2.1 Implement the ntfy JSON stream subscription in
    `bot/bot.sh`: `curl -sf --no-buffer` to
    `http://127.0.0.1:80/${CMD_TOPIC}/json` inside a `while
    read` loop. Add outer retry loop with 5s sleep on
    disconnect.
  - [~] 2.2 Implement JSON message parsing: extract `event`
    and `message` fields using `sed`/`grep`. Skip non-message
    events (`open`, `keepalive`). Trim and lowercase the
    message text.
  - [~] 2.3 Implement the `reply()` function: POST to
    `http://127.0.0.1:80/${ALERT_TOPIC}` with Title and
    Priority headers (same pattern as
    `healthcheck/check.sh:11-19`).
  - [~] 2.4 Implement `case` command dispatcher with stub
    handlers that reply "Not implemented yet" for each
    command. Add startup message: "VPN Bot online" posted
    to alerts topic on connect. Verify: deploy, send a
    message to `vpn-cmd` topic, confirm "Not implemented"
    reply appears in `vpn-alerts`.

- [~] 3.0 **User Story:** As a developer, I want read-only
  commands (`ping`, `status`, `ip`, `help`) so that I can
  check VPN state from my phone [4/4]
  - [~] 3.1 Implement `cmd_ping`: reply with "pong" + system
    uptime from `/proc/uptime`. Priority: default.
  - [~] 3.2 Implement `cmd_status`: check Mullvad (curl
    ifconfig.me, compare to VPS_PUBLIC_IP) and Company VPN
    (ping L2TP_CHECK_IP). Reply with named labels:
    "Mullvad: UP/DOWN (IP)\nCompany: UP/DOWN". Priority:
    default.
  - [~] 3.3 Implement `cmd_ip`: curl ifconfig.me, reply with
    the public IP. Priority: default.
  - [~] 3.4 Implement `cmd_help`: reply with static text
    listing all commands and brief descriptions. Priority:
    low.

- [~] 4.0 **User Story:** As a developer, I want restart
  commands so that I can recover VPN tunnels from my phone
  without SSH [3/3]
  - [~] 4.1 Implement `cmd_restart_company`: reply
    "Restarting Company VPN...", run
    `docker restart l2tp-vpn`, wait for container running,
    reply with post-restart status. Priority: high.
  - [~] 4.2 Implement `cmd_restart_mullvad` confirmation
    flow: write timestamp to `/tmp/vpn-bot-confirm-mullvad`,
    reply with warning (priority: urgent). Implement
    `cmd_confirm`: check confirm file exists and < 30s old,
    if valid reply "Initiating restart..." then
    `docker restart gluetun`, if expired/missing reply
    "Nothing to confirm". Clean up stale confirm files on
    each command.
  - [~] 4.3 Implement `cmd_unknown`: reply "Unknown command:
    {input}. Send `help` for available commands." Ensure no
    shell interpolation of user input (input only passed as
    curl `-d` body).

- [~] 5.0 **User Story:** As a developer, I want dns test and
  rate limiting so that I can troubleshoot DNS and prevent
  command spam [3/3]
  - [~] 5.1 Implement `cmd_dns_test`: resolve a company
    domain (`dig +short @127.0.0.1 ${COMPANY_DOMAIN}`) and
    a public domain (`dig +short @127.0.0.1 example.com`).
    Reply with both results. Priority: default.
  - [~] 5.2 Implement rate limiting: track last command +
    timestamp in `/tmp/vpn-bot-last-cmd`. If same command
    received within 60s, reply "Command already processed,
    please wait" and skip execution. Check at the top of
    the dispatch function before executing any command.
  - [X] 5.3 Update README.md: add a "Remote Control" section
    documenting available commands and how to subscribe to
    the `vpn-cmd` topic from the ntfy app.

- [ ] 6.0 **User Story:** As a developer, I want end-to-end
  verification so that I know all commands work from my
  phone [4/0]
  - [X] 6.1 Deploy to VPS: `deploy-push.sh`, then
    `rdocker.sh compose up -d --build vpn-bot`. Verify
    container starts and shows healthy in `docker ps`.
    Verify "VPN Bot online" message appears in vpn-alerts.
  - [ ] 6.2 Subscribe to `vpn-cmd` topic in ntfy app on
    phone (second subscription alongside `vpn-alerts`).
    Test read-only commands from phone: `ping`, `status`,
    `ip`, `help`, `dns test`. Verify responses arrive in
    `vpn-alerts`.
  - [ ] 6.3 Test `restart company` from phone. Verify
    l2tp-vpn restarts and status response arrives.
  - [ ] 6.4 Test `restart mullvad` from phone. Verify
    warning arrives, send `confirm`, verify gluetun
    restarts and "VPN Bot online" message arrives after
    recovery.
