# 004-L2TP-SPEED - Task List

## Relevant Files

- [tasks/004-L2TP-SPEED/2026-03-25-004-L2TP-SPEED-tech-design.md](
  2026-03-25-004-L2TP-SPEED-tech-design.md) :: Technical Design
- [tasks/004-L2TP-SPEED/2026-03-25-004-L2TP-SPEED-prd.md](
  2026-03-25-004-L2TP-SPEED-prd.md) :: Product Requirements Document
- [l2tp/entrypoint.sh](../../l2tp/entrypoint.sh) :: L2TP container
  entrypoint — xl2tpd config, IPsec config, PPP options, routing
- [l2tp/Dockerfile](../../l2tp/Dockerfile) :: L2TP container image
  definition
- [docker-compose.yml](../../docker-compose.yml) :: Container
  orchestration and network config
- [gluetun/post-rules.txt](../../gluetun/post-rules.txt) :: Gluetun
  iptables rules including existing MSS clamping
- [gluetun/init-routes.sh](../../gluetun/init-routes.sh) :: Company
  CIDR routing setup

## Notes

- This task follows a **measure → diagnose → fix → verify** workflow.
  Do NOT apply fixes before completing Phase 1 diagnostics.
- All diagnostic commands run via `docker exec` on the VPS.
- No iperf3 available on company side — use `curl` to company HTTP
  resources as throughput proxy.
- Success target: company traffic speed >= Mullvad internet speed.

## Tasks

- [X] 1.0 **User Story**: As a developer, I want to confirm the
  xl2tpd bandwidth cap hypothesis so that I can apply the most
  likely fix first [2/2]
  - [X] 1.1 SSH into VPS, run
    `docker exec l2tp-vpn grep -i bps /etc/xl2tpd/xl2tpd.conf`
    — if no output, the 10 Mbps default cap is active (B0
    confirmed). Record result.
    **Result**: No output — B0 CONFIRMED. No tx/rx bps set.
  - [X] 1.2 Check xl2tpd logs for bandwidth negotiation:
    `docker logs l2tp-vpn 2>&1 | grep -i bps` — look for any
    AVP bandwidth values exchanged with the company server.
    **Result**: No bps entries in logs.

- [~] 2.0 **User Story**: As a developer, I want baseline speed
  measurements at each network segment so that I can isolate the
  exact bottleneck location [3/4]
  - [ ] 2.1 **Segment D (end-to-end)**: From Mac via Tailscale,
    `curl -o /dev/null -w "%{speed_download}\n" http://COMPANY_URL`
    to a known company HTTP resource. Record speed in bytes/sec.
    **Status**: Pending — requires Mac-side measurement.
  - [X] 2.2 **Segment C (L2TP → internet via ppp0)**: From inside
    L2TP container, curl to speedtest.
    **Result**: 3.6 MB/s (~29 Mbps). L2TP tunnel is fast.
  - [X] 2.3 **Segment B (Docker bridge)**: iperf3 gluetun → L2TP.
    **Result**: 11.9 Gbps. Bridge is not a bottleneck.
  - [X] 2.4 **Mullvad reference**: wget from gluetun via tun0.
    **Result**: 1.1 MB/s (~8.8 Mbps). This is VPS Mullvad speed.

- [X] 3.0 **User Story**: As a developer, I want to check IPsec
  cipher negotiation and CPU overhead so that I can rule out or
  confirm crypto-related bottlenecks [3/3]
  - [X] 3.1 Check negotiated cipher.
    **Result**: AES_CBC_128/HMAC_SHA1_96/PRF_HMAC_SHA1/MODP_1024.
    No 3DES — B1 ruled out.
  - [X] 3.2 Check AES-NI hardware support.
    **Result**: AES-NI available on VPS CPU.
  - [X] 3.3 Check IP fragmentation counters.
    **Result**: All zeros — FragOKs=0, FragFails=0,
    FragCreates=0. No fragmentation occurring.

