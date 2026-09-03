#!/usr/bin/env python3
"""Render the non-Nix sing-box base config from install.sh options."""

import argparse
import ipaddress
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


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


# The TUN's own addresses. --no-ipv6 drops the v6 one: with auto_route on a host
# without a v6 upstream it installs a v6 default route to nowhere, and whatever
# reaches for v6 first waits on it
TUN_ADDRESS4 = "172.19.0.1/30"
TUN_ADDRESS6 = "fdfe:dcba:9876::1/126"


def tagged_path(value):
    try:
        tag, path = value.split("=", 1)
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected TAG=PATH") from error
    if not tag or not path:
        raise argparse.ArgumentTypeError("expected non-empty TAG=PATH")
    return tag, path


def cidr(value):
    try:
        return str(ipaddress.ip_network(value, strict=False))
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"not an address or CIDR: {value}") from error


def absolute_path(value):
    if not value.startswith("/"):
        raise argparse.ArgumentTypeError(f"a path is absolute: {value}")
    return value


def domain(value):
    """A site as typed — a bare name, a URL, `*.example.com` — as a domain suffix;
    the same normalisation skvpn.py makes for `split add domain`"""
    if "://" in value:
        value = urlparse(value).hostname or ""
    value = value.strip().rstrip("/").lower()
    if value.startswith("*."):
        value = value[1:]
    dotted = value.startswith(".")
    try:
        labels = [
            label.encode("idna").decode() for label in value.lstrip(".").split(".")
        ]
    except UnicodeError as error:
        raise argparse.ArgumentTypeError(f"not a domain: {value}") from error
    value = ("." if dotted else "") + ".".join(labels)
    # A whole zone is written with its dot, `.ru`; a bare single label is a host name
    zone = r"\.[a-z0-9-]+(\.[a-z0-9-]+)*"
    host = r"[a-z0-9-]+(\.[a-z0-9-]+)+"
    if not re.fullmatch(f"{zone}|{host}", value):
        raise argparse.ArgumentTypeError(
            f"not a domain — a whole zone is written with its dot, like .ru: {value}"
        )
    return value


def is_glob(value):
    return "*" in value or "?" in value


def catches_sing_box(kind, value, binary):
    """Whether an entry would match sing-box itself: its traffic never enters the
    tunnel, and a pattern wide enough to catch it (`*`, `/**`) catches everything —
    the same refusal skvpn.py makes for `split add`"""
    if kind == "name":
        targets = ["sing-box", os.path.basename(binary)]
    else:
        targets = [binary]
    if is_glob(value):
        return any(re.search(glob_regex(kind, value), t) for t in targets)
    return value in targets


def glob_regex(kind, pattern):
    """The same translation skvpn.py makes for `split add`: a name or path with
    wildcards as process_path_regex — `*` one segment, `**` any run, `?` one character,
    a name matching the executable's basename."""
    body = (
        re.escape(pattern)
        .replace(r"\*\*", ".*")
        .replace(r"\*", "[^/]*")
        .replace(r"\?", "[^/]")
    )
    return ("(^|/)" if kind == "name" else "^") + body + "$"


parser = argparse.ArgumentParser()
parser.add_argument("--tailscale", action="store_true")
parser.add_argument("--docker", action="store_true")
parser.add_argument("--preset", action="append", choices=PRESETS, default=[])
parser.add_argument("--direct-zone", action="append", default=[])
parser.add_argument("--direct-geosite", action="append", type=tagged_path, default=[])
parser.add_argument("--direct-geoip", action="append", type=tagged_path, default=[])
# Split tunnelling, bypass only: the listed processes and addresses leave direct
parser.add_argument("--split-name", action="append", default=[])
parser.add_argument("--split-path", action="append", type=absolute_path, default=[])
parser.add_argument("--split-ip", action="append", type=cidr, default=[])
# A direct zone with the CLI's normalisation: a URL or *.example.com is fine here
parser.add_argument("--split-domain", action="append", type=domain, default=[])
# Where install.sh found sing-box: what a split entry must not name
parser.add_argument("--sing-box", dest="sing_box", default="/usr/bin/sing-box")
parser.add_argument("--tun-interface", default="skvpn-tun")
parser.add_argument("--tun-address", action="append")
parser.add_argument("--dns-server", default="8.8.8.8")
parser.add_argument("--stack", choices=("system", "gvisor", "mixed"), default="system")
parser.add_argument("--no-ipv6", dest="ipv6", action="store_false")
parser.add_argument("--rule-set-dir", default="/usr/share/sing-box/rule-set")
parser.add_argument("--skip-path-check", action="store_true")
args = parser.parse_args()

for kind, values in (("name", args.split_name), ("path", args.split_path)):
    for value in values:
        if catches_sing_box(kind, value, args.sing_box):
            parser.error(
                f"--split {kind} {value} would match sing-box itself — its traffic "
                "never enters the tunnel, and a pattern that wide catches everything"
            )

zones = list(args.direct_zone) + list(args.split_domain)
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
all_names = list(dict.fromkeys(args.split_name))
all_paths = list(dict.fromkeys(args.split_path))
split_names = [v for v in all_names if not is_glob(v)]
split_paths = [v for v in all_paths if not is_glob(v)]
split_regex = [glob_regex("name", v) for v in all_names if is_glob(v)]
split_regex += [glob_regex("path", v) for v in all_paths if is_glob(v)]
split_ips = list(dict.fromkeys(args.split_ip))
dns_rules = []
if zones:
    dns_rules.append({"domain_suffix": zones, "server": "bootstrap"})
if geosite_tags:
    dns_rules.append({"rule_set": geosite_tags, "server": "bootstrap"})
# A bypassed process resolves outside the tunnel too; addresses have no DNS side
if split_names:
    dns_rules.append({"process_name": split_names, "server": "bootstrap"})
if split_paths:
    dns_rules.append({"process_path": split_paths, "server": "bootstrap"})
if split_regex:
    dns_rules.append({"process_path_regex": split_regex, "server": "bootstrap"})

inbound = {
    "type": "tun",
    "tag": "tun-in",
    "interface_name": args.tun_interface,
    "address": args.tun_address
    or ([TUN_ADDRESS4, TUN_ADDRESS6] if args.ipv6 else [TUN_ADDRESS4]),
    "auto_route": True,
    "auto_redirect": True,
    "strict_route": False,
    "stack": args.stack,
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
if split_names:
    route_rules.append({"process_name": split_names, "outbound": "direct"})
if split_paths:
    route_rules.append({"process_path": split_paths, "outbound": "direct"})
if split_regex:
    route_rules.append({"process_path_regex": split_regex, "outbound": "direct"})
if split_ips:
    route_rules.append({"ip_cidr": split_ips, "outbound": "direct"})

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
