# 004-L2TP-SPEED: Company VPN Speed Investigation & Fix — Technical Design

**Status**: Complete
**PRD**: [004-L2TP-SPEED-prd.md](2026-03-25-004-L2TP-SPEED-prd.md)
**Created**: 2026-03-25

---

## Overview

Company VPN throughput (1–10 Mbps) is far below what Mullvad achieves on the
same VPS. Since the L2TP path has fewer external hops than Mullvad, the
bottleneck must be in our infrastructure. This document defines a systematic
diagnostic approach and the fixes for each identified root cause.

The design is structured as: **measure → diagnose → fix → verify**, with
specific metrics and commands for each potential bottleneck.

---

## Current Architecture — Traffic Paths

### Company Traffic (slow)

```
Mac ──Tailscale──▶ gluetun (tailscale0, MTU 1280)
                        │
                        │ ip route: COMPANY_CIDRS via 172.29.0.20 dev eth0
                        │ ip rule: to COMPANY_CIDRS lookup main priority 100
                        ▼
                   Docker bridge (eth0, MTU 1500)
                        │
                        │ forwarded — no NAT (source IP preserved)
                        ▼
                   L2TP container (eth0: 172.29.0.20)
                        │
                        │ MASQUERADE on ppp0
                        ▼
                   ppp0 (MTU 1400) ──IPsec ESP──▶ company network
```

### Mullvad Traffic (fast)

```
Mac ──Tailscale──▶ gluetun (tailscale0, MTU 1280)
                        │
                        │ default route via tun0
                        │ MASQUERADE on tun0
                        ▼
                   tun0 (WireGuard, MTU 1380) ──▶ Mullvad server ──▶ internet
```

### Key Difference

Mullvad path: 1 hop inside gluetun (tailscale0 → tun0), kernel WireGuard.
Company path: 2 container hops (gluetun → Docker bridge → L2TP), userspace
xl2tpd + strongSwan IPsec, plus PPP encapsulation.

---

## Identified Potential Bottlenecks

Analysis of the codebase, Mar 23 investigation, and research into xl2tpd
known issues reveals eight potential bottleneck areas, ranked by likelihood:

### B0: xl2tpd Default Bandwidth Cap at 10 Mbps (VERY HIGH likelihood)

**Code evidence** (`l2tp/entrypoint.sh:68-74`):
```
[lac company]
lns = ${L2TP_SERVER}
ppp debug = yes
pppoptfile = /etc/ppp/options.l2tpd.client
length bit = yes
```

**The smoking gun**: xl2tpd has a compiled-in default `DEFAULT_MAX_BPS =
10000000` (10 Mbps) defined in `l2tp.h`. This value is advertised during
L2TP tunnel negotiation via AVP (Attribute Value Pair) messages. If the
company L2TP server respects this AVP, throughput is **hard-capped at
~10 Mbps** — exactly matching the observed 1-10 Mbps range.

The xl2tpd.conf `[lac company]` section is **missing `tx bps` and `rx bps`
settings**, so the compiled-in 10 Mbps default applies.

