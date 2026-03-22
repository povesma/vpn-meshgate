# Gluetun Bug: PUT /v1/vpn/status Triggers Full Process Restart

**Date discovered**: 2026-03-21
**Gluetun image**: `qmcgaw/gluetun` (latest as of 2026-03-21)
**VPN type**: WireGuard / Mullvad

---

## Expected Behaviour

Per the gluetun HTTP control server documentation, `PUT /v1/vpn/status` with
body `{"status":"stopped"}` followed by `{"status":"running"}` should cycle
only the VPN tunnel inside the running container — equivalent to disconnecting
and reconnecting WireGuard, without restarting the container process itself.

Combined with `PUT /v1/vpn/settings` to update `server_selection.countries`,
this should enable a hot country switch: update settings → stop tunnel →
start tunnel → tunnel reconnects to new country. Container stays alive
throughout.

## Actual Behaviour

`PUT /v1/vpn/status {"status":"stopped"}` triggers a **full gluetun process
restart**, not a tunnel-only cycle. Evidence from container logs:

```
12:47:10  [bot] PUT /v1/vpn/status {"status":"stopped"}   ← API call
12:47:13  [gluetun] INFO [routing] adding route for 0.0.0.0/0  ← full restart
12:47:13  [gluetun] INFO [healthcheck] listening on 127.0.0.1:9999
12:47:13  [gluetun] INFO [http server] read 1 roles from authentication file
12:47:13  [gluetun] INFO [http server] http server listening on [::]:8000
12:47:18  [gluetun] INFO [ip getter] Public IP address is ... (Turkey)
```

The process exits and reinitialises from scratch, re-reading all environment
variables including `SERVER_COUNTRIES` from the compose-injected env. This
means:

1. The `PUT /v1/vpn/settings` country change is **discarded** — compose env
   wins on restart.
2. The container's network namespace is **destroyed and recreated** — all
   containers sharing `network_mode: service:gluetun` (ntfy, vpn-bot,
   tailscale, healthcheck, route-init) lose their network stack and become
   non-functional until they are also recreated.

## Impact in This Stack

All of the following containers use `network_mode: service:gluetun`:

- `ntfy` — ntfy messaging server
- `vpn-bot` — command listener (the caller of the API)
- `tailscale` — exit node (goes offline)
- `healthcheck` — VPN monitor
- `route-init` — iptables route setup

After a single `PUT /v1/vpn/status stopped` call:
- All of the above lose network connectivity
- `vpn-bot` can no longer receive or send ntfy messages
- `tailscale` exit node goes offline in the Tailscale network
- Recovery requires `docker compose up --force-recreate` on all affected
  containers

## Reproduction Steps

```bash
# 1. Verify gluetun is healthy
docker compose ps gluetun   # STATUS: Up (healthy)

# 2. Call the stop API
curl -sf -X PUT http://127.0.0.1:8000/v1/vpn/status \
  -H "X-API-Key: <key>" \
  -H "Content-Type: application/json" \
  -d '{"status":"stopped"}'

# 3. Observe: gluetun container restarts (check timestamps in logs)
docker logs gluetun --tail 10

# 4. Observe: ntfy / vpn-bot / tailscale lose network
docker exec vpn-bot ip addr show   # shows only loopback — eth0/tun0 gone
```

## Additional Finding: PUT /v1/vpn/settings Is Runtime-Only

`PUT /v1/vpn/settings` with `{"provider":{"server_selection":{"countries":["Germany"]}}}`
returns HTTP 200 and appears to succeed, but the change is **not persisted**.
On the next process start (which the status stop/start immediately triggers),
gluetun re-reads `SERVER_COUNTRIES` from the environment, discarding the
API-set value. The setting change has no observable effect.

## Workaround

To switch Mullvad country without breaking the shared namespace:

1. Run the country switch from a **separate container** that is **not** in
   `network_mode: service:gluetun` — so it survives gluetun's restart.
2. Use `docker compose up -d --force-recreate gluetun` with
   `SERVER_COUNTRIES` overridden via a mounted env file that the switcher
   writes before triggering the recreate.
3. After gluetun is healthy, the switcher calls ntfy directly (via the
   bridge network IP `172.29.0.10:80`) to report the new IP.

This is implemented in the `mullvad-switcher` container (`switcher/`).

## References

- Gluetun control server docs: https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md
- Related issue (runtime settings): https://github.com/qdm12/gluetun/issues/2473
