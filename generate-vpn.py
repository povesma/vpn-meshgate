#!/usr/bin/env python3
"""Generate docker-compose.override.yml and vpn-instances.json from vpn-instances.yaml."""

import ipaddress
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required. Install: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

CONFIG_FILE = "secrets/vpn-instances.yaml"
OVERRIDE_FILE = "docker-compose.override.yml"
JSON_FILE = "vpn-instances.json"
BASE_IP = "172.29.0.101"
VALID_TYPES = {"l2tp", "wireguard", "openvpn", "netbird"}

REQUIRED_FIELDS = {
    "l2tp": ["server", "credentials"],
    "wireguard": ["config_file"],
    "openvpn": ["config_file"],
    "netbird": ["credentials"],
}

REQUIRED_CREDENTIALS = {
    "l2tp": ["username", "password", "psk"],
    "openvpn": ["username", "password"],
    "netbird": ["setup_key"],
}


def load_config(path):
    with open(path) as f:
        data = yaml.safe_load(f)
    if not data or "instances" not in data:
        fatal("YAML must have an 'instances' key with a list of VPN instances")
    instances = data["instances"]
    if not isinstance(instances, list) or len(instances) == 0:
        fatal("'instances' must be a non-empty list")
    return instances


def validate(instances):
    names = set()
    all_cidrs = []

    for i, inst in enumerate(instances):
        label = inst.get("name", f"instance[{i}]")

        name = inst.get("name")
        if not name:
            fatal(f"{label}: 'name' is required")
        if not all(c.isalnum() or c == "-" for c in name):
            fatal(f"{label}: 'name' must be alphanumeric + hyphens")
        if name in names:
            fatal(f"{label}: duplicate name '{name}'")
        names.add(name)

        vtype = inst.get("type")
        if vtype not in VALID_TYPES:
            fatal(f"{label}: 'type' must be one of {VALID_TYPES}, got '{vtype}'")

        cidrs = inst.get("cidrs")
        if not cidrs or not isinstance(cidrs, list):
            fatal(f"{label}: 'cidrs' must be a non-empty list")
        for cidr_str in cidrs:
            try:
                net = ipaddress.ip_network(cidr_str, strict=False)
            except ValueError as e:
                fatal(f"{label}: invalid CIDR '{cidr_str}': {e}")
            for existing_name, existing_net in all_cidrs:
                if net.overlaps(existing_net):
                    fatal(f"{label}: CIDR '{cidr_str}' overlaps with '{existing_net}' from '{existing_name}'")
            all_cidrs.append((name, net))

        for field in REQUIRED_FIELDS.get(vtype, []):
            if field == "credentials":
                creds = inst.get("credentials", {})
                if not isinstance(creds, dict):
                    fatal(f"{label}: 'credentials' must be a mapping")
                for cred_field in REQUIRED_CREDENTIALS.get(vtype, []):
                    if not creds.get(cred_field):
                        fatal(f"{label}: credentials.{cred_field} is required for type '{vtype}'")
            elif not inst.get(field):
                fatal(f"{label}: '{field}' is required for type '{vtype}'")


def assign_ips(instances):
    base = ipaddress.IPv4Address(BASE_IP)
    for i, inst in enumerate(instances):
        inst["_ip"] = str(base + i)
        inst["_container"] = f"vpn-{inst['name']}"


def generate_env_file(name, secrets):
    """Write secrets to .env.vpn-{name} and return the filename."""
    env_path = Path(f".env.vpn-{name}")
    lines = [f"{k}={v}" for k, v in secrets.items()]
    env_path.write_text("\n".join(lines) + "\n")
    env_path.chmod(0o600)
    print(f"Wrote {env_path} (secrets)")
    return str(env_path)


