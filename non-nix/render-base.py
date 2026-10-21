#!/usr/bin/env python3
"""Render the non-Nix sing-box base config, the guard laid over it, or the Tor pair —
the torrc and the sing-box half of the `tor` profile — from install.sh options."""

import argparse
import ipaddress
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


# Presets, the guard's AI rule-set and the tailnet: policy.json beside non-nix/, the
# file the NixOS module and the CLI read too
POLICY_FILE = Path(__file__).resolve().parent.parent / "policy.json"
POLICY = json.loads(POLICY_FILE.read_text())
PRESETS = {preset["name"]: preset for preset in POLICY["presets"]}
GUARD_AI = (f"geosite-{POLICY['guard']['tag']}", POLICY["guard"]["geosite"])
TOR = POLICY["tor"]


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


def tor_plugin(value):
    """TRANSPORTS=PATH: the comma-separated transports one plugin binary runs"""
    transports, path = tagged_path(value)
    unknown = [t for t in transports.split(",") if t not in TOR["transports"]]
    if unknown:
        raise argparse.ArgumentTypeError(
            f"not a transport skvpn asks Moat for: {unknown[0]}"
        )
    return transports.split(","), absolute_path(path)


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
# The sniffed protocol and the clients policy.json names leave direct
parser.add_argument("--bittorrent", action="store_true")
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
parser.add_argument("--dns-server", default="1.1.1.1")
parser.add_argument("--stack", choices=("system", "gvisor", "mixed"), default="system")
parser.add_argument("--no-ipv6", dest="ipv6", action="store_false")
parser.add_argument("--rule-set-dir", default="/usr/share/sing-box/rule-set")
parser.add_argument("--skip-path-check", action="store_true")
# Sites refused while no profile is up; any of them turns the guard on
parser.add_argument("--guard-ai", action="store_true")
parser.add_argument("--guard-zone", action="append", default=[])
parser.add_argument("--guard-geosite", action="append", type=tagged_path, default=[])
# A Tor of skvpn's own: .onion names reach it from any program, and `skvpn up tor`
# sends everything there. Each --tor-plugin is one transport binary the torrc runs
parser.add_argument("--tor", action="store_true")
parser.add_argument("--tor-plugin", action="append", type=tor_plugin, default=[])
parser.add_argument("--tor-socks-port", type=int, default=TOR["socksPort"])
parser.add_argument("--tor-data-dir", type=absolute_path, default="/var/lib/skvpn-tor")
parser.add_argument(
    "--tor-bridges", type=absolute_path, default="/var/lib/skvpn/tor-bridges.conf"
)
# The same options render every file, so they can never disagree about the base
parser.add_argument(
    "--render",
    choices=("base", "guard", "tor", "torrc", "tor-resolv"),
    default="base",
)
args = parser.parse_args()
if args.tor and not args.tor_plugin:
    parser.error("--tor needs a --tor-plugin: Tor goes out through bridges only")

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

guard_geosite = {}
if args.guard_ai:
    guard_geosite[GUARD_AI[0]] = f"{args.rule_set_dir}/{GUARD_AI[1]}"
guard_geosite.update(args.guard_geosite)
guard_zones = list(dict.fromkeys(args.guard_zone))

