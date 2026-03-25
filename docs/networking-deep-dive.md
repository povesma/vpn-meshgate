# Networking Deep Dive

How traffic flows through the Tailscale exit node VPN router stack —
routing tables, iptables rules, DNS, MTU, and the dead ends we hit
along the way.

---

## Network Topology

```
VPS Host
│
├── Shared Network Namespace (gluetun owns it)
│   ├── gluetun        — Mullvad WireGuard tunnel (tun0)
│   ├── tailscale      — exit node (tailscale0)
│   ├── route-init     — sets up ip rules, routes, iptables
│   ├── ntfy           — push notifications (:80)
│   ├── healthcheck    — monitors tunnels
│   └── vpn-bot        — remote control
│
└── Docker Bridge (bridge_vpn: 172.29.0.0/24)
    ├── l2tp-vpn  (.20) — company L2TP/IPsec tunnel (ppp0)
    └── dnsmasq   (.30) — split DNS resolver
```

Containers in the shared namespace communicate over localhost.
Containers on the bridge communicate via Docker networking (eth0).

### Interfaces Inside the Shared Namespace

| Interface | MTU | Purpose |
|-----------|-----|---------|
| `tailscale0` | 1280 | Tailscale overlay — all client traffic enters here |
| `tun0` | 1380 | Mullvad WireGuard — general internet exit |
| `eth0` | 1500 | Docker bridge — connects to L2TP and dnsmasq containers |
| `lo` | 65536 | Loopback — gluetun API, Docker internal DNS |

---

## Traffic Paths

### Internet Traffic (Mac → Mullvad → internet)

```
Mac ──tailscale──▶ tailscale0
                       │ FORWARD: tailscale0 → tun0
                       │ NAT: MASQUERADE on tun0
                       ▼
                    tun0 (Mullvad WireGuard) ──▶ internet
```

### Company Traffic (Mac → L2TP → company network)

```
Mac ──tailscale──▶ tailscale0
                       │ ip rule: to COMPANY_CIDRS → main table
                       │ ip route: COMPANY_CIDRS via 172.29.0.20
                       │ FORWARD: tailscale0 → eth0
                       ▼
                    eth0 (Docker bridge)
                       │
                       ▼
                    l2tp-vpn (172.29.0.20)
                       │ NAT: MASQUERADE on ppp0
                       ▼
                    ppp0 (L2TP/IPsec) ──▶ company network
```

### Tailscale WireGuard (direct P2P, bypassing Mullvad)

```
tailscaled marks WireGuard packets with fwmark 0x80000
                       │ ip rule: fwmark 0x80000 → table 201
                       │ table 201: default via 172.29.0.1 (Docker GW)
                       │ iptables OUTPUT: ACCEPT mark 0x80000 on eth0
                       ▼
                    eth0 → Docker bridge → host network → internet
```

### DNS (Mac → MagicDNS or DNAT → dnsmasq)

```
Mac DNS query to 100.100.100.100 (MagicDNS)
  → tailscaled resolves via Headscale-pushed nameservers
  → queries forwarded through exit node tunnel
  → DNAT on tailscale0 port 53 → dnsmasq (172.29.0.30)
  → dnsmasq splits:
    ├── company domains → company DNS (via L2TP)
    └── everything else → public DNS (via Mullvad)
```

---

## IP Policy Routing

All rules are applied by `route-init` container in the gluetun
namespace. They run before gluetun's own rules (priority 100 vs
gluetun's 101).

### Routing Tables

| Table | Content | Purpose |
|-------|---------|---------|
| `main` | Company CIDRs via L2TP, bridge subnet | Company traffic routing |
| `51820` | `default dev tun0` | Gluetun's Mullvad route (catch-all) |
| `52` | Per-peer routes to `tailscale0` | Tailscale return path |
| `201` | `default via 172.29.0.1 dev eth0` | Tailscale WireGuard bypass |

### Policy Rules (priority order)

```
100: to 172.29.0.0/24      → main     # bridge subnet stays local
100: fwmark 0x80000/0xff0000 → 201    # TS WireGuard bypasses Mullvad
100: to COMPANY_CIDRS       → main    # company traffic via L2TP
100: to 100.64.0.0/10       → 52     # TS return traffic → tailscale0
101: not fwmark 0xca6c      → 51820  # everything else → Mullvad
```