**References**:
- [xl2tpd Issue #124 — low throughput](https://github.com/xelerance/xl2tpd/issues/124)
- [Ubuntu Bug #400748 — xl2tpd connection speed too low](https://bugs.launchpad.net/ubuntu/+source/xl2tpd/+bug/400748)
- [xl2tpd l2tp.h — DEFAULT_MAX_BPS](https://github.com/richvdh/xl2tpd/blob/master/l2tp.h)

**Diagnostic**:
```bash
# Check current xl2tpd config for bps settings
docker exec l2tp-vpn grep -i bps /etc/xl2tpd/xl2tpd.conf
# If no output → capped at 10 Mbps default

# Check xl2tpd logs for bandwidth negotiation
docker logs l2tp-vpn 2>&1 | grep -i bps
```

**Fix**: Add to `[lac company]` section in entrypoint.sh:
```
tx bps = 100000000
rx bps = 100000000
```

This raises the cap to 100 Mbps. **This is likely the primary fix.**

**Metric**: Throughput before/after adding `tx bps`/`rx bps`.

---

### B1: IPsec Cipher Fallback to 3DES (HIGH likelihood)

**Code evidence** (`l2tp/entrypoint.sh:59-60`):
```
ike=aes128-sha1-modp1024,3des-sha1-modp1024!
esp=aes128-sha1,3des-sha1!
```

The IPsec config offers **both AES-128 and 3DES** as ESP ciphers. 3DES
throughput on modern CPUs is typically **50-150 Mbps** vs AES-128-NI at
**1+ Gbps**. However, AES-128 at 50-150 Mbps shouldn't limit us to 1-10
Mbps, so 3DES alone doesn't explain the full gap. Still, if the VPS CPU
lacks AES-NI, even AES-128 in software could be slow.

**Why it matters**: If the company server selects 3DES, every packet goes
through triple DES encryption/decryption — dramatically slower than AES
with hardware acceleration.

**Diagnostic**:
```bash
# Check which cipher was actually negotiated
docker exec l2tp-vpn ipsec statusall | grep -E "ESTABLISHED|IKE|ESP"

# Check if VPS CPU has AES-NI hardware acceleration
docker exec l2tp-vpn grep -o aes /proc/cpuinfo | head -1

# Measure crypto overhead directly
docker exec l2tp-vpn ipsec stroke statusall
```

**Expected output**: Look for `ESP:` line showing `AES_CBC_128` (good) vs
`3DES_CBC` (bad).

**Metric**: `ipsec statusall` shows negotiated cipher suite.

---

### B2: xl2tpd Userspace Processing (HIGH likelihood)

**Architecture issue**: xl2tpd runs as a userspace daemon
(`l2tp/entrypoint.sh:143`: `xl2tpd -D`). Every packet traverses:
kernel → xl2tpd (userspace) → PPP → kernel → IPsec → wire.

This double kernel/userspace crossing per packet is inherently slower than
kernel-mode WireGuard (Mullvad path stays entirely in kernel).

Linux kernel has a native L2TP implementation (`l2tp_ppp` module) that
eliminates the userspace hop. However, switching to it requires significant
entrypoint rewrite and the kernel module may not be available in Alpine.

**Diagnostic**:
```bash
# Check CPU usage during transfer — high xl2tpd CPU = userspace bottleneck
docker exec l2tp-vpn sh -c 'apk add --no-cache procps && \
  top -bn1 | grep -E "xl2tpd|pppd|charon"'

# Check if kernel L2TP module is available
docker exec l2tp-vpn sh -c 'lsmod 2>/dev/null | grep l2tp; \
  ls /lib/modules/*/kernel/net/l2tp/ 2>/dev/null'

# Measure overhead: compare ppp0 throughput from INSIDE L2TP container
# vs end-to-end from Mac (isolates Tailscale+Docker overhead from L2TP)
docker exec l2tp-vpn sh -c 'apk add --no-cache curl && \
  curl -o /dev/null -w "%{speed_download}" http://COMPANY_RESOURCE 2>/dev/null'
```

**Metric**: CPU % of xl2tpd/pppd during active transfer.

---

### B3: Missing MSS Clamping on ppp0 (MEDIUM likelihood)

**Code evidence**: `l2tp/entrypoint.sh` has no iptables mangle rules.
The `setup_routing()` function (line 167) only adds MASQUERADE on ppp0,
no TCPMSS rules.

**The gap**: MSS clamping on tailscale0 (in `gluetun/post-rules.txt`)
clamps to 1240 for Mac↔gluetun TCP. But TCP connections originating FROM
gluetun toward the L2TP container traverse the Docker bridge (MTU 1500),
so the SYN MSS could be up to 1460. When these packets hit ppp0 (MTU 1400
minus IPsec overhead), they fragment or get dropped.

However, Path MTU Discovery should handle this if ICMP isn't blocked. The
Mar 23 investigation showed MTU-sized pings work, so PMTUD may be
functioning. This makes MSS clamping a contributing factor, not the primary
bottleneck.

**Diagnostic**:
```bash
# Check for fragmentation on ppp0
docker exec l2tp-vpn sh -c 'cat /proc/net/snmp | grep -A1 "^Ip:"'
# Look at: ReasmReqds, ReasmOKs, FragCreates, FragOKs, FragFails

# Check for ICMP "need frag" messages (PMTUD)
docker exec l2tp-vpn sh -c 'iptables -t mangle -L -v -n'
```

**Metric**: IP fragmentation counters (`FragCreates`, `FragFails` in
`/proc/net/snmp`).

---

### B4: PPP MTU/MRU Mismatch (MEDIUM likelihood)

**Code evidence** (`l2tp/entrypoint.sh:83-84`):
```
mtu 1410
mru 1410
```

PPP options request MTU 1410, but the Mar 23 investigation found ppp0 has
MTU 1400 — the peer negotiated it down by 10 bytes. This isn't itself the
problem, but the MTU should account for IPsec ESP overhead.

**The real issue**: ppp0 MTU 1400 is the IP-level MTU. But traffic arriving
at ppp0 from the Docker bridge has been through TCP with MSS potentially
based on 1500 MTU. After IPsec ESP encapsulation (~52-60 bytes for
AES-128-CBC + SHA1), the actual wire packet could be 1452-1460 bytes,
exceeding the outer interface MTU.

**Diagnostic**:
```bash
# Check actual negotiated PPP MTU/MRU
docker exec l2tp-vpn ip link show ppp0

# Check IPsec overhead
docker exec l2tp-vpn ipsec statusall | grep -i "bytes_i\|bytes_o"

# Compare: send known-size TCP data, check if fragmentation occurs
docker exec l2tp-vpn sh -c 'ping -c 5 -s 1372 -M do COMPANY_IP'
# 1372 + 28 ICMP/IP = 1400 = ppp0 MTU — should work
# Try larger:
docker exec l2tp-vpn sh -c 'ping -c 5 -s 1373 -M do COMPANY_IP'
# Should fail if MTU is truly 1400
```

**Metric**: Actual vs configured PPP MTU; ping DF-bit test results.

---

### B5: Docker Bridge Forwarding Overhead (LOW-MEDIUM likelihood)

**Architecture issue**: Company traffic crosses the Docker bridge twice:
gluetun eth0 → bridge → L2TP eth0 (forward), and
L2TP eth0 → bridge → gluetun eth0 (return).

Docker bridge uses Linux bridge + netfilter, which adds iptables traversal
per packet. Compare this to Mullvad traffic which stays inside gluetun's
network namespace (tailscale0 → tun0, no bridge crossing).

Additionally, `init-routes.sh` adds iptables OUTPUT/INPUT rules for each
COMPANY_CIDR, plus `ip rule` entries — more routing table lookups per packet.

**Diagnostic**:
```bash
# Measure Docker bridge throughput directly (eliminates VPN as variable)
# Run iperf3 server in L2TP container, client in gluetun namespace
docker exec l2tp-vpn sh -c 'apk add --no-cache iperf3 && iperf3 -s -D'
docker exec gluetun sh -c 'apt-get install -y iperf3 && iperf3 -c 172.29.0.20 -t 10'

# Check conntrack table pressure
docker exec gluetun sh -c 'cat /proc/sys/net/netfilter/nf_conntrack_count; \
  cat /proc/sys/net/netfilter/nf_conntrack_max'

# Check iptables rule count (more rules = more per-packet overhead)
docker exec gluetun iptables -L -n | wc -l
docker exec l2tp-vpn iptables -L -n | wc -l
```

**Metric**: iperf3 throughput between containers (baseline for bridge speed);
conntrack count and iptables rule count.

---

### B6: TCP Parameter Tuning (LOW-MEDIUM likelihood)

**Code evidence**: No sysctl tuning anywhere in the stack. Containers use
kernel defaults, which may not suit the multi-hop VPN path.

Key parameters that affect throughput on high-latency/lossy links:

- `net.core.rmem_max` / `net.core.wmem_max` — socket buffer limits
- `net.ipv4.tcp_rmem` / `net.ipv4.tcp_wmem` — TCP buffer auto-tuning range
- `net.ipv4.tcp_congestion_control` — BBR vs cubic (BBR better for VPN)
- `net.ipv4.tcp_mtu_probing` — enable PMTUD at TCP level

**Diagnostic**:
```bash
# Check current TCP settings in L2TP container
docker exec l2tp-vpn sh -c '
  sysctl net.core.rmem_max net.core.wmem_max \
         net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
         net.ipv4.tcp_congestion_control \
         net.ipv4.tcp_mtu_probing \
         net.ipv4.tcp_window_scaling 2>/dev/null'

# Same in gluetun
docker exec gluetun sh -c '
  sysctl net.core.rmem_max net.core.wmem_max \
         net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
         net.ipv4.tcp_congestion_control \
         net.ipv4.tcp_mtu_probing 2>/dev/null'
```

**Metric**: Current vs recommended values for VPN throughput.

---

### B7: Company-Side Throttling (UNKNOWN likelihood)

Cannot rule out that the company VPN concentrator rate-limits L2TP
connections. This is diagnosed by exclusion — if all other bottlenecks
are fixed and throughput is still low, the limit is on their side.

**Diagnostic**:
```bash
# Compare throughput from INSIDE L2TP container vs from Mac end-to-end
# If L2TP container → company is also slow, limit is company-side or IPsec
# If L2TP container → company is fast but Mac → company is slow, limit is
# in the Tailscale/Docker path

# From L2TP container directly:
docker exec l2tp-vpn curl -o /dev/null -w "Speed: %{speed_download} bytes/sec\n" \
  http://COMPANY_INTERNAL_URL

# From Mac via Tailscale (end-to-end):
curl -o /dev/null -w "Speed: %{speed_download} bytes/sec\n" \
  http://COMPANY_INTERNAL_URL
```

**Metric**: Throughput ratio (L2TP-direct vs Mac-end-to-end). If both are
equally slow, the bottleneck is at or beyond ppp0.

---

## Diagnostic Execution Plan

### Phase 1: Segment Isolation (most critical)

The single most important measurement is comparing throughput at each hop
to pinpoint WHERE the speed drops:

```
Segment A: Mac → gluetun (Tailscale overlay)
Segment B: gluetun → L2TP container (Docker bridge)
Segment C: L2TP container → company (ppp0 + IPsec)
Segment D: Mac → company (end-to-end = A + B + C)
```

| # | Test | Command | What it tells us |
|---|------|---------|------------------|
| 0 | **xl2tpd bps cap** | `grep -i bps /etc/xl2tpd/xl2tpd.conf` in L2TP container | Missing tx/rx bps = 10 Mbps cap |
| 1 | **Segment D** baseline | `curl` to company resource from Mac | Current end-to-end speed |
| 2 | **Segment C** direct | `curl` to company resource from inside L2TP container | Isolates L2TP+IPsec from everything else |
| 3 | **Segment B** bridge | `iperf3` between gluetun and L2TP container | Docker bridge overhead |
| 4 | **Mullvad** reference | `curl` speed test from gluetun via tun0 | Comparison baseline |
| 5 | **Cipher check** | `ipsec statusall` in L2TP container | 3DES vs AES |
| 6 | **CPU check** | `top` during active transfer | xl2tpd/charon bottleneck |

**Decision tree based on results**:

```
Step 0: Is tx/rx bps missing from xl2tpd.conf?
├── YES → Apply Fix F0 (add tx/rx bps). Re-measure. Likely resolves issue.
└── NO or still slow after F0 ↓

Is Segment C (L2TP → company) also slow?
├── YES → Bottleneck is IPsec/L2TP/company-side
│   ├── Is cipher 3DES? → Try removing 3DES from config (F1)
│   ├── Is CPU high on xl2tpd/charon? → Userspace bottleneck (F5)
│   └── Neither? → Company-side throttling (B7)
│
└── NO (fast from L2TP, slow end-to-end) → Bottleneck is gluetun→L2TP path
    ├── Is Segment B slow? → Docker bridge issue (B5)
    └── Segment B fast? → MSS/fragmentation between hops (B3/B4)
```

### Phase 2: Targeted Fixes

Applied based on Phase 1 findings:

**Fix F0: Add tx/rx bps to xl2tpd.conf** (if B0 confirmed — MOST LIKELY FIX)
- File: `l2tp/entrypoint.sh:68-74`
- Change: Add `tx bps = 100000000` and `rx bps = 100000000` to `[lac company]`
- Risk: None — only raises the bandwidth cap
- Rollback: Remove the lines
- **Apply first** — this alone may resolve the entire issue

**Fix F1: Remove 3DES from cipher list** (if B1 confirmed)
- File: `l2tp/entrypoint.sh:59-60`
- Change: Remove `3des-sha1-modp1024` from `ike=` and `3des-sha1` from `esp=`
- Risk: Connection may fail if company server only supports 3DES
- Rollback: Add 3DES back

**Fix F2: Add MSS clamping on ppp0** (if B3 confirmed or as preventive measure)
- File: `l2tp/entrypoint.sh`, in `setup_routing()` after MASQUERADE
- Add:
  ```bash
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o ppp0 \
    -j TCPMSS --clamp-mss-to-pmtu
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i ppp0 \
    -j TCPMSS --clamp-mss-to-pmtu
  ```
- Risk: None — `--clamp-mss-to-pmtu` auto-calculates from interface MTU
- Rollback: Remove the rules

**Fix F3: TCP tuning** (if B6 contributes)
- File: `l2tp/entrypoint.sh`, in `configure()` or top of main
- Add sysctl settings for VPN-optimized TCP:
  ```bash
  sysctl -w net.ipv4.tcp_mtu_probing=1
  sysctl -w net.ipv4.tcp_congestion_control=bbr  # if available
  ```
- Risk: Low — these are standard tuning parameters
- Rollback: Remove sysctl lines

**Fix F4: Reduce PPP MTU to account for IPsec overhead** (if B4 confirmed)
- File: `l2tp/entrypoint.sh:83-84`
- Change: `mtu 1410` → `mtu 1360` (accounting for ~40 bytes IPsec ESP)
- Risk: May reduce throughput slightly due to smaller packets
- Rollback: Revert MTU value

**Fix F5: Kernel L2TP** (if B2 confirmed as primary bottleneck, last resort)
- Requires `l2tp_ppp` and `l2tp_eth` kernel modules on VPS host
- Major entrypoint rewrite — use `ip l2tp add tunnel` instead of xl2tpd
- Risk: High complexity; only pursue if xl2tpd is clearly the bottleneck
- Separate task if needed

---

## Files to Modify

| File | Change | When |
|------|--------|------|
| `l2tp/entrypoint.sh` | Add `tx bps`/`rx bps` to xl2tpd.conf | Fix F0 (first!) |
| `l2tp/entrypoint.sh` | Add MSS clamping in `setup_routing()` | Fix F2 |
| `l2tp/entrypoint.sh` | Remove 3DES from cipher list | Fix F1 (if confirmed) |
| `l2tp/entrypoint.sh` | Add TCP sysctl tuning | Fix F3 (if confirmed) |
| `l2tp/entrypoint.sh` | Adjust PPP MTU/MRU | Fix F4 (if confirmed) |
| `docker-compose.yml` | Set bridge MTU to 1280 | Fix F2 companion |
| `l2tp/Dockerfile` | Add `iperf3` for diagnostics (temporary) | Phase 1 |
| `gluetun/post-rules.txt` | Possibly add MSS clamping for eth0→L2TP path | Fix F2 alt |

---

## Trade-offs

### Approach A: Fix Everything Speculatively

Apply F1-F4 all at once, measure after.

- **Pro**: Fast, one deployment
- **Con**: Can't attribute improvement to specific fix; may mask root cause
- **Not recommended**: Violates "measure first" principle

### Approach B: Measure → Fix → Measure (Recommended)

Run Phase 1 diagnostics first, then apply targeted fixes.

- **Pro**: Data-driven; understand actual bottleneck; avoid unnecessary changes
- **Con**: Multiple deployment cycles
- **Recommended**: The speed gap is too large for guesswork

### Approach C: Replace xl2tpd with Kernel L2TP

Eliminate userspace overhead entirely.

- **Pro**: Maximum possible L2TP performance
- **Con**: Major rewrite; kernel module dependency; may not be the bottleneck
- **Not recommended initially**: Try simpler fixes first

---

## Measurement Infrastructure

Since there's no iperf3 on company side, throughput measurement uses:

1. **Docker-internal**: iperf3 between containers (install temporarily)
2. **Company-side proxy**: `curl -o /dev/null` to a known company HTTP
   resource, using `-w "%{speed_download}"` for throughput
3. **Mullvad reference**: `curl` to a public speed test endpoint via tun0
4. **Packet counters**: `/proc/net/snmp` for IP fragmentation stats
5. **IPsec stats**: `ipsec statusall` for cipher and byte counters

---

## Rollback Plan

All fixes are in container configuration files. Rollback = revert the file
changes and rebuild/restart the container:
```bash
git checkout l2tp/entrypoint.sh
rdocker.sh compose up -d --build --force-recreate l2tp-vpn
```

---

## Phase 1 Diagnostic Results (2026-03-25)

### Segment Throughput Measurements

| Segment | Speed | Verdict |
|---------|-------|---------|
| B: Docker bridge (gluetun→L2TP) | 11.9 Gbps | Not a bottleneck |
| C: L2TP container → internet via ppp0 | 29 Mbps | Fast — tunnel is healthy |
| Mullvad reference (gluetun → internet via tun0) | 8.8 Mbps | VPS→internet baseline |
| D: Mac → company (end-to-end) | ~1-10 Mbps | Slow — matches Tailscale limit |

### Bottleneck Diagnosis

| Suspect | Status | Evidence |
|---------|--------|---------|
| B0: xl2tpd 10 Mbps cap | CONFIRMED present but NOT current bottleneck | No tx/rx bps set; but Tailscale is slower than 10 Mbps anyway |
| B1: 3DES cipher | RULED OUT | AES_CBC_128 negotiated |
| B2: xl2tpd userspace | NOT limiting | 29 Mbps from container |
| B3: MSS/fragmentation on ppp0 | RULED OUT | FragOKs/FragFails/FragCreates all zero |
| B4: PPP MTU mismatch | NOT limiting | No fragmentation observed |
| B5: Docker bridge | RULED OUT | 11.9 Gbps |
| B6: TCP tuning | UNKNOWN | May help at margins |
| B7: Company-side throttling | RULED OUT | 29 Mbps from L2TP container |

### Revised Understanding

The actual bottleneck is **Segment A: Mac → VPS via Tailscale**.
All traffic (both company and Mullvad) passes through Tailscale first.
If Tailscale throughput to the VPS is ~9 Mbps, nothing downstream can
go faster.

```
Mac ──Tailscale (~9 Mbps)──▶ VPS ──L2TP (29 Mbps)──▶ company
                                  ──Mullvad (9 Mbps)──▶ internet
```

The L2TP tunnel is 3x faster than Mullvad when measured from the VPS.
The speed limit is the Tailscale overlay, not the VPN tunnels.

### CRITICAL: B8 — Tailscale Routed Through Mullvad

**This is an architectural flaw, not a tuning issue.**

Tailscale runs inside gluetun's network namespace. Gluetun forces ALL
outbound traffic through Mullvad via iptables kill switch (OUTPUT policy
DROP, rule 101 routes everything to table 51820/tun0). This means:

- Tailscale HTTPS control plane → goes through Mullvad
- Tailscale DERP relay → goes through Mullvad
- Tailscale STUN probes → go through Mullvad
- Tailscale WireGuard peer-to-peer → goes through Mullvad

**Consequences**:
- Private Tailscale/Headscale infrastructure depends on third-party
  Mullvad. If Mullvad goes down, ALL Tailscale connectivity dies.
- STUN discovers Mullvad's IP, not VPS real IP → direct peer
  connections impossible → forced into DERP relay
- DERP latency inflated by ~80ms (Mullvad round-trip)
- Throughput capped by Mullvad's relay path

**Root cause**: Tailscale shares gluetun's network namespace
(`network_mode: service:gluetun`). This was done so Tailscale can
use gluetun's VPN tunnel as exit node. But it also subjects all
Tailscale control traffic to gluetun's kill switch.

**Required fix**: Tailscale's WireGuard, STUN, DERP, and HTTPS
control traffic must bypass Mullvad and route directly through the
VPS host network. Only user data traffic (exit node forwarding)
should go through Mullvad/L2TP.

**Approaches attempted** (2026-03-25):
1. `ip rule fwmark 0x80000 → table 201` — broke exit node data
   path (fwmark too broad, caught all Tailscale traffic)
2. `ip rule sport 41642 → table 201` — worked for WireGuard but
   not STUN/DERP/HTTPS
3. `iptables -m mark --mark 0x80000` in post-rules.txt — gluetun
   can't parse hex fwmark, crashes MTU discovery

**Approach needed**: Separate Tailscale's control traffic from data
traffic. Options:
- Move Tailscale to host network (cleanest but requires rearchitect)
- Use iptables MARK on specific destination IPs (Headscale server)
  + UDP sport (Tailscale WireGuard port) and route marked packets
  via host, with host MASQUERADE for return path
- Use gluetun `FIREWALL_OUTBOUND_SUBNETS` to whitelist Headscale IP

---

## References

### Code Analysis

- `l2tp/entrypoint.sh:59-60` — IPsec cipher config (3DES risk)
- `l2tp/entrypoint.sh:83-84` — PPP MTU/MRU 1410 (peer negotiates to 1400)
- `l2tp/entrypoint.sh:143` — xl2tpd runs in userspace (`-D` foreground)
- `l2tp/entrypoint.sh:209` — Only MASQUERADE on ppp0, no MSS clamping
- `gluetun/post-rules.txt:20-21` — MSS clamping only on tailscale0
- `gluetun/init-routes.sh:26-38` — Company CIDR routing + iptables rules

### Historical Context (Claude-Mem)

- Mar 23 investigation: Full MTU analysis, traffic path tracing, MSS clamping
  added on tailscale0 but didn't resolve speed issue
- L2TP tunnel works at MTU level (1400-byte pings succeed)
- Latency is fine (11ms), problem is throughput-specific

---

**Next Steps**:
1. Review this design
2. Run `/dev:tasks` for implementation task breakdown
3. Start with Phase 1 diagnostics on the VPS
