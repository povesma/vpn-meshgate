# VPN-001 - Session Decisions & Current State

[TYPE: SESSION-DECISION]
[PROJECT: tailscale-exitnode-vpn]

## L2TP/IPsec PoC Validated
The `poc-l2tp/` PoC was tested and works on a real VPS. Key findings:
- `rightid=%any` required (server identifies by IP not hostname)
- `esp=aes128-sha1,3des-sha1!` (no DH group in ESP phase 2)
- `privileged: true` needed for the container
- PPP DNS may not be pushed by all servers — handled gracefully
- The production `l2tp/entrypoint.sh` is based on this validated PoC

## Architecture Decision: route-init sidecar
Gluetun doesn't support custom entrypoint hooks for `ip route` commands.
Solution: a `route-init` alpine sidecar container that shares gluetun's
network namespace (`network_mode: service:gluetun`), waits for VPN to be
healthy, then adds `ip route` entries for each COMPANY_CIDRS CIDR via
l2tp-vpn's static bridge IP (172.29.0.20).

## Static IPs on bridge_vpn (172.29.0.0/24)
- gluetun: 172.29.0.10
- l2tp-vpn: 172.29.0.20
- dnsmasq: 172.29.0.30
- ntfy: 172.29.0.40
Originally used 172.20.0.0/24 but changed to 172.29.0.0/24 due to
Docker network pool overlap on dev machine.

## DNS Configuration Issue (CURRENT BLOCKER)
Setting `DNS_ADDRESS=172.29.0.30` in gluetun caused healthcheck failures
because dnsmasq isn't running when gluetun starts. Fix: removed
`DNS_ADDRESS` from gluetun — let gluetun use its own built-in DNS.
Still TODO: configure tailscale exit node traffic to use dnsmasq for
split DNS. This needs to be solved in the next session.

## Current Task State
- Tasks 1.0: [X] complete (scaffolding)
- Tasks 2.1-2.3, 3.1-3.2: [X] config done in docker-compose
- Tasks 4.1-4.6: [~] coded, pending VPS testing
- Tasks 5.1-5.3: [~] coded (route-init sidecar)
- Tasks 6.1-6.3: [~] coded (dnsmasq)
- Tasks 7.1-7.4: [~] coded (healthcheck + ntfy)
- Tasks 8.1-8.4: [~] coded (restart, healthchecks, depends_on, README)
- ALL verification tasks (2.4, 3.3, 5.4, 6.4, 7.5, 8.5, 8.6): [ ] need VPS

## Next Steps
1. Fix DNS: figure out how to make tailscale exit node traffic use
   dnsmasq (172.29.0.30) without breaking gluetun's own healthcheck
2. Test `docker compose up gluetun` again after DNS fix
3. Deploy full stack to VPS for real testing
