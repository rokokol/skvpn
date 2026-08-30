#!/usr/bin/env python3
"""Render the non-Nix sing-box base config from install.sh options."""

import argparse
import json
import sys
from pathlib import Path


PRESETS = {
    "russia": {
        "tag": "ru",
        "zones": [".ru", ".su", ".xn--p1ai"],
        "geosite": "geosite-category-ru.srs",
        "geoip": "geoip-ru.srs",
    },
    "china": {
        "tag": "cn",
        "zones": [".cn", ".xn--fiqs8s", ".xn--fiqz9s"],
        "geosite": "geosite-cn.srs",
        "geoip": "geoip-cn.srs",
    },
    "iran": {
        "tag": "ir",
        "zones": [".ir", ".xn--mgba3a4f16a"],
        "geosite": "geosite-category-ir.srs",
        "geoip": "geoip-ir.srs",
    },
}


def tagged_path(value):
    try:
        tag, path = value.split("=", 1)
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected TAG=PATH") from error
    if not tag or not path:
        raise argparse.ArgumentTypeError("expected non-empty TAG=PATH")
    return tag, path


parser = argparse.ArgumentParser()
parser.add_argument("--tailscale", action="store_true")
parser.add_argument("--docker", action="store_true")
parser.add_argument("--preset", action="append", choices=PRESETS, default=[])
parser.add_argument("--direct-zone", action="append", default=[])
parser.add_argument("--direct-geosite", action="append", type=tagged_path, default=[])
parser.add_argument("--direct-geoip", action="append", type=tagged_path, default=[])
parser.add_argument("--tun-interface", default="skvpn-tun")
parser.add_argument("--tun-address", action="append")
parser.add_argument("--dns-server", default="8.8.8.8")
parser.add_argument("--rule-set-dir", default="/usr/share/sing-box/rule-set")
parser.add_argument("--skip-path-check", action="store_true")
args = parser.parse_args()

zones = list(args.direct_zone)
geosite = {}
geoip = {}
for name in args.preset:
    preset = PRESETS[name]
    zones.extend(preset["zones"])
    geosite[f"geosite-{preset['tag']}"] = f"{args.rule_set_dir}/{preset['geosite']}"
    geoip[f"geoip-{preset['tag']}"] = f"{args.rule_set_dir}/{preset['geoip']}"
geosite.update(args.direct_geosite)
geoip.update(args.direct_geoip)

zones = list(dict.fromkeys(zones))
if not args.skip_path_check:
    missing = [
        path
        for path in [*geosite.values(), *geoip.values()]
        if not Path(path).is_file()
    ]
    if missing:
        parser.error(
            f"rule-set not found: {missing[0]}; on Arch install "
            "sing-geoip-rule-set and sing-geosite-rule-set"
        )

geosite_tags = sorted(geosite)
geoip_tags = sorted(geoip)
rule_tags = geosite_tags + geoip_tags
dns_rules = []
if zones:
    dns_rules.append({"domain_suffix": zones, "server": "bootstrap"})
if geosite_tags:
    dns_rules.append({"rule_set": geosite_tags, "server": "bootstrap"})

inbound = {
    "type": "tun",
    "tag": "tun-in",
    "interface_name": args.tun_interface,
    "address": args.tun_address or ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    "auto_route": True,
    "auto_redirect": True,
    "strict_route": False,
    "stack": "system",
}
if args.tailscale:
    inbound["route_exclude_address"] = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]
if args.docker:
    inbound["exclude_interface"] = ["docker0"]

route_rules = [
    {"action": "sniff"},
    {"protocol": "dns", "action": "hijack-dns"},
    {"ip_is_private": True, "outbound": "direct"},
]
if zones:
    route_rules.append({"domain_suffix": zones, "outbound": "direct"})
if rule_tags:
    route_rules.append({"rule_set": rule_tags, "outbound": "direct"})

config = {
    "log": {"level": "warn", "timestamp": True},
    "dns": {
        "servers": [
            {"tag": "bootstrap", "type": "local"},
            {
                "tag": "remote",
                "type": "tls",
                "server": args.dns_server,
                "detour": "proxy",
                "domain_resolver": "bootstrap",
            },
        ],
        "rules": dns_rules,
        "final": "remote",
        "strategy": "ipv4_only",
    },
    "inbounds": [inbound],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "route": {
        "auto_detect_interface": True,
        "default_domain_resolver": "bootstrap",
        "rules": route_rules,
        "rule_set": [
            {"tag": tag, "type": "local", "format": "binary", "path": path}
            for tag, path in [*sorted(geosite.items()), *sorted(geoip.items())]
        ],
        "final": "proxy",
    },
}

json.dump(config, fp=sys.stdout, indent=2)
print()
