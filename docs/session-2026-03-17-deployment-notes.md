# VPS Deployment Notes - 2026-03-17

## Verified Working
- Mullvad WireGuard via gluetun (Turkey/Istanbul exit IP)
- Tailscale exit node (Mac routes internet through Mullvad)
- L2TP/IPsec company VPN (ppp0 up, company network reachable)
- Company network reachable from Mac via Tailscale exit node
- Healthcheck detecting Mullvad status via ifconfig.me

## Not Working Yet
- **Company DNS via dnsmasq** — Docker embedded DNS (127.0.0.11) intercepts port 53 via iptables NAT. Dnsmasq changed to port 5353 but integration with gluetun DNS not completed.

## Critical Fixes Applied

### Gluetun healthcheck
`wget --spider` → `wget -qO /dev/null` (HEAD not supported by gluetun health endpoint). Added `start_period: 60s`.

### Healthcheck in gluetun namespace
`network_mode: service:gluetun`, uses `https://ifconfig.me` directly through VPN tunnel instead of gluetun API (auth issues on port 8000, empty response on port 9999).

### L2TP kernel module prerequisite
`sudo apt install linux-modules-extra-$(uname -r) && sudo modprobe l2tp_ppp`. Without it, xl2tpd userspace fallback is broken. Persist with `echo l2tp_ppp | sudo tee /etc/modules-load.d/l2tp.conf`.

### PPP DNS extraction
Alpine pppd doesn't write `/etc/ppp/resolv.conf` despite `usepeerdns`. Fix: custom `/etc/ppp/ip-up` script writes `$DNS1` to `/shared/company-dns-ip`. Plus 15s polling loop fallback.

### Wait for ppp0 IP assignment
Changed from `ip link show ppp0` to `ip -4 addr show ppp0` with 60s timeout. Routes added before IP assignment get lost.

### MASQUERADE on l2tp container
`iptables -t nat -A POSTROUTING -o ppp0 -j MASQUERADE` — required for return traffic from company network to reach gluetun.

### Policy routing rules (init-routes.sh)
- `ip rule add to <CIDR> lookup main priority 100` — bypasses WireGuard table 51820 catch-all for company CIDRs
- `ip rule add to 100.64.0.0/10 lookup 52 priority 100` — routes Tailscale return traffic to tailscale0 instead of tun0
- `iptables OUTPUT/INPUT` rules for company CIDRs on gluetun firewall

### FORWARD rules (post-rules.txt)
Gluetun nftables FORWARD policy is DROP. Added: tailscale0↔tun0, tailscale0↔eth0, RELATED/ESTABLISHED.

### Tailscale advertise-routes
`--advertise-routes=${COMPANY_CIDRS}` required — without it Tailscale drops company-destined packets. Routes must be approved in Headscale.

### route-init Dockerfile
Created `gluetun/Dockerfile.route-init` with iproute2, iptables, wget. Plain alpine has no iptables.

## Known Issues
- Docker network overlap: `vpn_bridge_vpn` vs `tailscale-exitnode-vpn_bridge_vpn`. Fix: `docker network prune -f` before starting.
- Remote `docker compose` via SSH context has quirks — file changes require manual upload before running compose commands.