zones = list(dict.fromkeys(zones))
if not args.skip_path_check:
    missing = [
        path
        for path in [*geosite.values(), *geoip.values(), *guard_geosite.values()]
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
# Each client also under the name a Nix wrapper runs as, which is what sing-box reads
# off /proc/<pid>/exe; the NixOS module joins the same names
bittorrent_names = [
    name
    for client in (POLICY["bittorrent"]["clients"] if args.bittorrent else [])
    for name in (client, f".{client}-wrapped")
]
all_names = list(dict.fromkeys(args.split_name + bittorrent_names))
all_paths = list(dict.fromkeys(args.split_path))
split_names = [v for v in all_names if not is_glob(v)]
split_paths = [v for v in all_paths if not is_glob(v)]
split_regex = [glob_regex("name", v) for v in all_names if is_glob(v)]
split_regex += [glob_regex("path", v) for v in all_paths if is_glob(v)]
split_ips = list(dict.fromkeys(args.split_ip))


def bootstrap_rule(field, values):
    """A DNS rule steering `values` to the local resolver, in sing-box's action form —
    the bare `server` field is the legacy shape deprecated in 1.11"""
    return {field: values, "action": "route", "server": "bootstrap"}


dns_rules = []
# A .onion name gets an address from the fake range, and the connection to it carries
# the name back, which the route rule below sends to Tor; no resolver knows these names
if args.tor:
    dns_rules.append(
        {"domain_suffix": [TOR["onion"]], "action": "route", "server": "onion"}
    )
if zones:
    dns_rules.append(bootstrap_rule("domain_suffix", zones))
if geosite_tags:
    dns_rules.append(bootstrap_rule("rule_set", geosite_tags))
# A bypassed process resolves outside the tunnel too; addresses have no DNS side
if split_names:
    dns_rules.append(bootstrap_rule("process_name", split_names))
if split_paths:
    dns_rules.append(bootstrap_rule("process_path", split_paths))
if split_regex:
    dns_rules.append(bootstrap_rule("process_path_regex", split_regex))

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
    inbound["route_exclude_address"] = POLICY["tailnet"]
if args.docker:
    inbound["exclude_interface"] = ["docker0"]

route_rules: list[dict] = [
    {"action": "sniff"},
    {"protocol": "dns", "action": "hijack-dns"},
]
# Ahead of every direct rule: a .onion connection that fell through to one of them would
# leave in the clear and fail
if args.tor:
    route_rules.append({"domain_suffix": [TOR["onion"]], "outbound": "tor"})
route_rules.append({"ip_is_private": True, "outbound": "direct"})
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
# Any client the list misses, where the sniffer can read it: plain TCP handshakes, uTP
# and UDP tracker requests
if args.bittorrent:
    route_rules.append({"protocol": ["bittorrent"], "outbound": "direct"})

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
        # A connection with no name of its own still meets the domain rules
        "reverse_mapping": True,
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

local_tor = {"server": "127.0.0.1", "server_port": TOR["routePort"]}
if args.tor:
    config["dns"]["servers"].append(
        {"tag": "onion", "type": "fakeip", "inet4_range": TOR["fakeip"]}
    )
    # The port that isolates by destination, so two sites never share one circuit
    config["outbounds"].append({"type": "socks", "tag": "tor", **local_tor})

# The sing-box half of the `tor` profile: `proxy` is Tor's SOCKS, and Tor's own traffic,
# matched by its user, leaves direct — or through the node `skvpn up tor --via` puts in
# place of `direct` — rather than back into itself. Names go to Tor's DNSPort, except
# Tor's own, which it needs before it can resolve anything: a transport looks up its
# broker's name before the first circuit exists
tor_profile = None
if args.tor:
    tor_user = [TOR["user"]]
    tor_profile = {
        "outbounds": [{"type": "socks", "tag": "proxy", **local_tor}],
        "dns": {
            "servers": [
                {
                    "tag": "tor",
                    "type": "udp",
                    "server": "127.0.0.1",
                    "server_port": TOR["dnsPort"],
                }
            ],
            "rules": [
                {"user": tor_user, "action": "route", "server": "bootstrap"},
                {"action": "route", "server": "tor"},
            ],
        },
        # Tor's SOCKS carries no UDP; refused at once, QUIC falls back to TCP at once
        "route": {
            "rules": [
                {"user": tor_user, "outbound": "direct"},
                {"network": ["udp"], "action": "reject"},
            ]
        },
    }


def torrc():
    """Tor's own config. The second SOCKS port is the one sing-box dials; the first is
    the user's. The bridges file is CLI state, written by `skvpn tor bridges update`"""
    lines = [
        f"DataDirectory {args.tor_data_dir}",
        f"SocksPort 127.0.0.1:{args.tor_socks_port}",
        f"SocksPort 127.0.0.1:{TOR['routePort']} IsolateDestAddr",
        f"DNSPort 127.0.0.1:{TOR['dnsPort']}",
    ]
    lines += [
        f"ClientTransportPlugin {','.join(transports)} exec {path}"
        for transports, path in args.tor_plugin
    ]
    lines += ["UseBridges 1", f"%include {args.tor_bridges}"]
    return "\n".join(lines) + "\n"


def tor_resolv():
    """The resolv.conf bound into Tor's unit. A transport resolves its broker through
    glibc otherwise, and the query reaches sing-box from systemd-resolved, which the
    `tor` profile's rule for Tor's user cannot match. sing-box serves DNS on the address
    after the TUN's own. The remote DNS server follows as a fallback for a host with no
    sing-box running; while one runs, the TUN takes those queries too, still as Tor's
    user. The short timeout keeps a lookup without a TUN from a long wait"""
    tun4 = [
        address
        for address in map(ipaddress.ip_interface, inbound["address"])
        if address.version == 4
    ]
    if not tun4:
        parser.error("--tor needs an IPv4 --tun-address: Tor's resolver is the TUN's")
    try:
        ipaddress.ip_address(args.dns_server)
    except ValueError:
        parser.error("--tor needs --dns-server as an address: Tor's fallback resolver")
    return (
        f"nameserver {tun4[0].ip + 1}\n"
        f"nameserver {args.dns_server}\n"
        "options timeout:2\n"
    )


# Laid over the base the way nix/module.nix lays it: sing-box sorts every file by
# path, keeps the first scalar and appends arrays, so this cannot move `final` and its
# rules land after the base's. `proxy` is direct here instead, and the names nobody
# refuses go to the bootstrap, not to the DoT server that would now be dialled direct
guard_matches = []
if guard_zones:
    guard_matches.append({"domain_suffix": guard_zones})
if guard_geosite:
    guard_matches.append({"rule_set": sorted(guard_geosite)})
guard = None
if guard_matches:
    guard = {
        # Not an empty direct outbound, which sing-box refuses as the DoT server's
        # detour at start; the resolver is the base's default anyway (PITFALLS.md)
        "outbounds": [
            {"type": "direct", "tag": "proxy", "domain_resolver": "bootstrap"}
        ],
        "dns": {
            "rules": [
                {**match, "action": "predefined", "rcode": "REFUSED"}
                for match in guard_matches
            ]
            + [{"action": "route", "server": "bootstrap"}],
        },
        "route": {
            "rules": [{**match, "action": "reject"} for match in guard_matches],
            "rule_set": [
                {"tag": tag, "type": "local", "format": "binary", "path": path}
                for tag, path in sorted(guard_geosite.items())
            ],
        },
    }

if args.render == "torrc":
    if not args.tor:
        parser.error("--render torrc needs --tor")
    sys.stdout.write(torrc())
    sys.exit(0)
if args.render == "tor-resolv":
    if not args.tor:
        parser.error("--render tor-resolv needs --tor")
    sys.stdout.write(tor_resolv())
    sys.exit(0)

# `null` for the guard or the tor profile means there is none: install.sh drops its file
rendered = {"base": config, "guard": guard, "tor": tor_profile}[args.render]
json.dump(rendered, fp=sys.stdout, indent=2)
print()
