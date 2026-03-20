# Tailscale Exit Node VPN Router

A self-hosted Docker Compose stack that runs on a Linux VPS and acts as a
Tailscale exit node with policy-based routing. Select it as your exit node
and traffic is automatically split:

- **Company traffic** (`COMPANY_CIDRS`) routes through L2TP/IPsec
- **All other traffic** routes through Mullvad WireGuard
- **DNS** is split: company domains via company DNS, everything else via Mullvad

## Architecture

```
┌──────────────────────────────────────────────────┐
│                  VPS (host)                       │
│                                                   │
│  ┌─────────────── Shared Namespace ────────────┐  │
│  │  gluetun (Mullvad WG)  +  tailscale (exit)  │  │
│  │  + route-init  +  ntfy (:80)  + healthcheck │  │
│  │  + vpn-bot (remote control)                 │  │
│  └──────────────────┬──────────────────────────┘  │
│                     │ bridge_vpn (172.29.0.0/24)  │
│  ┌──────────┐  ┌────┴────┐                        │
│  │ l2tp-vpn │  │ dnsmasq │                        │
│  │  .0.20   │  │  .0.30  │                        │
│  └──────────┘  └─────────┘                        │
└──────────────────────────────────────────────────┘
```

## Prerequisites

- Linux VPS with Docker and Docker Compose
- L2TP kernel module (required for xl2tpd PPP sessions):
  ```bash
  sudo apt install linux-modules-extra-$(uname -r)
  sudo modprobe l2tp_ppp
  # Make persistent across reboots:
  echo l2tp_ppp | sudo tee /etc/modules-load.d/l2tp.conf
  ```
- IP forwarding enabled: `sysctl -w net.ipv4.ip_forward=1`
- Headscale server (or Tailscale coordination server)
- Mullvad VPN account (WireGuard credentials)
- Company L2TP/IPsec VPN credentials

## Setup

1. Clone this repo on your VPS:
   ```bash
   git clone <repo-url> && cd tailscale-exitnode-vpn
   ```

2. Create `.env` from the template:
   ```bash
   cp .env.example .env
   ```

3. Edit `.env` with your actual credentials.

4. Start the stack:
   ```bash
   docker compose up -d
   ```

5. Approve the exit node route in Headscale:
   ```bash
   headscale routes list
   headscale routes enable -r <route-id>
   ```

6. On your Mac, select the exit node:
   ```bash
   tailscale set --exit-node=<TS_HOSTNAME>
   ```

## Verification

```bash
# Check all containers are healthy
docker ps

# From your Mac (with exit node active):
curl ifconfig.me              # Should show Mullvad IP
ping <L2TP_CHECK_IP>          # Should reach company network
dig example.com               # Should resolve via Mullvad DNS
dig <host>.<COMPANY_DOMAIN>   # Should resolve via company DNS
```

## Notifications

The stack includes ntfy for push notifications when VPN tunnels go
down or recover. ntfy runs in the Tailscale network namespace, so
it's reachable via MagicDNS from any device on your tailnet.

1. Install the ntfy app ([ntfy.sh](https://ntfy.sh)) on your phone
2. Add a subscription with the server URL and topic:
   ```
   http://<TS_HOSTNAME>/vpn-alerts
   ```
   For example, if `TS_HOSTNAME=vpn-router`:
   ```
   http://vpn-router/vpn-alerts
   ```
3. The topic name matches your `NTFY_TOPIC` env var (default:
   `vpn-alerts`)

## Remote Control

The stack includes a `vpn-bot` container that listens for commands on a
separate ntfy topic, allowing you to manage VPN tunnels from your phone.

1. Subscribe to the command topic in the ntfy app:
   ```
   http://<TS_HOSTNAME>/vpn-cmd
   ```
2. Send commands and receive responses all within the `vpn-cmd` topic.

**Available commands:**

| Command | Description |
|---|---|
| `ping` | Check bot is alive (returns uptime) |
| `status` | Show Mullvad and Company VPN tunnel status |
| `ip` | Show current public exit IP |
| `restart company` | Restart L2TP tunnel |
| `restart mullvad` | Restart Mullvad tunnel (requires `confirm`) |
| `disable company` | Stop L2TP permanently (survives reboots; SSH to re-enable) |
| `dns test` | Test split DNS resolution |
| `help` | List available commands |

Restarting Mullvad requires a two-step confirmation: send `restart mullvad`,
then `confirm` within 30 seconds.

To re-enable Company VPN after `disable company`, SSH to the VPS and run:
```bash
docker update --restart=unless-stopped l2tp-vpn
docker start l2tp-vpn
```

## Troubleshooting

```bash
# Check individual container logs
docker compose logs gluetun
docker compose logs l2tp-vpn
docker compose logs tailscale
docker compose logs dnsmasq
docker compose logs healthcheck

# Shell into a container
docker exec -it l2tp-vpn sh
docker exec -it gluetun sh

# Check routing inside gluetun namespace
docker exec gluetun ip route
docker exec gluetun curl ifconfig.me

# Check L2TP tunnel
docker exec l2tp-vpn ip addr show ppp0
docker exec l2tp-vpn ip route
```

## Configuration

All configuration is via `.env`. See `.env.example` for all variables.

Key variables:
| Variable | Description |
|---|---|
| `COMPANY_CIDRS` | Comma-separated CIDRs routed through company VPN |
| `COMPANY_DOMAIN` | Domain suffix(es) for split DNS |
| `MULLVAD_COUNTRY` | Mullvad server country |
| `VPS_PUBLIC_IP` | Your VPS public IP (for health check) |
| `NTFY_TOPIC` | ntfy notification topic name |
| `NTFY_CMD_TOPIC` | ntfy command topic for remote control |