def generate_override(instances):
    services = {}
    for inst in instances:
        name = inst["name"]
        vtype = inst["type"]
        ip = inst["_ip"]
        container = inst["_container"]
        cidrs_str = ",".join(inst["cidrs"])

        env_file = None

        if vtype == "l2tp":
            creds = inst["credentials"]
            env_file = generate_env_file(name, {
                "L2TP_SERVER": inst["server"],
                "L2TP_USERNAME": creds["username"],
                "L2TP_PASSWORD": creds["password"],
                "L2TP_PSK": creds["psk"],
            })
            svc = {
                "build": "./l2tp",
                "container_name": container,
                "privileged": True,
                "dns": ["1.1.1.1", "8.8.8.8"],
                "devices": ["/dev/ppp:/dev/ppp"],
                "env_file": [env_file],
                "environment": [
                    f"VPN_INSTANCE_NAME={name}",
                    f"INSTANCE_CIDRS={cidrs_str}",
                    "NTFY_TOPIC=${NTFY_TOPIC:-vpn-alerts}",
                ],
                "networks": {"bridge_vpn": {"ipv4_address": ip}},
                "volumes": ["shared-config:/shared"],
                "restart": "unless-stopped",
            }
            if inst.get("check_ip"):
                svc["environment"].append(f"L2TP_CHECK_IP={inst['check_ip']}")

        elif vtype == "wireguard":
            config_file = inst["config_file"]
            svc = {
                "build": "./wireguard",
                "container_name": container,
                "cap_add": ["NET_ADMIN"],
                "environment": [
                    f"VPN_INSTANCE_NAME={name}",
                    f"INSTANCE_CIDRS={cidrs_str}",
                    "NTFY_TOPIC=${NTFY_TOPIC:-vpn-alerts}",
                ],
                "networks": {"bridge_vpn": {"ipv4_address": ip}},
                "volumes": [
                    "shared-config:/shared",
                    f"./{config_file}:/etc/wireguard/wg0.conf:ro",
                ],
                "restart": "unless-stopped",
            }
            if inst.get("check_ip"):
                svc["environment"].append(f"WG_CHECK_IP={inst['check_ip']}")

        elif vtype == "openvpn":
            config_file = inst["config_file"]
            creds = inst.get("credentials", {})
            if creds.get("username"):
                env_file = generate_env_file(name, {
                    "OVPN_USERNAME": creds["username"],
                    "OVPN_PASSWORD": creds["password"],
                })
            svc = {
                "build": "./openvpn",
                "container_name": container,
                "cap_add": ["NET_ADMIN"],
                "devices": ["/dev/net/tun:/dev/net/tun"],
                "environment": [
                    f"VPN_INSTANCE_NAME={name}",
                    f"INSTANCE_CIDRS={cidrs_str}",
                    "NTFY_TOPIC=${NTFY_TOPIC:-vpn-alerts}",
                ],
                "networks": {"bridge_vpn": {"ipv4_address": ip}},
                "volumes": [
                    "shared-config:/shared",
                    f"./{config_file}:/etc/openvpn/client.conf:ro",
                ],
                "restart": "unless-stopped",
            }
            if env_file:
                svc["env_file"] = [env_file]
            if inst.get("check_ip"):
                svc["environment"].append(f"OVPN_CHECK_IP={inst['check_ip']}")

        elif vtype == "netbird":
            creds = inst["credentials"]
            nb_secrets = {"NB_SETUP_KEY": creds["setup_key"]}
            if inst.get("management_url"):
                nb_secrets["NB_MANAGEMENT_URL"] = inst["management_url"]
            env_file = generate_env_file(name, nb_secrets)
            svc = {
                "image": "netbirdio/netbird:latest",
                "container_name": container,
                "cap_add": ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"],
                "env_file": [env_file],
                "environment": [
                    f"VPN_INSTANCE_NAME={name}",
                    f"INSTANCE_CIDRS={cidrs_str}",
                    "NTFY_TOPIC=${NTFY_TOPIC:-vpn-alerts}",
                ],
                "networks": {"bridge_vpn": {"ipv4_address": ip}},
                "volumes": [
                    "shared-config:/shared",
                    f"netbird-{name}:/var/lib/netbird",
                    "./netbird/entrypoint.sh:/entrypoint.sh:ro",
                ],
                "entrypoint": ["/entrypoint.sh"],
                "restart": "unless-stopped",
            }
            if inst.get("check_ip"):
                svc["environment"].append(f"NB_CHECK_IP={inst['check_ip']}")

        services[container] = svc

    override = {"services": services}

    netbird_volumes = {
        f"netbird-{inst['name']}": None
        for inst in instances if inst["type"] == "netbird"
    }
    if netbird_volumes:
        override["volumes"] = netbird_volumes

    return yaml.dump(override, default_flow_style=False, sort_keys=False)


def generate_json(instances):
    result = []
    for inst in instances:
        result.append({
            "name": inst["name"],
            "type": inst["type"],
            "ip": inst["_ip"],
            "cidrs": inst["cidrs"],
            "check_ip": inst.get("check_ip", ""),
            "dns_domains": inst.get("dns_domains", []),
            "container": inst["_container"],
        })
    return json.dumps(result, indent=2)


def fatal(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    config_path = Path(CONFIG_FILE)
    if not config_path.exists():
        fatal(f"{CONFIG_FILE} not found. Copy from {CONFIG_FILE}.example")

    print(f"Reading {CONFIG_FILE}...")
    instances = load_config(config_path)

    print(f"Validating {len(instances)} instance(s)...")
    validate(instances)

    assign_ips(instances)

    override_content = generate_override(instances)
    Path(OVERRIDE_FILE).write_text(override_content)
    print(f"Wrote {OVERRIDE_FILE}")

    json_content = generate_json(instances)
    Path(JSON_FILE).write_text(json_content + "\n")
    print(f"Wrote {JSON_FILE}")

    print()
    for inst in instances:
        print(f"  {inst['_container']:25s} {inst['type']:10s} {inst['_ip']:15s} {','.join(inst['cidrs'])}")
    print(f"\nDone. Run: docker compose up -d --build")


if __name__ == "__main__":
    main()