**Why priority 100 matters**: gluetun's catch-all rule at priority
101 sends everything to Mullvad (table 51820). Our rules at 100
intercept specific traffic before that happens.

### The Return Path Problem

Without the `100.64.0.0/10 → table 52` rule, return traffic
destined for Tailscale clients (100.64.x.x) hits gluetun's rule
101 and gets routed to tun0 (Mullvad) — a black hole. This rule
ensures responses go back through tailscale0.

**Symptom when missing**: Exit node appears connected, traffic
flows outbound (visible in packet counters), but nothing comes
back. `curl` times out. Interface stats show asymmetric
TX/RX on tailscale0.

---

## Iptables Rules

Gluetun runs a strict kill switch: INPUT, FORWARD, and OUTPUT
policies are all DROP. Every allowed flow must be explicitly
permitted.

### `gluetun/post-rules.txt`

Applied by gluetun at startup. All rules use `-A` (append).

#### DNS Redirection

```bash
# Intercept DNS from Tailscale clients → dnsmasq
iptables -t nat -A PREROUTING -i tailscale0 -p udp --dport 53 \
  -j DNAT --to-destination 172.29.0.30:53
iptables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 53 \
  -j DNAT --to-destination 172.29.0.30:53

# MASQUERADE so dnsmasq responses route back
iptables -t nat -A POSTROUTING -o eth0 -d 172.29.0.30 \
  -p udp --dport 53 -j MASQUERADE
iptables -t nat -A POSTROUTING -o eth0 -d 172.29.0.30 \
  -p tcp --dport 53 -j MASQUERADE

# Accept DNS on INPUT (kill switch would block it)
iptables -A INPUT -i tailscale0 -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i tailscale0 -p tcp --dport 53 -j ACCEPT
```

#### MagicDNS Forwarding

```bash
# Allow tailscaled to reach dnsmasq for DNS forwarding
iptables -A OUTPUT -o eth0 -d 172.29.0.30 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -o eth0 -d 172.29.0.30 -p tcp --dport 53 -j ACCEPT
```

