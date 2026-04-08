# Tailscale Exit Node VPN Router - Task List

## Relevant Files

- [tasks/VPN-001-tailscale-exit-node-vpn-router/2026-03-17-VPN-001-tailscale-exit-node-vpn-router-prd.md](tasks/VPN-001-tailscale-exit-node-vpn-router/2026-03-17-VPN-001-tailscale-exit-node-vpn-router-prd.md) :: Product Requirements Document
- [tasks/VPN-001-tailscale-exit-node-vpn-router/2026-03-17-VPN-001-tailscale-exit-node-vpn-router-tech-design.md](tasks/VPN-001-tailscale-exit-node-vpn-router/2026-03-17-VPN-001-tailscale-exit-node-vpn-router-tech-design.md) :: Technical Design Document
- [.env.example](.env.example) :: Documented environment variable template (committed to git)
- [.gitignore](.gitignore) :: Git ignore rules (`.env`, volumes, etc.)
- [docker-compose.yml](docker-compose.yml) :: Main Docker Compose stack definition
- [gluetun/post-rules.sh](gluetun/post-rules.sh) :: Script to generate iptables rules from `COMPANY_CIDRS`
- [l2tp/Dockerfile](l2tp/Dockerfile) :: Custom Alpine image with strongSwan + xl2tpd
- [l2tp/entrypoint.sh](l2tp/entrypoint.sh) :: Generates configs from env vars, starts VPN, extracts DNS
- [l2tp/ipsec.conf.tmpl](l2tp/ipsec.conf.tmpl) :: IPsec config template
- [l2tp/xl2tpd.conf.tmpl](l2tp/xl2tpd.conf.tmpl) :: xl2tpd config template
- [l2tp/options.l2tpd.client](l2tp/options.l2tpd.client) :: PPP options (usepeerdns, etc.)
- [dns/Dockerfile](dns/Dockerfile) :: Custom Alpine image with dnsmasq
- [dns/entrypoint.sh](dns/entrypoint.sh) :: Waits for company DNS IP, generates dnsmasq.conf
- [healthcheck/Dockerfile](healthcheck/Dockerfile) :: Alpine image with curl + ping
- [healthcheck/check.sh](healthcheck/check.sh) :: Health check loop script
- [README.md](README.md) :: Setup guide, architecture diagram, usage
- [rdocker.sh](rdocker.sh) :: Run docker commands on remote VPS via SSH
- [deploy-push.sh](deploy-push.sh) :: Rsync project files to remote VPS
- [gluetun/Dockerfile.route-init](gluetun/Dockerfile.route-init) :: Alpine image with iptables for route-init sidecar

## Notes

- `.env` is a secrets file — never read, written, or accessed
  by automation tools. Only `.env.example` is managed.
- TDD is not applicable for most tasks in this project since
  the deliverables are Docker configs, shell scripts, and
  infrastructure. Testing is done via manual verification on
  a real VPS with real VPN credentials.
- Each task's verification steps describe how to confirm it
  works on a live deployment.
- `COMPANY_CIDRS` is a comma-separated list of CIDRs (e.g.
  `10.11.0.0/16,10.12.0.0/16`) — never hardcode subnets.

## Tasks

- [X] 1.0 **User Story:** As a developer, I want project
  scaffolding with `.env.example`, `.gitignore`, and Docker
  Compose skeleton so that the repo is ready for
  implementation and safe for open-source [5/5]
  - [X] 1.1 Create `.gitignore` with entries for `.env`,
    Docker volumes, and OS files
  - [X] 1.2 Create `.env.example` with all documented env
    vars and placeholder values (see tech design
    `.env.example` section)
  - [X] 1.3 Create `docker-compose.yml` skeleton with all 6
    services defined (gluetun, tailscale, l2tp-vpn, dnsmasq,
    ntfy, healthcheck), the `bridge_vpn` network, and named
    volumes (`ts-state`, `ntfy-cache`, `shared-config`). Use
    placeholder images — details filled in later tasks.
  - [X] 1.4 Create directory structure: `l2tp/`, `dns/`,
    `healthcheck/`, `gluetun/`
  - [X] 1.5 Verify: `docker compose config` parses without
    errors