- [X] 4.0 **User Story**: As a developer, I want to apply the
  xl2tpd bandwidth cap fix (F0) and re-measure so that the
  primary bottleneck is resolved [3/3]
  - [X] 4.1 DEFERRED to 7.1 — diagnostics revealed xl2tpd bps
    cap is NOT the current bottleneck (Tailscale is slower than
    10 Mbps). Fix still needed as preventive measure.
  - [X] 4.2 DEFERRED to 7.4 — bundled deployment.
  - [X] 4.3 DEFERRED to 8.1 — final measurement after all fixes.

- [X] 5.0 **User Story**: As a developer, I want MSS clamping and
  MTU fixes applied to the L2TP path so that TCP fragmentation
  is eliminated [3/3]
  - [X] 5.1 SKIPPED — 3DES not negotiated (AES confirmed in 3.1).
    No cipher change needed.
  - [X] 5.2 SKIPPED — No fragmentation detected (3.3). MSS
    clamping and sysctl changes moved to task 7.0 as preventive
    measures bundled with the xl2tpd bps fix.
  - [X] 5.3 SKIPPED — Deployment deferred to task 7.0 to batch
    all L2TP changes together.

- [X] 6.0 **User Story**: As a developer, I want to investigate
  Tailscale overlay throughput so that the real bottleneck
  (Mac → VPS) is understood and improved [4/4]
  - [X] 6.1 Check Tailscale connection type.
    **Result**: Mac (100.64.0.12) connected via
    `relay "headscale"` — NOT direct. This is the root cause.
  - [X] 6.2 Check Tailscale ping and path.
    **Result**: `via DERP(headscale)` 106-110ms latency.
    `direct connection not established`. All traffic relayed.
  - [X] 6.3 Run Tailscale netcheck.
    **Result**: UDP=true, IPv4=yes (149.102.229.x:49794),
    IPv6=no, DERP latency=79ms to Headscale Embedded DERP.
    Only one DERP server available (headscale embedded).
    No `MappingVariesByDestIP` result — NAT traversal may
    be failing.
  - [X] 6.4 Measure raw Tailscale throughput: iperf3 Mac → VPS.
    **Result**: 12 Mbps sender, 11.6 Mbps receiver. This is
    the hard ceiling for all traffic through the VPS.

- [~] 7.0 **User Story**: As a developer, I want to apply
  preventive L2TP fixes and commit all changes so the VPS-side
  path is optimized [5/6]
  - [X] 7.1 Apply Fix F0: add `tx bps = 100000000` and
    `rx bps = 100000000` to xl2tpd.conf in
    `l2tp/entrypoint.sh:70-79`.
  - [X] 7.2 Apply Fix F2: add MSS clamping on ppp0 in
    `setup_routing()` after the MASQUERADE rule.
  - [X] 7.3 Apply Fix F3: add `sysctl -w net.ipv4.tcp_mtu_probing=1`
    in `configure()`.
  - [X] 7.4 Deploy to VPS, verify L2TP connection establishes
    and ppp0 is healthy.
    **Result**: All 3 fixes verified active. ppp0 UP.
  - [ ] 7.5 Commit all changes: `gluetun/post-rules.txt` (MSS
    clamping from Mar 23) + `l2tp/entrypoint.sh` (F0, F2, F3).
  - [X] 7.6 Route Tailscale control/WireGuard traffic directly to
    internet bypassing Mullvad. Persist fwmark routing (table 201,
    ip rule priority 100) and iptables bypass in config files so
    it survives container restarts.
    **Result**: Fixed. (1) fwmark 0x80000 routing via table 201 +
    iptables OUTPUT ACCEPT; (2) exposed UDP 41642 for direct P2P
    WireGuard; (3) ip rule 100.64.0.0/10 → table 52 for return
    traffic; (4) OUTPUT -o tailscale0 ACCEPT for MagicDNS/exit
    node responses. Internet, company VPN, and DNS all verified
    working through vpn-gate exit node.

- [ ] 8.0 **User Story**: As a developer, I want to verify
  end-to-end speed and document results so the fix is confirmed
  and measurable [3/0]
  - [ ] 8.1 Run final measurements: Segment D (Mac → company),
    Mullvad reference, Tailscale raw throughput. Compare.
  - [ ] 8.2 Document final speed numbers and findings in tech
    design.
  - [ ] 8.3 Update PRD and tech design status to Complete.