Without these, MagicDNS (tailscaled's built-in DNS proxy) can
receive queries from clients but can't forward them — gluetun's
OUTPUT DROP policy blocks it.

#### Exit Node Traffic

```bash
# Allow tailscaled to send on tailscale0 (responses, MagicDNS)
iptables -A OUTPUT -o tailscale0 -j ACCEPT

# Forward between Tailscale clients and VPN tunnels
iptables -A FORWARD -i tailscale0 -o tun0 -j ACCEPT   # → Mullvad
iptables -A FORWARD -i tun0 -o tailscale0 -j ACCEPT   # ← Mullvad
iptables -A FORWARD -i tailscale0 -o eth0 -j ACCEPT   # → L2TP
iptables -A FORWARD -i eth0 -o tailscale0 -j ACCEPT   # ← L2TP
iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# MASQUERADE outbound on Mullvad tunnel
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
```

**The `OUTPUT -o tailscale0` rule**: Without this, gluetun's
OUTPUT DROP blocks tailscaled from sending any traffic on the
Tailscale interface. This breaks exit node functionality entirely
— traffic enters tailscale0 but responses can never leave.

#### MSS Clamping

```bash
# Clamp TCP MSS to fit Tailscale MTU (1280 - 40 = 1240)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -o tailscale0 -j TCPMSS --set-mss 1240
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -i tailscale0 -j TCPMSS --set-mss 1240
```

#### Tailscale WireGuard Bypass

```bash
# Let TS WireGuard packets bypass Mullvad (fwmark 0x80000)
iptables -A OUTPUT -m mark --mark 0x80000/0xff0000 -o eth0 -j ACCEPT
```

### `l2tp/entrypoint.sh` (runtime rules)

```bash
# MASQUERADE on L2TP tunnel
iptables -t nat -A POSTROUTING -o ppp0 -j MASQUERADE

# MSS clamping on ppp0 (auto-calculated from MTU)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -o ppp0 -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -i ppp0 -j TCPMSS --clamp-mss-to-pmtu
```

### `gluetun/init-routes.sh` (runtime rules)

```bash
# Allow company traffic through gluetun's kill switch
iptables -A OUTPUT -o eth0 -d ${CIDR} -j ACCEPT   # per CIDR
iptables -A INPUT -i eth0 -s ${CIDR} -j ACCEPT    # per CIDR
```

### Dual iptables Backends

Gluetun uses `iptables-nft`. Tailscale uses `iptables-legacy`.
Both are active simultaneously. Tailscale creates its own chains
(`ts-forward`, `ts-postrouting`, `ts-input`) in the legacy tables.

Tailscale's `ts-forward` marks forwarded packets with `0x40000`
and `ts-postrouting` MASQUERADEs them. This works alongside
gluetun's nft rules — packets traverse both backends.

---

## Port Exposure

### Why the WireGuard Port Is Exposed

```yaml
# docker-compose.yml
ports:
  - "41642:41642/udp"   # on gluetun container

# tailscale container
TS_TAILSCALED_EXTRA_ARGS=--port=41642
```

Tailscale runs inside gluetun's namespace (Docker container).
Without port mapping, inbound UDP from peers can't reach tailscaled.
NAT hole-punching would normally handle this, but Docker's
networking layer doesn't forward unsolicited inbound UDP to
containers — the hole-punching packets exit through Docker's NAT
but return packets hit the host and get dropped.

The fixed port (`--port=41642`) ensures Tailscale always listens
on the same port. The Docker port mapping forwards host UDP 41642
to the container. Tailscale's STUN probes discover the VPS's real
public IP on this port, and peers can reach it directly.

**Security**: WireGuard silently drops unauthenticated packets.
Only peers registered in the control server (Headscale) can
establish connections. The port appears closed to port scanners.

---

## MTU Chain and MSS Clamping

```
Hop                     MTU    MSS (TCP)
────────────────────────────────────────
Mac local interface     1500   1460
Tailscale overlay       1280   1240  ← clamped in post-rules.txt
Docker bridge           1500   1460
ppp0 (L2TP)             1400   ~1360 ← clamped by --clamp-mss-to-pmtu
IPsec ESP overhead      ~52 bytes
Wire                    ~1348
```

Two MSS clamp points prevent fragmentation:
1. **tailscale0** (post-rules.txt): Hard-set to 1240
2. **ppp0** (entrypoint.sh): Auto-calculated from ppp0 MTU

`tcp_mtu_probing=1` is also enabled in the L2TP container as a
fallback for PMTUD.

---

## DNS Architecture

### Split DNS via dnsmasq

dnsmasq is configured with:
- Company domains → company DNS server (obtained from L2TP peer)
- Everything else → public DNS (via Mullvad)

The company DNS IP is extracted from the PPP connection:

```bash
# /etc/ppp/ip-up (inside L2TP container)
echo "$DNS1" > /shared/company-dns-ip
```

dnsmasq reads this from a shared Docker volume.

### MagicDNS Integration

Mac clients use MagicDNS (`100.100.100.100`) as their DNS server.
MagicDNS is built into tailscaled. It forwards non-Tailnet queries
to upstream nameservers configured in the control server
(Headscale).

Headscale's DNS config should include:
- Global nameservers (e.g., `1.1.1.1`) — these get DNAT'd to
  dnsmasq on the VPS
- Split DNS for company domain → VPS Tailscale IP — queries go
  directly to dnsmasq via the Tailscale network

The DNAT rules in post-rules.txt intercept any DNS query arriving
on tailscale0 (regardless of destination) and redirect to dnsmasq.
This means even if MagicDNS forwards to `1.1.1.1`, the query hits
dnsmasq instead.

---

## Sysctl Tuning

### gluetun (via docker-compose.yml sysctls)

| Parameter | Value | Why |
|-----------|-------|-----|
| `net.ipv4.conf.all.src_valid_mark` | 1 | Required for fwmark-based policy routing |
| `net.ipv4.tcp_rmem` | 4096 262144 16777216 | Large receive buffers for high-latency VPN path |
| `net.ipv4.tcp_wmem` | 4096 262144 16777216 | Large send buffers |

### l2tp-vpn (via entrypoint.sh sysctl)

| Parameter | Value | Why |
|-----------|-------|-----|
| `net.ipv4.tcp_mtu_probing` | 1 | Enables TCP-level PMTUD for variable MTU path |
| `net.core.rmem_max` | 16777216 | Socket buffer hard limit |
| `net.core.wmem_max` | 16777216 | Socket buffer hard limit |

---

## Dead Ends and Failed Approaches

Things we tried that didn't work, documented so nobody repeats
them.

### 1. Fwmark-Only Routing (No Port Exposure)

**Idea**: Route Tailscale WireGuard traffic via fwmark `0x80000`
to table 201 (host network), without exposing any UDP port.

**What happened**: STUN probes went out correctly and discovered
the VPS real IP. But return UDP packets from peers hit the host
and Docker's networking dropped them — there's no port mapping,
so the host doesn't know to forward inbound UDP to the container.

NAT hole-punching normally handles this, but Docker's bridge
networking doesn't preserve hole-punch state for container-internal
sockets. The STUN hole gets punched at the Docker NAT layer, but
the kernel doesn't associate the return path with the container.

**Symptom**: `tailscale ping` shows DERP relay forever.
`tailscale netcheck` shows correct external IP but direct
connection never establishes.

**Resolution**: Exposed a fixed UDP port (41642) on the host.

### 2. Sport-Based Routing

**Idea**: Route packets with source port 41642 (Tailscale
WireGuard) via the host instead of Mullvad.

```bash
ip rule add sport 41642 lookup 201 priority 100
```

**What happened**: Worked for WireGuard handshakes but not for
STUN probes, DERP connections, or HTTPS control traffic — those
use ephemeral source ports.

**Resolution**: Fwmark-based routing (0x80000) catches all
Tailscale control traffic regardless of port.

### 3. Hex Fwmark in post-rules.txt (Delete Rules)

**Idea**: Use `-m mark --mark 0x80000` in both append and delete
rules in gluetun's post-rules.txt.

**What happened**: Append (`-A`) rules work fine — gluetun passes
them directly to the iptables binary. But delete (`-D`) rules go
through gluetun's internal Go parser, which has a bug: when it
sees `-m mark`, it expects `!` (negation) as the next token. If
it sees `--mark` instead, it errors out with "unsupported match
mark."

**Resolution**: Only use append rules. No `-D` rules with `-m
mark` in post-rules.txt.

### 4. Broad Fwmark Routing Without Mask

**Idea**: `ip rule add fwmark 0x80000 lookup 201`

**What happened**: The fwmark `0x80000` without a mask matched
too broadly. Tailscale's `ts-forward` chain marks forwarded exit
node traffic with `0x40000` — and since both marks share bits in
the upper range, the routing rule caught exit node data traffic
too, breaking internet access for clients.

**Resolution**: Use mask `0xff0000` to match only the specific
byte: `fwmark 0x80000/0xff0000`.

### 5. Missing Return Path Rule

**Idea**: Just add the fwmark bypass and port exposure — return
traffic will find its way back via conntrack.

**What happened**: Outbound traffic from tailscale0 was forwarded
to tun0 (Mullvad) and MASQUERADEd. Return packets from Mullvad
arrived on tun0 with destination `100.64.0.x` (client Tailscale
IP). The routing decision used ip rules — rule 101
(`not fwmark 0xca6c → table 51820`) caught the return packets
and routed them BACK to tun0 instead of tailscale0. Routing loop.

**Symptom**: `tailscale0 TX` counter near zero while `tun0 RX`
counter climbed. Exit node appeared connected but all traffic
timed out. Interface stats showed the asymmetry clearly.

**Resolution**: Added `ip rule add to 100.64.0.0/10 lookup 52
priority 100` to route Tailscale CGNAT traffic to table 52
(Tailscale's own routing table with per-peer routes on
tailscale0).

### 6. Missing OUTPUT Rule on tailscale0

**Idea**: FORWARD rules are enough — tailscaled handles traffic
internally.

**What happened**: Gluetun's OUTPUT policy is DROP. Tailscaled
runs as a process in the shared namespace and needs to send
packets on tailscale0 (exit node responses, MagicDNS replies).
Without an OUTPUT ACCEPT rule for tailscale0, tailscaled could
receive traffic but never respond.

**Symptom**: `nslookup` to MagicDNS (100.100.100.100) returned
"Operation not permitted." Exit node appeared up but nothing
worked.

**Resolution**: Added `iptables -A OUTPUT -o tailscale0 -j ACCEPT`
to post-rules.txt.

### 7. MagicDNS SERVFAIL for Internal Domains

**Idea**: MagicDNS handles DNS transparently — just enable it and
everything works.

**What happened**: MagicDNS forwarded queries to upstream DNS
servers configured in Headscale. For public domains this worked,
but company-internal domains returned SERVFAIL because public DNS
servers don't know about them.

Setting `TS_ACCEPT_DNS=false` on the VPS was even worse — MagicDNS
had zero upstream servers and couldn't resolve anything.

**Resolution**: Configure Headscale to push split DNS — company
domain queries go to the VPS Tailscale IP, which then hits the
DNAT rule and reaches dnsmasq. Global queries go to a public DNS
server (e.g., `1.1.1.1`), which also gets DNAT'd to dnsmasq on
the VPS.

### 8. xl2tpd 10 Mbps Bandwidth Cap

**Idea**: xl2tpd.conf without `tx bps` / `rx bps` settings uses
defaults.

**What happened**: xl2tpd has a compiled-in `DEFAULT_MAX_BPS =
10000000` (10 Mbps) that's advertised during L2TP tunnel
negotiation. If the peer respects it, throughput is hard-capped.

**Symptom**: L2TP throughput limited to ~10 Mbps.

**Resolution**: Added `tx bps = 100000000` and
`rx bps = 100000000` to the `[lac]` section of xl2tpd.conf
(generated in entrypoint.sh). However, this turned out not to be
the primary bottleneck — Tailscale overlay throughput was the
actual limit.

### 9. Port 41641 Already in Use

**Idea**: Use Tailscale's default WireGuard port 41641.

**What happened**: The VPS host had its own Tailscale instance
running, already binding port 41641.

**Resolution**: Used port 41642 instead.

---

## Rebuilding from Scratch

If the environment is destroyed, here's the order of operations:

1. **Host prerequisites**:
   - `modprobe l2tp_ppp` (persist in `/etc/modules-load.d/`)
   - `sysctl -w net.ipv4.ip_forward=1`

2. **Create `.env`** from `.env.example` with all credentials

3. **`docker compose up -d`** — starts everything in dependency
   order

4. **Verify gluetun** is healthy:
   `docker exec gluetun wget -qO- http://127.0.0.1:9999/v1/publicip/ip`

5. **Verify route-init** applied rules:
   `docker exec route-init ip rule show` — should show table 201
   and company CIDR rules at priority 100

6. **Verify Tailscale** authenticated and advertising:
   `docker exec tailscale tailscale status`

7. **Verify L2TP** tunnel is up:
   `docker exec l2tp-vpn ip link show ppp0`

8. **Verify DNS**:
   `docker exec dnsmasq dig @127.0.0.1 example.com +short`

9. **Approve exit node** in Headscale:
   ```
   headscale routes list
   headscale routes enable -r <route-id>
   ```

10. **Test from Mac**:
    ```
    tailscale set --exit-node=<hostname>
    curl ifconfig.me          # should show Mullvad IP
    ping <company-host-ip>    # should work via L2TP
    nslookup <company-domain> # should resolve via dnsmasq
    ```

### Key Config Files

| File | What it does | When it runs |
|------|-------------|--------------|
| `docker-compose.yml` | Container definitions, ports, env | `docker compose up` |
| `gluetun/post-rules.txt` | iptables rules in gluetun namespace | gluetun startup |
| `gluetun/init-routes.sh` | ip rules, routes, iptables for routing | route-init startup |
| `l2tp/entrypoint.sh` | IPsec, xl2tpd, PPP, MSS clamping | l2tp-vpn startup |
| `.env` | All credentials and config variables | sourced by compose |

### Headscale DNS Config

The control server needs DNS settings for MagicDNS to work:

```yaml
dns:
  nameservers:
    global:
      - 1.1.1.1           # gets DNAT'd to dnsmasq on the VPS
    split:
      company.example.com:
        - <vpn-gate-tailscale-ip>   # dnsmasq via Tailscale
```
