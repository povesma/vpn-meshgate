# 002-MULLVAD-COUNTRY-SWITCH: Mullvad Country Switcher via Bot — PRD

**Status**: Complete
**Created**: 2026-03-20
**Author**: Claude (via rlm-mem analysis)

---

## Context

The vpn-bot already supports remote restart of the Mullvad (Gluetun) container
via ntfy. The next logical step is to allow switching the Mullvad exit country
from the phone without SSH — enabling geographic flexibility for privacy,
streaming, and corporate access scenarios.

### Current State

- `bot/bot.sh` handles `restart mullvad` (with confirm flow) and several other
  commands via ntfy JSON stream subscription
- `docker-compose.yml` passes `SERVER_COUNTRIES=${MULLVAD_COUNTRY}` to the
  `gluetun` container as a static env var from `.env`
- Gluetun exposes a control API at `http://127.0.0.1:9999` (used by the
  healthcheck), but **does not support hot country switching** — a container
  restart with a new `SERVER_COUNTRIES` value is required
- `docker update --env` can override env vars on a running/stopped container
  before restart — no compose file access needed from the bot

### Constraints

- The bot runs in `network_mode: service:gluetun` with Docker socket access
- No compose CLI available inside the bot container
- `.env` is a secrets file — the bot must not read or modify it
- Country changes must survive across container restarts (persisted via
  `docker update`, which writes to Docker's container config)

---

## Problem Statement

**Who**: Developer using the VPS as a Tailscale exit node
**What**: Cannot change Mullvad's exit country without SSH access to the VPS
**Why**: Requires country-specific IP for privacy, bypassing geo-restrictions,
or testing connectivity from different regions
**When**: Ad-hoc from phone — while traveling, accessing region-locked services,
or troubleshooting

---

## Goals

### Primary Goal
Allow switching Mullvad's exit country via a single ntfy message from the phone,
with real-time progress updates and a final confirmation of the new IP.

### Secondary Goals
- Minimize downtime during the switch (~15s)
- Provide live stage-by-stage feedback so the user knows what's happening
- Persist the new country across future gluetun restarts
- Support a comprehensive set of countries for maximum flexibility

---

## User Stories

### Epic
As a developer, I want to switch Mullvad's exit country from my phone via ntfy
so that I can change my VPN exit region without SSH access.

### User Story 1 — Country Switch
**As a** developer using the vpn-bot
**I want** to send `mullvad <country>` to the vpn-cmd topic
**So that** Gluetun restarts with the new country and I receive confirmation

**Acceptance Criteria**:
- [ ] Sending `mullvad uk` switches exit to United Kingdom
- [ ] Bot immediately replies with a warning: "Switching to UK, ~15s downtime"
- [ ] Bot sends stage updates: "Stopping tunnel...", "Restarting with UK...",
  "Waiting for tunnel..."
- [ ] Bot waits for gluetun healthcheck to pass (up to 60s)
- [ ] Bot replies with final report: new public IP + country label
- [ ] New country persists if gluetun is later restarted (docker update persists it)
- [ ] Rate limiting applies (60s cooldown, same as other commands)

### User Story 2 — Country Listing
**As a** developer
**I want** to send `mullvad list` (or see it in `help`)
**So that** I can see available country codes without guessing

**Acceptance Criteria**:
- [ ] `mullvad list` replies with all supported country keywords and their
  full names
- [ ] `help` output mentions `mullvad <country>` with a note to use
  `mullvad list`

### User Story 3 — Invalid Country
**As a** developer
**I want** a clear error if I type an unsupported country
**So that** I know what went wrong without triggering a restart

**Acceptance Criteria**:
- [ ] `mullvad xyz` replies "Unknown country 'xyz'. Send 'mullvad list' for
  available countries." — no restart triggered

---

## Supported Countries

The following keyword → Gluetun country-name mappings must be supported:

| Keyword      | SERVER_COUNTRIES value  |
|-------------|------------------------|
| `us`        | United States          |
| `uk`        | United Kingdom         |
| `nl`        | Netherlands            |
| `de`        | Germany                |
| `fr`        | France                 |
| `ch`        | Switzerland            |
| `se`        | Sweden                 |
| `fi`        | Finland                |
| `be`        | Belgium                |
| `cy`        | Cyprus                 |
| `ca`        | Canada                 |
| `jp`        | Japan                  |
| `sg`        | Singapore              |
| `th`        | Thailand               |
| `id`        | Indonesia              |
| `il`        | Israel                 |
| `tr`        | Turkey                 |
| `al`        | Albania                |
| `ua`        | Ukraine                |
| `za`        | South Africa           |
| `ng`        | Nigeria                |

21 countries total. Keywords are standard 2-letter ISO codes for familiarity.

---

## Functional Requirements

1. **FR-1**: Parse `mullvad <keyword>` command in the bot's `case` dispatcher
   - Priority: High
   - Keywords are 2-letter ISO codes (see table above)
   - Unknown keywords return an error reply, no restart

2. **FR-2**: Country switch procedure (in order)
   - Priority: High
   - Step 1: Reply "⚠️ Switching Mullvad to {Country}... (~15s downtime)"
   - Step 2: `docker update --env SERVER_COUNTRIES="{Country}" gluetun`
   - Step 3: `docker restart gluetun`
   - Step 4: Poll gluetun healthcheck (`wget -qO- http://127.0.0.1:9999/v1/publicip/ip`)
     every 3s, up to 60s timeout
   - Step 5: On success — reply "✅ Mullvad switched to {Country}. New IP: {ip}"
   - Step 6: On timeout — reply "⚠️ Gluetun did not recover in 60s. Check logs."

3. **FR-3**: Stage notifications during switch
   - Priority: Medium
   - Send intermediate ntfy updates at key steps (not just start/end)
   - Keeps the user informed that the bot is alive during the ~15s blackout

4. **FR-4**: `mullvad list` command
   - Priority: Medium
   - Reply with a formatted list of all supported keywords and country names

5. **FR-5**: Persist country across gluetun restarts
   - Priority: High
   - `docker update` writes to Docker's container config — the new
     `SERVER_COUNTRIES` value survives future `docker restart gluetun` calls
   - No `.env` modification required

6. **FR-6**: `help` command updated
   - Priority: Low
   - Add `mullvad <country>` and `mullvad list` to the help text

---

## Non-Functional Requirements

1. **NFR-1 — Downtime**: Switch must complete (gluetun healthy again) within 60s
2. **NFR-2 — Safety**: User input (keyword) must never be interpolated into shell
   commands directly — only passed through a validated lookup table
3. **NFR-3 — No `.env` access**: Country state stored in Docker container config
   only; `.env` is never read or modified by the bot
4. **NFR-4 — Consistency**: Follows existing bot patterns — same `reply()`
   function, same rate limiting, same ntfy topic

---

## Out of Scope

- Selecting specific servers or cities (country-level only)
- Scheduling automatic country rotation
- Reverting to the `.env` default country automatically
- Supporting VPN providers other than Mullvad/Gluetun

---

## Success Metrics

1. `mullvad uk` → bot replies with UK IP within 60s
2. All 21 country keywords successfully switch gluetun
3. Country persists after manual `docker restart gluetun`
4. Invalid keyword returns error without restarting gluetun

---

## References

### From Codebase
- `bot/bot.sh` — existing command pattern, `reply()`, `check_rate_limit()`
- `docker-compose.yml` — gluetun `SERVER_COUNTRIES` env var, control API port 9999
- `healthcheck/check.sh` — healthcheck uses `wget` against `9999/v1/publicip/ip`

### Technical Notes
- Gluetun control API **does not support** runtime country changes (confirmed
  via context7 docs review)
- `docker update --env` persists the change in Docker's container metadata
- `docker update --env` replaces the entire env list for that key — only
  `SERVER_COUNTRIES` needs to change, all other env vars stay intact because
  `docker update --env` appends/overrides a single variable

---

**Implementation Notes**:

The original design assumed `docker update --env` + `docker restart` from the
bot. This was replaced by a sidecar-based approach after discovering that:
1. `docker compose up` overwrites `docker update` env changes
2. The bot shares gluetun's namespace and dies when gluetun restarts
3. Gluetun's HTTP API `PUT /v1/vpn/status` triggers a full process restart

See tech-design for the final sidecar architecture.