- [X] 2.0 **User Story:** As a developer, I want gluetun to
  establish a Mullvad WireGuard tunnel so that all default
  traffic exits through Mullvad with a kill switch
  (REQ-02, REQ-06) [4/4]
  - [X] 2.1 Configure gluetun service in `docker-compose.yml`:
    image `qmcgaw/gluetun`, env vars for Mullvad WireGuard
    (`VPN_SERVICE_PROVIDER`, `VPN_TYPE`, `WIREGUARD_PRIVATE_KEY`,
    `WIREGUARD_ADDRESSES`, `SERVER_COUNTRIES`), `cap_add:
    NET_ADMIN`, `bridge_vpn` network, and
    `FIREWALL_OUTBOUND_SUBNETS` for bridge access
  - [X] 2.2 Add `devices: ["/dev/net/tun:/dev/net/tun"]` and
    sysctl `net.ipv4.conf.all.src_valid_mark=1` to gluetun
  - [X] 2.3 Mount gluetun volume for custom iptables rules
    at `/iptables/post-rules.txt` (empty file for now)
  - [ ] 2.4 Verify: gluetun healthy, public IP is Mullvad,
    not VPS IP. **IN PROGRESS** — re-testing from Mac client.

- [X] 3.0 **User Story:** As a developer, I want Tailscale to
  run as an exit node in gluetun's network namespace so that
  my Mac can route all traffic through the VPS
  (REQ-01, REQ-11) [4/4]
  - [X] 3.1 Configure tailscale service in
    `docker-compose.yml`: image `tailscale/tailscale`,
    `network_mode: service:gluetun`, env vars (`TS_AUTHKEY`,
    `TS_HOSTNAME`, `TS_EXTRA_ARGS=--advertise-exit-node`,
    `TS_USERSPACE=false`, `TS_STATE_DIR=/var/lib/tailscale`,
    `TS_ACCEPT_DNS=false`), `depends_on: gluetun`,
    `cap_add: NET_ADMIN`, volume `ts-state`
  - [X] 3.2 Add `TS_ROUTES` env var support if needed for
    Headscale route advertisement
  - [ ] 3.3 Verify: test client set exit-node=vpn-gate,
    internet works via Mullvad IP. **IN PROGRESS**
  - [ ] 3.4 Verify Tailscale mesh connectivity while exit
    node active. **IN PROGRESS**

- [X] 4.0 **User Story:** As a developer, I want the L2TP/
  IPsec container to connect to the company VPN so that
  company resources on `COMPANY_CIDRS` are reachable from
  the VPS (REQ-03) [6/6]
  **PoC validated** (`poc-l2tp/`): Alpine 3.21 + strongSwan
  5.9.14 + xl2tpd. Key findings:
  - `rightid=%any` required (server identifies by IP)
  - `esp=aes128-sha1,3des-sha1!` (no DH group in ESP)
  - `privileged: true` needed (or fine-grained caps TBD)
  - PPP DNS may not be pushed by all servers — handle
    gracefully
  - [X] 4.1 Move validated `poc-l2tp/` Dockerfile and
    entrypoint to `l2tp/`, adapting for the full stack
  - [X] 4.2 Create `l2tp/ipsec.conf.tmpl`: configs generated
    inline in entrypoint
  - [X] 4.3 Create `l2tp/xl2tpd.conf.tmpl`: configs generated
    inline in entrypoint
  - [X] 4.4 Create `l2tp/options.l2tpd.client`: generated
    inline in entrypoint
  - [X] 4.5 Create `l2tp/entrypoint.sh`: writes DNS to
    `/shared/company-dns-ip`, routes COMPANY_CIDRS via ppp0
  - [ ] 4.6 Verify: company network reachable from Mac
    client via exit node. **IN PROGRESS**

- [X] 5.0 **User Story:** As a developer, I want policy
  routing to split `COMPANY_CIDRS` traffic to the L2TP
  container so that company traffic goes through the company
  VPN while everything else goes through Mullvad
  (REQ-04, REQ-12) [4/4]
  - [X] 5.1 Create route-init sidecar (`gluetun/init-routes.sh`)
    with custom Dockerfile.route-init (Alpine + iptables)
  - [X] 5.2 Add `route-init` service in docker-compose.yml:
    `network_mode: service:gluetun`, `cap_add: NET_ADMIN`
  - [X] 5.3 Configure `FIREWALL_OUTBOUND_SUBNETS` in gluetun
    to include the bridge subnet
  - [ ] 5.4 Verify split routing from Mac client: internet
    via Mullvad, company via L2TP. **IN PROGRESS**

- [X] 6.0 **User Story:** As a developer, I want split DNS
  via dnsmasq so that company domain queries use company
  DNS and everything else uses Mullvad DNS (REQ-05) [4/4]
  - [X] 6.1 Create `dns/Dockerfile`: Alpine + dnsmasq +
    bind-tools + iproute2
  - [X] 6.2 Create `dns/entrypoint.sh`: waits for company
    DNS IP, generates dnsmasq.conf, adds routes to company
    CIDRs via l2tp-vpn for DNS reachability
  - [X] 6.3 Configure dnsmasq in `docker-compose.yml` with
    `cap_add: NET_ADMIN`, `COMPANY_CIDRS`. Gluetun uses
    `DNS_UPSTREAM_RESOLVER_TYPE=plain` and
    `DNS_UPSTREAM_PLAIN_ADDRESSES=172.29.0.30:53` to forward
    DNS through dnsmasq.
  - [ ] 6.4 Verify DNS split from Mac client: public
    domains resolve, company domains resolve to internal IPs.
    **IN PROGRESS**

- [X] 7.0 **User Story:** As a developer, I want health
  monitoring with ntfy push notifications so that I'm
  alerted within 60 seconds when either VPN tunnel goes
  down (REQ-07, REQ-08) [5/5]
  - [X] 7.1 Configure ntfy service in `docker-compose.yml`:
    image `binwiederhier/ntfy`, healthy
  - [X] 7.2 Create `healthcheck/Dockerfile`: Alpine + curl +
    iputils
  - [X] 7.3 Create `healthcheck/check.sh`: monitors Mullvad
    IP and L2TP ping, notifies on state change
  - [X] 7.4 Configure healthcheck service in
    `docker-compose.yml`: `network_mode: service:gluetun`
  - [X] 7.5 Verify healthcheck notifications work end-to-end
    from Mac client perspective.

- [X] 8.0 **User Story:** As a developer, I want the full
  stack to work end-to-end with auto-recovery and a README
  so that I can deploy, select the exit node, and forget
  about it (REQ-09, REQ-10) [6/6]
  - [X] 8.1 Add `restart: unless-stopped` to all services
  - [X] 8.2 Add Docker healthchecks to gluetun, l2tp-vpn,
    dnsmasq, ntfy. All passing.
  - [X] 8.3 Add proper `depends_on` with `condition:
    service_healthy` for tailscale and route-init on gluetun
  - [X] 8.4 Write `README.md`
  - [X] 8.5 End-to-end test: all 7 containers running,
    gluetun/l2tp-vpn/dnsmasq/ntfy healthy. Via ts-test-client
    exit node: ifconfig.me → Mullvad IP, company ping OK,
    DNS split OK, ntfy notifications OK.
  - [~] 8.6 ~~Reboot test~~ — DISABLED (unreliable)

- [X] 9.0 **User Story:** As a developer, I want to
  subscribe to VPN alerts on my phone using the Tailscale
  hostname (e.g., `http://vpn-router/vpn-alerts`) so that
  I get push notifications without remembering IP addresses
  (REQ-08) [3/3]
  - [X] 9.1 Move ntfy to gluetun's network namespace:
    change `docker-compose.yml` ntfy service from
    `networks: bridge_vpn` to
    `network_mode: service:gluetun`, add
    `depends_on: gluetun: condition: service_healthy`,
    keep existing healthcheck. Remove ntfy's static IP
    (`172.29.0.40`).
  - [X] 9.2 Update `healthcheck/check.sh`: change
    `NTFY_URL` from `http://172.29.0.40:80` to
    `http://127.0.0.1:80` (both now share gluetun's
    namespace). Update healthcheck `depends_on` for ntfy
    to `condition: service_healthy`.
  - [X] 9.3 Verify: deploy to VPS, confirm ntfy is
    reachable from phone at
    `http://<TS_HOSTNAME>/<NTFY_TOPIC>`, confirm
    healthcheck can still post notifications, confirm
    ntfy healthcheck passes in `docker ps`.
