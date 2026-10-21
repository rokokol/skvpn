#!/usr/bin/env python3
"""Manage sing-box profiles as systemd template instances.

A profile is one file in /etc/sing-box/profiles holding a single outbound tagged `proxy`; the
shared base comes from the NixOS module. Switching is `systemctl start sing-box@<name>`.
"""

import base64
import ipaddress
import json
import os
import queue
import re
import select
import shutil
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlencode, urlparse

# Relocates every path at once, so the tool can be exercised outside root
ROOT = Path(os.environ.get("SKVPN_ROOT", "/"))
CONF = ROOT / "etc/sing-box"
PROFILES = CONF / "profiles"
SUB_URL = CONF / "subscription.url"
MANIFEST = CONF / "subscription.profiles"
BASE_D = CONF / "base.d"
# The imperative split list, rendered straight into the base directory: sing-box's -C
# appends its rules after the declared base, and the file is the whole state
SPLIT = BASE_D / "70-split.json"
# CLI kind → sing-box rule field; dict order is the render order. A name or path with a
# wildcard is rendered as process_path_regex instead, see glob_regex
SPLIT_KINDS = {
    "name": "process_name",
    "path": "process_path",
    "ip": "ip_cidr",
    "domain": "domain_suffix",
}
# What `split ls` shows, in order: the kinds plus regexes written by hand
SPLIT_SHOWN = ("name", "path", "regex", "ip", "domain")
# What `ping` reaches for through each node
PING_URL = CONF / "ping.url"
DEFAULT_PING_URL = "https://www.google.com/generate_204"
# The mark sing-box puts on its own sockets so its nftables redirect lets them out —
# auto_redirect_output_mark, whose default this is. The probe borrows it for the same
# reason: measured through the physical interface, not inside the active tunnel
REDIRECT_MARK = 0x2024
PING_TIMEOUT_MS = 5000
# What `measure` downloads through each exit: https, because the probe's own delay test
# takes nothing else, and bounded twice — in bytes by the range, in time by curl. The
# default asks Cloudflare's speed endpoint for as many bytes as the range allows
MEASURE_URL = CONF / "measure.url"
MEASURE_BYTES = 10_000_000
DEFAULT_MEASURE_URL = f"https://speed.cloudflare.com/__down?bytes={MEASURE_BYTES}"
MEASURE_MAX_SECONDS = 15
# The UDP half asks a public resolver the same question a few times through each exit
UDP_RESOLVER = "1.1.1.1"
UDP_QUERY_NAME = "example.com"
UDP_QUERIES = 8
# The suite shortens the wait for an answer that never comes
UDP_TIMEOUT = float(os.environ.get("SKVPN_UDP_TIMEOUT", "2"))
# Where `top` may send its secret: the Clash API of the live instance, on this host only
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "[::1]")
STAMP = ROOT / "var/lib/skvpn/last-sync"
ACTIVE = ROOT / "var/lib/skvpn/active"
# A profile pinned for boot by hand; without it boot follows ACTIVE, the last `up`
BOOT = ROOT / "var/lib/skvpn/boot"
UNIT = "sing-box@{}.service"
# What runs while no profile is up, when the base was rendered with sites to refuse; the
# file's presence is the whole question of whether there is a guard at all
GUARD = CONF / "guard.json"
GUARD_UNIT = "skvpn-guard.service"
# nft-bypass's hold, run by a unit because the unit carries the policy's flags. The new
# sing-box lets the hold go once its rules are in; the CLI only sets it, or drops it for off
HOLD_UNIT = "skvpn-nft@hold.service"
RELEASE_UNIT = "skvpn-nft@release.service"
HELD = "the network stays held until a tunnel is up — `skvpn down --no-guard` lets it go"
# skvpn's own Tor. tor.json is the sing-box half of the `tor` profile, rendered beside the
# torrc from the same options, and its presence is the whole question of whether there is
# a Tor here, as guard.json is for the guard. The bridges directory is CLI state the
# torrc includes whole; while it is empty the unit does not start. Moat's answer and the
# user's own bridges are separate files in it, so an update never touches the own ones
TOR_PROFILE = CONF / "tor.json"
TORRC = CONF / "torrc"
TOR_BRIDGES = ROOT / "var/lib/skvpn/tor-bridges.d"
MOAT_BRIDGES = TOR_BRIDGES / "moat.conf"
OWN_BRIDGES = TOR_BRIDGES / "own.conf"
TOR_UNIT = "skvpn-tor.service"
# The profile `skvpn up tor` writes from tor.json, so no share link may take the name
TOR_NAME = "tor"
# The node `up tor --via` carries Tor's own traffic through, under a tag of its own
VIA_TAG = "tor-via"
MOAT_TIMEOUT = 30
MAX_AGE = 24 * 3600

# Cloudflare's bot rules answer 403 to the stock Python-urllib agent
USER_AGENT = "skvpn/1"


def die(msg):
    print(f"skvpn: {msg}", file=sys.stderr)
    sys.exit(1)


def need_root():
    if os.geteuid() != 0 and "SKVPN_ROOT" not in os.environ:
        die("needs root — try `sudo skvpn …`")


def slug(name):
    # No dots: they become the systemd instance name, where a leading one gets escaped
    return re.sub(r"[^A-Za-z0-9_-]", "-", name)


def profile_path(name):
    return PROFILES / f"{slug(name)}.json"


def profile_names():
    return sorted(p.stem for p in PROFILES.glob("*.json"))


def node_names():
    """The profiles that are nodes: what `ping`, `measure` and a phone take when no name
    is given. The `tor` profile is the host's own Tor — a download through it every hour
    is a load on the Tor network, and a phone has no such Tor to dial"""
    return [name for name in profile_names() if name != TOR_NAME]


def remembered():
    return ACTIVE.read_text().strip() if ACTIVE.exists() else None


def pinned():
    return BOOT.read_text().strip() if BOOT.exists() else None


def boot_choice():
    """(name, pinned) — what `restore` would start: the pin if there is one, else the last
    `up`; (None, False) when boot starts nothing."""
    pin = pinned()
    if pin is not None:
        return pin, True
    return remembered(), False


def forget(name):
    """Drop the boot choice when the profile behind it goes away."""
    if pinned() == name:
        BOOT.unlink()
        print(f"     {name} was pinned for boot, boot now follows the last up")
    if remembered() == name:
        ACTIVE.unlink()
        print(f"     {name} was the boot choice, boot now starts nothing")


def disown(name):
    """Drop a deleted profile from the manifest — a later `add` under the same name is the
    user's, and a manifest still claiming it would let the next sync overwrite it."""
    if not MANIFEST.exists():
        return
    names = MANIFEST.read_text().split()
    if name in names:
        MANIFEST.write_text("\n".join(n for n in names if n != name) + "\n")


def probe(*args):
    """A systemctl call whose answer is the point — never dies, unlike systemctl()."""
    return subprocess.run(["systemctl", *args], capture_output=True, text=True, check=False)


def failure(result):
    return result.stderr.strip().splitlines()[0] if result.stderr.strip() else "systemctl failed"


def systemctl(*args):
    result = probe(*args)
    if result.returncode != 0:
        die(failure(result))


def instances(state):
    # Asked of systemd, not of the profile directory, which an unprivileged user cannot read
    result = probe("list-units", "--plain", "--no-legend", f"--state={state}", "sing-box@*")
    names = []
    for line in result.stdout.splitlines():
        unit = line.split()[0]
        if unit.startswith("sing-box@") and unit.endswith(".service"):
            names.append(unit.removeprefix("sing-box@").removesuffix(".service"))
    return names


def running():
    names = instances("active")
    return names[0] if names else None


def guard_active():
    return GUARD.exists() and probe("is-active", "--quiet", GUARD_UNIT).returncode == 0


def start_guard(wait=True):
    """The off state, when there is a guard to be in. The unit skips itself while a TUN
    is still there, and a skipped start answers 0 — so a waited start is asked again."""
    if not GUARD.exists():
        return
    if not wait:
        systemctl("start", "--no-block", GUARD_UNIT)
    else:
        result = probe("start", GUARD_UNIT)
        if result.returncode != 0 or not guard_active():
            die(f"the guard did not come up — see journalctl -u {GUARD_UNIT}\n  {HELD}")
    print("  ⛨  guard")


def hold():
    """Hold the network before a switch: from the old sing-box stopping to the new one
    being ready nothing carries the traffic, and it would leave from the host's own
    address. A switch that cannot hold does not happen."""
    result = probe("start", HOLD_UNIT)
    if result.returncode != 0:
        die(f"could not hold the network, so nothing was switched: {failure(result)}")


def release():
    systemctl("start", RELEASE_UNIT)


def stop_active():
    """Stop whatever runs — the profile or the guard — leaving the boot choice alone.
    A profile waiting out RestartSec is activating, not active, and would come back."""
    for name in instances("active,activating"):
        systemctl("stop", UNIT.format(name))
        print(f"  ×  {name}")
    if GUARD.exists():
        systemctl("stop", GUARD_UNIT)


def restore_enabled():
    # The unit is absent when the NixOS option is off, disabled and removed by an
    # installer run with --no-restore: either way there is no boot to speak of
    return probe("is-enabled", "--quiet", "skvpn-restore.service").returncode == 0


# --- URI → sing-box outbound ------------------------------------------------


def parse_transport(q):
    """The stream transport of a TCP-based scheme, None for plain TCP, ValueError for one
    sing-box cannot speak — a profile written without it would only fail at runtime."""
    network = q.get("type", "tcp")
    if network == "ws":
        transport = {"type": "ws", "path": q.get("path", "/")}
        if q.get("host"):
            transport["headers"] = {"Host": q["host"]}
        return transport
    if network == "grpc":
        return {"type": "grpc", "service_name": q.get("serviceName", "")}
    if network == "httpupgrade":
        return {"type": "httpupgrade", "path": q.get("path", "/")}
    if network in ("tcp", "raw"):
        return None
    raise ValueError(f"transport {network!r} has no sing-box equivalent")


def parse_vless(url, q):
    node = {
        "type": "vless",
        "server": url.hostname,
        "server_port": url.port or 443,
        "uuid": unquote(url.username or ""),
    }
    if q.get("flow"):
        node["flow"] = q["flow"]

    if q.get("security") in ("tls", "reality"):
        tls = {"enabled": True, "server_name": q.get("sni", url.hostname)}
        if q.get("fp"):
            tls["utls"] = {"enabled": True, "fingerprint": q["fp"]}
        if q.get("security") == "reality":
            tls["reality"] = {"enabled": True, "public_key": q.get("pbk", "")}
            if q.get("sid"):
                tls["reality"]["short_id"] = q["sid"]
        if q.get("alpn"):
            tls["alpn"] = q["alpn"].split(",")
        node["tls"] = tls

    transport = parse_transport(q)
    if transport:
        node["transport"] = transport

    return node


def parse_hysteria2(url, q):
    node = {
        "type": "hysteria2",
        "server": url.hostname,
        "server_port": url.port or 443,
        "password": unquote(url.username or ""),
        "tls": {"enabled": True, "server_name": q.get("sni", url.hostname)},
    }
    if q.get("insecure") == "1":
        node["tls"]["insecure"] = True
    if q.get("obfs"):
        node["obfs"] = {"type": q["obfs"], "password": q.get("obfs-password", "")}
    return node


def parse_trojan(url, q):
    node = {
        "type": "trojan",
        "server": url.hostname,
        "server_port": url.port or 443,
        "password": unquote(url.username or ""),
        "tls": {"enabled": True, "server_name": q.get("sni", url.hostname)},
    }
    if q.get("alpn"):
        node["tls"]["alpn"] = q["alpn"].split(",")
    transport = parse_transport(q)
    if transport:
        node["transport"] = transport
    return node


PARSERS = {
    "vless": parse_vless,
    "hysteria2": parse_hysteria2,
    "hy2": parse_hysteria2,
    "trojan": parse_trojan,
}


def uri_to_profile(uri):
    """Return (name, config) for a share link, or raise ValueError."""
    url = urlparse(uri.strip())
    parser = PARSERS.get(url.scheme)
    if parser is None:
        raise ValueError(f"scheme {url.scheme!r} is not supported by sing-box")
    # Also what guarantees a non-empty name below: the fragment falls back to the host
    if not url.hostname:
        raise ValueError("the link names no server")
    node = parser(url, {k: v[0] for k, v in parse_qs(url.query).items()})
    node["tag"] = "proxy"
    name = unquote(url.fragment) or url.hostname
    if slug(name) == TOR_NAME:
        raise ValueError(f"{TOR_NAME} is the name of the host's own Tor profile — rename the link")
    return name, {"outbounds": [node]}


def write_private(path, text, mode):
    """Create with the mode already tight: write_text-then-chmod leaves a window where the
    file sits world-readable with the secret in it, and the directory lists for everyone."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    # An existing file keeps its old mode on open, so tighten that too
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)


def write_profile(name, config):
    PROFILES.mkdir(parents=True, exist_ok=True)
    path = profile_path(name)
    # The unit runs as the sing-box user, and these carry node credentials
    write_private(path, json.dumps(config, indent=2) + "\n", 0o640)
    return path


def read_profile(name):
    """The `proxy` outbound of a profile, None for a file that is not one — a crash
    mid-write leaves a truncated file, a hand edit a wrong shape. PermissionError is
    the caller's: the contents are root-only on purpose."""
    try:
        return json.loads(profile_path(name).read_text())["outbounds"][0]
    except (ValueError, LookupError, TypeError):
        return None


def profile_line(name, node, active, extra="", servers=False):
    """One row of `ls`, and of the ping table when `extra` carries the answer. The
    server is shown only when asked for: a node's address is part of what the profile
    keeps private, and a table pasted somewhere should not carry it by default."""
    mark = "*" if name == active else " "
    row = f" {mark} {name:<24} {node['type']:<10}"
    if servers:
        row = f"{row} {node.get('server', '-'):<32}"
    return f"{row} {extra}".rstrip()


# --- ping -------------------------------------------------------------------


def sing_box_binary(required=True):
    """sudo's secure_path may hide the one on PATH, hence the fixed fallbacks."""
    override = os.environ.get("SKVPN_SING_BOX")
    if override:
        return override
    for candidate in (
        shutil.which("sing-box"),
        "/run/current-system/sw/bin/sing-box",
        "/usr/bin/sing-box",
    ):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    if required:
        die("sing-box not found — set SKVPN_SING_BOX to the binary")
    return None


def ping_url():
    return PING_URL.read_text().strip() if PING_URL.exists() else DEFAULT_PING_URL


def normalize_ping_target(arg):
    """A bare host becomes https://host/, an https URL is kept as given. https only:
    sing-box's delay test quietly swaps a plain-http URL for its own default site, so
    an http target would measure something else and never say so."""
    if "://" in arg:
        url = urlparse(arg)
        if url.scheme != "https" or not url.hostname:
            die(f"the ping site is an https url or a bare host — sing-box tests nothing else: {arg}")
        return arg
    if not arg or "/" in arg or any(c.isspace() for c in arg):
        die(f"not a host name: {arg}")
    return f"https://{arg}/"


def redirect_mark():
    """The active TUN's output mark, should the base have moved it off the default."""
    if not BASE_D.is_dir():
        return REDIRECT_MARK
    for path in sorted(BASE_D.glob("*.json")):
        try:
            inbounds = json.loads(path.read_text()).get("inbounds", [])
        except (OSError, ValueError, AttributeError):
            continue
        for inbound in inbounds:
            mark = inbound.get("auto_redirect_output_mark") if isinstance(inbound, dict) else None
            if isinstance(mark, int):
                return mark
            if isinstance(mark, str):
                try:
                    return int(mark, 0)
                except ValueError:
                    pass
    return REDIRECT_MARK


def probe_config(names, port, listeners=None):
    """One throwaway sing-box: every asked profile as an outbound tagged with its name,
    the Clash API on loopback to ask for delays. `ping` stops there and has no inbounds;
    `measure` passes {name: (tcp_port, udp_port)} and gets a pair of loopback inbounds
    per exit — a mixed one to carry a download, a direct one to carry DNS over UDP —
    each routed to that exit alone."""
    outbounds = []
    for name in names:
        node = read_profile(name)
        if node is None:
            die(f"broken profile: {name}")
        outbounds.append({**node, "tag": name})
    config = {
        "log": {"level": "error"},
        # The system resolver, as the base's own bootstrap: it only ever resolves the
        # nodes' hostnames — the site's name travels to the node and is resolved there,
        # the way it does through the tunnel — so no resolver of the probe's own could
        # be blocked on the way. ipv4_only as in the base, and not for taste: an
        # unanswered AAAA query spends the delay test's whole budget (PITFALLS.md)
        "dns": {
            "servers": [{"tag": "bootstrap", "type": "local"}],
            "final": "bootstrap",
            "strategy": "ipv4_only",
        },
        "outbounds": outbounds,
        "route": {
            "auto_detect_interface": True,
            # The TUN's output mark, so the probe's sockets leave through the physical
            # interface like the active sing-box's own; without it every delay would be
            # measured inside the active tunnel
            "default_mark": redirect_mark(),
            "default_domain_resolver": "bootstrap",
        },
        "experimental": {"clash_api": {"external_controller": f"127.0.0.1:{port}"}},
    }
    if listeners:
        config["inbounds"] = []
        config["route"]["rules"] = []
        for name, (tcp_port, udp_port) in listeners.items():
            config["inbounds"] += [
                {"type": "mixed", "tag": f"tcp-{name}", "listen": "127.0.0.1", "listen_port": tcp_port},
                {
                    "type": "direct",
                    "tag": f"udp-{name}",
                    "listen": "127.0.0.1",
                    "listen_port": udp_port,
                    "network": "udp",
                    "override_address": UDP_RESOLVER,
                    "override_port": 53,
                },
            ]
            config["route"]["rules"].append(
                {"inbound": [f"tcp-{name}", f"udp-{name}"], "action": "route", "outbound": name}
            )
    return config


def free_ports(count):
    """Distinct free loopback ports: all are held at once, so no two come out equal."""
    held = [socket.socket() for _ in range(count)]
    try:
        for held_socket in held:
            held_socket.bind(("127.0.0.1", 0))
        return [held_socket.getsockname()[1] for held_socket in held]
    finally:
        for held_socket in held:
            held_socket.close()


def wait_for_port(proc, port, stderr_path):
    """Until the API answers, or the probe has died — the port was free a moment ago,
    and a config sing-box rejects shows up here first."""
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            lines = stderr_path.read_text().strip().splitlines()
            die(f"the probe sing-box exited: {lines[-1] if lines else 'no output'}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    die("the probe sing-box never opened its API")


def delay(port, name, url):
    """Milliseconds through one outbound; 'timeout' when the site never answered, None
    for everything else the node could not do."""
    query = urlencode({"url": url, "timeout": PING_TIMEOUT_MS})
    request = f"http://127.0.0.1:{port}/proxies/{quote(name, safe='')}/delay?{query}"
    # Loopback, so an http_proxy in the environment must not get in the way
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=PING_TIMEOUT_MS / 1000 + 3) as resp:
            return int(json.loads(resp.read())["delay"])
    except urllib.error.HTTPError as exc:
        return "timeout" if exc.code == 504 else None
    except (urllib.error.URLError, OSError, ValueError, KeyError, TypeError):
        return None


@contextmanager
def probe_instance(names, exits=False, prefix="skvpn-ping-"):
    """A probe sing-box that lives only as long as the block — the config carries node
    credentials, so it sits in a private directory and goes with it. Yields the Clash API
    port and, with `exits`, the {name: (tcp_port, udp_port)} of each exit's inbounds."""
    binary = sing_box_binary()
    ports = free_ports(1 + 2 * len(names) if exits else 1)
    port = ports[0]
    listeners = {name: (ports[1 + 2 * i], ports[2 + 2 * i]) for i, name in enumerate(names)} if exits else None
    work = Path(tempfile.mkdtemp(prefix=prefix))
    config = work / "config.json"
    stderr_path = work / "stderr"
    proc = None
    try:
        write_private(config, json.dumps(probe_config(names, port, listeners)) + "\n", 0o600)
        # A file, not a pipe: a chatty child would fill the pipe and hang the parent
        with open(stderr_path, "w") as stderr:
            proc = subprocess.Popen(
                [binary, "-D", str(work), "-c", str(config), "run"],
                stdout=subprocess.DEVNULL,
                stderr=stderr,
            )
        wait_for_port(proc, port, stderr_path)
        yield (port, listeners) if exits else port
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        shutil.rmtree(work, ignore_errors=True)


def measure(names):
    """{name: delay(...)} for every name, through one probe sing-box."""
    url = ping_url()
    with probe_instance(names) as port:
        with ThreadPoolExecutor(max_workers=min(16, len(names))) as pool:
            return dict(zip(names, pool.map(lambda n: delay(port, n, url), names)))


def print_pings(results, servers=False):
    active = running()
    for name, answer in results.items():
        node = read_profile(name) or {"type": "?"}
        if isinstance(answer, int):
            extra = f"{answer} ms"
        else:
            extra = answer or "unreachable"
        print(profile_line(name, node, active, extra, servers))


def take_flag(args, flag):
    """(present, args without it) — a flag that may sit anywhere among the names."""
    return flag in args, [arg for arg in args if arg != flag]


# --- measure ----------------------------------------------------------------


def measure_url():
    return MEASURE_URL.read_text().strip() if MEASURE_URL.exists() else DEFAULT_MEASURE_URL


def dns_query(query_id):
    """A recursive A query for UDP_QUERY_NAME, the smallest question a resolver answers."""
    labels = b"".join(bytes([len(label)]) + label.encode() for label in UDP_QUERY_NAME.split("."))
    return struct.pack(">HHHHHH", query_id, 0x0100, 1, 0, 0, 0) + labels + b"\0" + struct.pack(">HH", 1, 1)


def udp_probe(port):
    """(median round trip in seconds or None, share of queries unanswered) of UDP_QUERIES
    DNS queries sent one at a time through an exit's direct inbound. A reply counts when
    it carries the query's id and the response bit."""
    rtts = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for query_id in range(1, UDP_QUERIES + 1):
            query = dns_query(query_id)
            sent = time.monotonic()
            sock.sendto(query, ("127.0.0.1", port))
            while time.monotonic() - sent < UDP_TIMEOUT:
                sock.settimeout(UDP_TIMEOUT - (time.monotonic() - sent))
                try:
                    reply = sock.recv(512)
                except OSError:
                    break
                if len(reply) > 2 and reply[:2] == query[:2] and reply[2] & 0x80:
                    rtts.append(time.monotonic() - sent)
                    break
    return (statistics.median(rtts) if rtts else None), 1 - len(rtts) / UDP_QUERIES


def download(url, proxy=None):
    """{'ttfb': seconds, 'bps': bytes per second or None} of one bounded download by curl,
    None when it failed. The speed is the bytes over the time after the first byte, so a
    slow first byte does not read as a slow link. Cut off at the time limit with bytes in
    hand, a download still counts: the limit is what bounds it. A proxy is a socks5h one,
    which leaves the name to the exit; with none, the request takes the host's own route
    and a proxy variable of the environment is not obeyed."""
    curl = shutil.which("curl")
    if curl is None:
        die("curl not found")
    command = [
        curl,
        "--silent",
        "--output", "/dev/null",
        "--max-time", str(MEASURE_MAX_SECONDS),
        "--connect-timeout", "10",
        "--range", f"0-{MEASURE_BYTES - 1}",
        "--write-out", "%{http_code} %{time_starttransfer} %{time_total} %{size_download}",
    ]
    command += ["--proxy", proxy] if proxy else ["--noproxy", "*"]
    command.append(url)
    try:
        run = subprocess.run(command, capture_output=True, text=True, check=False, timeout=MEASURE_MAX_SECONDS + 10)
        code, ttfb, total, size = run.stdout.split()
        ttfb, total, size = float(ttfb), float(total), int(size)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    if run.returncode not in (0, 28) or code not in ("200", "206") or size <= 0:
        return None
    return {"ttfb": ttfb, "bps": size / (total - ttfb) if total > ttfb else None}


def measure_exits(names):
    """{name: {tcp, ttfb, bps, udp_rtt, udp_loss}} for every name, through one probe. The
    delay and the DNS queries are light and run for all exits together; the download
    fills the link, so one exit takes it at a time."""
    ping, url = ping_url(), measure_url()
    with probe_instance(names, exits=True, prefix="skvpn-measure-") as (port, listeners):
        with ThreadPoolExecutor(max_workers=min(16, 2 * len(names))) as pool:
            delays = pool.map(lambda n: delay(port, n, ping), names)
            udps = pool.map(lambda n: udp_probe(listeners[n][1]), names)
            delays, udps = list(delays), list(udps)
        results = {}
        for name, tcp, (udp_rtt, udp_loss) in zip(names, delays, udps):
            got = download(url, f"socks5h://127.0.0.1:{listeners[name][0]}")
            results[name] = {
                "tcp": tcp,
                "ttfb": got["ttfb"] if got else None,
                "bps": got["bps"] if got else None,
                "udp_rtt": udp_rtt,
                "udp_loss": udp_loss,
            }
        return results


# One row per metric: the name, what it says, and how a result gives the value (None
# leaves the sample out, which is how Prometheus tells "unknown" from zero)
METRICS = (
    ("skvpn_exit_up", "1 when the exit carried a TCP request", lambda r: int(isinstance(r["tcp"], int) or r["ttfb"] is not None)),
    ("skvpn_tcp_latency_seconds", "Time to the first header of a HEAD through the exit", lambda r: r["tcp"] / 1000 if isinstance(r["tcp"], int) else None),
    ("skvpn_tcp_ttfb_seconds", "Time to the first byte of the download through the exit", lambda r: r["ttfb"]),
    ("skvpn_tcp_download_bytes_per_second", "Download speed after the first byte", lambda r: r["bps"]),
    ("skvpn_udp_up", "1 when at least one DNS query came back over UDP", lambda r: int(r["udp_rtt"] is not None)),
    ("skvpn_udp_rtt_seconds", "Median round trip of the DNS queries answered over UDP", lambda r: r["udp_rtt"]),
    ("skvpn_udp_loss_ratio", "Share of the DNS queries sent over UDP that got no answer", lambda r: r["udp_loss"]),
)


def prom_number(value):
    return str(value) if isinstance(value, int) else format(value, ".9g")


def render_metrics(results, timestamp, duration):
    """Prometheus text for node_exporter's textfile collector. The label is the profile
    name alone: nothing about the node itself belongs in a scrape."""
    lines = []
    for metric, text, value in METRICS:
        samples = [(name, value(result)) for name, result in results.items()]
        samples = [(name, v) for name, v in samples if v is not None]
        lines += [f"# HELP {metric} {text}", f"# TYPE {metric} gauge"]
        lines += [f'{metric}{{node="{name}"}} {prom_number(v)}' for name, v in samples]
    lines += [
        "# HELP skvpn_measure_timestamp_seconds Unix time the measurement finished",
        "# TYPE skvpn_measure_timestamp_seconds gauge",
        f"skvpn_measure_timestamp_seconds {int(timestamp)}",
        "# HELP skvpn_measure_duration_seconds How long the whole measurement took",
        "# TYPE skvpn_measure_duration_seconds gauge",
        f"skvpn_measure_duration_seconds {prom_number(duration)}",
    ]
    return "\n".join(lines) + "\n"


def write_textfile(path, text):
    """Whole or not at all: a collector that lists the directory mid-write must not read
    half a file. The temporary file is in the same directory, so the rename cannot cross
    a filesystem, and its name does not end in .prom, which the collector reads."""
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        # mkstemp is 0600, and the collector is another user; the file names profiles only
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def milliseconds(seconds):
    return "-" if seconds is None else f"{seconds * 1000:.0f} ms"


def print_measures(results):
    active = running()
    for name, result in results.items():
        node = read_profile(name) or {"type": "?"}
        tcp = f"{result['tcp']} ms" if isinstance(result["tcp"], int) else result["tcp"] or "unreachable"
        speed = "-" if result["bps"] is None else f"{result['bps'] * 8 / 1e6:.1f} Mbit/s"
        extra = (
            f"tcp {tcp}  first byte {milliseconds(result['ttfb'])}  down {speed}  "
            f"udp {milliseconds(result['udp_rtt'])}, {result['udp_loss'] * 100:.0f}% loss"
        )
        print(profile_line(name, node, active, extra))


# --- subscription -----------------------------------------------------------


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode()
    try:
        return base64.b64decode(raw + "===").decode()
    except Exception:
        return raw


def sync(if_stale=False, fatal=True):
    if not SUB_URL.exists():
        # The timer runs this before any subscription is stored; that is not a failure
        if if_stale:
            return
        die("no subscription stored — run `skvpn sub set <url>` first")
    if if_stale and STAMP.exists() and time.time() - STAMP.stat().st_mtime < MAX_AGE:
        return
    url = SUB_URL.read_text().strip()

    try:
        body = fetch(url)
    except (urllib.error.URLError, OSError) as exc:
        active = running()
        hint = f" — {active} is up, so the fetch went through it" if active else ""
        message = f"subscription unreachable: {exc}{hint}"
        if fatal:
            die(message)
        # Inside `up` a dead fetch must not block the switch: switching away from a dead
        # node is exactly when the fetch has nothing to travel through
        print(f"  ~  {message}; profiles left as they are")
        return

    # The manifest is what tells subscription profiles apart from ones added by hand: a
    # hand-added name is neither overwritten nor pruned, or a hostile subscription entry
    # could silently swap the node behind a name the user trusts
    previous = set(MANIFEST.read_text().split()) if MANIFEST.exists() else set()

    seen = []
    ignored = []
    for uri in (line for line in body.splitlines() if "://" in line):
        try:
            name, config = uri_to_profile(uri)
        except ValueError as exc:
            print(f"  skip  {exc}")
            continue
        stem = slug(name)
        if stem not in previous and profile_path(stem).exists():
            ignored.append(stem)
            print(f"  !  {stem} was added by hand, the subscription entry is ignored")
            continue
        path = write_profile(name, config)
        seen.append(path.stem)
        print(f"  +  {path.stem}")

    # Ignored entries still count as carried: a subscription whose every node the user has
    # added by hand is not an error, and dying here would leave no manifest to ever change
    # that — every later sync would ignore everything again, red forever
    if not seen and not ignored:
        message = "subscription carried nothing sing-box can speak"
        if fatal:
            die(message)
        print(f"  ~  {message}; profiles left as they are")
        return

    # Drop what this subscription used to carry and no longer does
    active = running()
    spared = []
    for gone in sorted(previous - set(seen)):
        path = profile_path(gone)
        if not path.exists():
            continue
        # Kept in the manifest as well as on disk, or the next sync would no longer know it
        # came from here and the orphan would outlive every cleanup
        if active == gone:
            spared.append(gone)
            print(f"  ~  {gone} is up, left in place")
            continue
        path.unlink()
        print(f"  -  {gone}")
        forget(gone)
    MANIFEST.write_text("\n".join(seen + spared) + "\n")

    # Only the mtime is ever read; the URL is a bearer secret and lives 0600 in SUB_URL.
    # Written empty rather than touched, so a stamp that carried the URL heals itself
    STAMP.parent.mkdir(parents=True, exist_ok=True)
    STAMP.write_text("")


# --- split tunnelling -------------------------------------------------------


def is_glob(value):
    return "*" in value or "?" in value


def glob_regex(kind, pattern):
    """A name or path with wildcards as sing-box's process_path_regex — the exact fields
    take no wildcards. `*` is one path segment, `**` any run, `?` one character; a name
    pattern matches the executable's basename, which is what process_name is."""
    body = (
        re.escape(pattern)
        .replace(r"\*\*", ".*")
        .replace(r"\*", "[^/]*")
        .replace(r"\?", "[^/]")
    )
    return ("(^|/)" if kind == "name" else "^") + body + "$"


def regex_glob(regex):
    """(kind, pattern) back from glob_regex's shape, None for a regex written by hand."""
    if regex.startswith("(^|/)") and regex.endswith("$"):
        kind, body = "name", regex[5:-1]
    elif regex.startswith("^") and regex.endswith("$"):
        kind, body = "path", regex[1:-1]
    else:
        return None
    body = body.replace(".*", "**").replace("[^/]*", "*").replace("[^/]", "?")
    return kind, re.sub(r"\\(.)", r"\1", body)


def as_list(value):
    return [value] if isinstance(value, str) else list(value or [])


def split_rules(path):
    """{kind: [values]} read back from one base.d file's route rules; every shown kind
    present, wildcard regexes folded back into the name or path they came from."""
    lists = {kind: [] for kind in SPLIT_SHOWN}
    try:
        rules = json.loads(path.read_text()).get("route", {}).get("rules", [])
    except ValueError:
        die(f"{path} is not JSON — fix or delete it")
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        for kind, field in SPLIT_KINDS.items():
            lists[kind].extend(v for v in as_list(rule.get(field)) if v not in lists[kind])
        for regex in as_list(rule.get("process_path_regex")):
            back = regex_glob(regex)
            kind, value = back if back else ("regex", regex)
            if value not in lists[kind]:
                lists[kind].append(value)
    return lists


def split_load():
    """The imperative list — what `split add`/`rm` edit."""
    if not SPLIT.exists():
        return {kind: [] for kind in SPLIT_SHOWN}
    return split_rules(SPLIT)


def split_declared():
    """The lists the renderers wrote — NixOS options or installer flags — which this
    tool shows but never edits."""
    lists = {kind: [] for kind in SPLIT_SHOWN}
    for path in sorted(BASE_D.glob("*.json")) if BASE_D.is_dir() else []:
        if path == SPLIT:
            continue
        for kind, values in split_rules(path).items():
            lists[kind].extend(v for v in values if v not in lists[kind])
    return lists


def split_save(lists):
    if not any(lists.values()):
        SPLIT.unlink(missing_ok=True)
        return
    # One rule per field, each routed direct: -C appends arrays, so nothing here can
    # reorder or replace the base's rules — bypass is the only shape that composes.
    # Wildcards go to the regex field; a hand-written regex is carried as it is
    fields = [
        ("process_name", [v for v in lists["name"] if not is_glob(v)]),
        ("process_path", [v for v in lists["path"] if not is_glob(v)]),
        (
            "process_path_regex",
            [glob_regex(k, v) for k in ("name", "path") for v in lists[k] if is_glob(v)]
            + lists.get("regex", []),
        ),
        ("ip_cidr", lists["ip"]),
        ("domain_suffix", lists["domain"]),
    ]
    route = [{field: values, "outbound": "direct"} for field, values in fields if values]
    # A bypassed process or domain should resolve outside the tunnel too, like the
    # base's direct zones; addresses have no DNS side
    dns = [
        {field: values, "action": "route", "server": "bootstrap"}
        for field, values in fields
        if values and field != "ip_cidr"
    ]
    config = {"route": {"rules": route}, "dns": {"rules": dns}}
    SPLIT.parent.mkdir(parents=True, exist_ok=True)
    # No secrets in here, and sing-box reads it as the service user
    write_private(SPLIT, json.dumps(config, indent=2) + "\n", 0o644)


def split_kind(args):
    """(kind, values): a leading kind word is consumed, `name` is the default."""
    if args and args[0] in SPLIT_KINDS:
        return args[0], args[1:]
    return "name", args


def catches_sing_box(kind, value):
    """Whether a name or path entry would match sing-box itself. Its own traffic never
    enters the tunnel, so the entry can do nothing right — and a pattern wide enough to
    catch it (`*`, `sing*`, `/**`) catches everything, which is the tunnel switched off."""
    binary = sing_box_binary(required=False)
    targets = ["sing-box"] if kind == "name" else []
    if binary:
        targets.append(os.path.basename(binary) if kind == "name" else binary)
    if is_glob(value):
        return any(re.search(glob_regex(kind, value), target) for target in targets)
    return value in targets


def domain_value(value):
    """A site as typed — a bare name, a URL, `*.example.com` — as the domain suffix
    sing-box matches: the name the client asked for, sniffed or answered, never an
    address, so a CDN sharing its addresses with the world changes nothing."""
    if "://" in value:
        value = urlparse(value).hostname or ""
    value = value.strip().rstrip("/").lower()
    if value.startswith("*."):
        value = value[1:]
    dotted = value.startswith(".")
    try:
        labels = [label.encode("idna").decode() for label in value.lstrip(".").split(".")]
    except UnicodeError:
        die(f"not a domain: {value}")
    value = ("." if dotted else "") + ".".join(labels)
    # A whole zone is written with its dot, `.ru`; without one a single label is a host
    # name, not a suffix, and is refused
    if not re.fullmatch(r"\.[a-z0-9-]+(\.[a-z0-9-]+)*|[a-z0-9-]+(\.[a-z0-9-]+)+", value):
        die(f"not a domain — a whole zone is written with its dot, like .ru: {value}")
    return value


def domain_shown(value):
    """The domain as a person reads it, with the wire form beside it when they differ:
    `пример.рф (xn--e1afmkfd.xn--p1ai)`. The file keeps the wire form — DNS carries
    nothing else — and this only ever changes how it is printed."""
    try:
        labels = [
            label.encode("ascii").decode("idna") if label.startswith("xn--") else label
            for label in value.lstrip(".").split(".")
        ]
    except UnicodeError:
        return value
    readable = ("." if value.startswith(".") else "") + ".".join(labels)
    return value if readable == value else f"{readable} ({value})"


def split_shown(kind, value):
    return domain_shown(value) if kind == "domain" else value


def split_check(kind, value):
    if kind == "domain":
        return domain_value(value)
    if kind == "ip":
        if is_glob(value):
            die(f"addresses take a CIDR, not a wildcard: {value}")
        try:
            return str(ipaddress.ip_network(value, strict=False))
        except ValueError:
            die(f"not an address or CIDR: {value}")
    if kind == "path":
        if not value.startswith("/"):
            die(f"a path is absolute: {value}")
    elif not value or "/" in value:
        die(f"{value!r} is not a process name — a path is `skvpn split add path {value}`")
    if catches_sing_box(kind, value):
        die(
            f"{value} would match sing-box itself — its traffic never enters the tunnel, "
            "and a pattern wide enough to catch it catches everything"
        )
    return value


def split_notice():
    """sing-box reads its routing rules only at start, and dropping the tunnel is the
    user's call: the file is written, the restart is asked for, never done here."""
    active = running()
    if active is None:
        print("     takes effect on the next `skvpn up`")
        return
    print(f"     {active} is still on the old rules — apply with `sudo skvpn restart`")


SPLIT_USAGE = (
    "usage: skvpn split [ls | add [name|path|ip|domain] <value>… "
    "| rm [name|path|ip|domain] <value>…]"
)


def cmd_split(args):
    if args == ["ls"] or not args:
        # Both lists, since both are on the wire: the declared one is the renderers'
        # and only shown, the other is what add/rm edit
        declared = split_declared()
        own = split_load()
        for kind in SPLIT_SHOWN:
            for value in declared[kind]:
                print(f"  {kind:<5} {split_shown(kind, value):<40} declared")
            for value in own[kind]:
                if value not in declared[kind]:
                    print(f"  {kind:<5} {split_shown(kind, value)}")
        return
    if args[0] not in ("add", "rm"):
        die(SPLIT_USAGE)
    kind, values = split_kind(args[1:])
    if not values:
        # `split add ip` alone is a kind without a value, not a process called ip:
        # that one is spelled `split add name ip`
        die(SPLIT_USAGE)
    need_root()
    lists = split_load()
    for value in values:
        value = split_check(kind, value)
        if args[0] == "add":
            if value in lists[kind]:
                print(f"  =  {kind} {value} (already listed)")
                continue
            lists[kind].append(value)
            print(f"  +  {kind} {value}")
        else:
            if value not in lists[kind]:
                die(f"not in the split list: {kind} {value}")
            lists[kind].remove(value)
            print(f"  -  {kind} {value}")
    split_save(lists)
    split_notice()


# --- tor --------------------------------------------------------------------


def need_tor():
    if not TOR_PROFILE.exists():
        die("Tor is not configured here — services.skvpn.tor.enable, or install.sh --tor")


def tor_transports():
    """The transports the torrc runs, from its ClientTransportPlugin lines: Moat is asked
    for these and no others, since a bridge of any other kind is one Tor cannot use."""
    transports = []
    try:
        lines = TORRC.read_text().splitlines()
    except OSError:
        die(f"cannot read {TORRC}")
    for line in lines:
        words = line.split()
        if len(words) > 2 and words[0] == "ClientTransportPlugin":
            transports += [t for t in words[1].split(",") if t not in transports]
    return transports


def tor_socks():
    """The SOCKS address the torrc gives users: its first SocksPort."""
    try:
        for line in TORRC.read_text().splitlines():
            words = line.split()
            if len(words) > 1 and words[0] == "SocksPort":
                return words[1]
    except OSError:
        pass
    return None


def preset_countries():
    """The countries whose presets the live base routes direct, by the tags of their
    rule-sets: the bridges a censor there has not yet blocked are the ones wanted."""
    tags = set()
    for path in sorted(BASE_D.glob("*.json")) if BASE_D.is_dir() else []:
        try:
            tags.update(rs.get("tag") for rs in json.loads(path.read_text()).get("route", {}).get("rule_set", []))
        except (OSError, ValueError, AttributeError):
            continue
    return [p["tag"] for p in policy()["presets"] if {f"geosite-{p['tag']}", f"geoip-{p['tag']}"} & tags]


# Moat can hand out an obfs4 bridge on a LAN address. obfs4 dials the address in its line,
# so such a bridge never answers; snowflake and webtunnel put documentation placeholders
# there and reach a broker or a URL instead
DIALLED_TRANSPORTS = {"obfs4"}
LOCAL_NETWORKS = [
    ipaddress.ip_network(n)
    for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7")
]


def reachable_bridge(kind, line):
    """False for a bridge whose transport dials a LAN, loopback or link-local address."""
    if kind not in DIALLED_TRANSPORTS:
        return True
    host = line.split()[1].rsplit(":", 1)[0].strip("[]")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return True
    return not (
        address.is_loopback
        or address.is_link_local
        or address.is_unspecified
        or any(address in network for network in LOCAL_NETWORKS)
    )


def moat_bridges(country, transports):
    """[(type, bridge line)] Moat recommends for the country, of the transports given, in
    the order it recommends them. Moat says what went wrong in an `errors` list."""
    url = os.environ.get("SKVPN_MOAT_URL") or policy()["tor"]["moat"]
    body = json.dumps({"country": country, "transports": transports}).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/vnd.api+json", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=MOAT_TIMEOUT) as resp:
            answer = json.loads(resp.read())
    except (urllib.error.URLError, OSError, ValueError) as exc:
        active = running()
        hint = f" — {active} is up, so the request went through it" if active else ""
        die(f"Moat unreachable: {exc}{hint}")
    errors = answer.get("errors") if isinstance(answer, dict) else None
    if errors:
        die(f"Moat refused: {'; '.join(str(e.get('detail', e)) for e in errors)}")
    bridges = []
    for setting in answer.get("settings") or []:
        offer = setting.get("bridges", {}) if isinstance(setting, dict) else {}
        if offer.get("type") in transports:
            bridges += [(offer["type"], line) for line in offer.get("bridge_strings", [])]
    for kind, line in bridges:
        if not reachable_bridge(kind, line):
            print(f"  -  {kind} {line.split()[1]}: a local address, never reachable")
    bridges = [bridge for bridge in bridges if reachable_bridge(*bridge)]
    if not bridges:
        die(f"Moat offered no bridges for {country} of a kind this Tor runs ({', '.join(transports)})")
    return bridges


def bridge_lines(path):
    """The bridges of one file in the bridges directory, without the `Bridge` word."""
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return []
    return [line.split(None, 1)[1] for line in lines if line.startswith("Bridge ")]


def tor_bridges():
    """({type: count}, country) of Moat's bridges; ({}, None) without them."""
    counts, country = {}, None
    try:
        lines = MOAT_BRIDGES.read_text().splitlines()
    except OSError:
        return counts, country
    for line in lines:
        words = line.split()
        if words[:2] == ["#", "country"] and len(words) == 3:
            country = words[2]
        elif len(words) > 1 and words[0] == "Bridge":
            counts[words[1]] = counts.get(words[1], 0) + 1
    return counts, country


def kinds_text(lines):
    counts = {}
    for line in lines:
        counts[line.split()[0]] = counts.get(line.split()[0], 0) + 1
    return ", ".join(f"{kind} {count}" for kind, count in counts.items())


def bridges_line():
    counts, country = tor_bridges()
    own = bridge_lines(OWN_BRIDGES)
    lines = []
    if counts:
        age = int((time.time() - MOAT_BRIDGES.stat().st_mtime) / 60)
        kinds = ", ".join(f"{kind} {count}" for kind, count in counts.items())
        lines.append(f"  bridges   {kinds} ({country or 'country unknown'}, {age} min ago)")
    if own:
        lines.append(f"  own       {kinds_text(own)}")
    if not lines:
        lines.append(
            "  bridges   none — `sudo skvpn tor bridges update` fetches them,"
            " `sudo skvpn tor bridges add` takes your own"
        )
    return "\n".join(lines)


def tor_bootstrap():
    """The last bootstrap line Tor logged, as `73% (loading_descriptors)`; None when the
    journal is not readable here, which takes root or the journal's group."""
    result = subprocess.run(
        ["journalctl", "-u", TOR_UNIT, "-o", "cat", "--no-pager", "-n", "500"],
        capture_output=True,
        text=True,
        check=False,
    )
    found = re.findall(r"Bootstrapped (\d+%(?: \([a-z_]+\))?)", result.stdout)
    return found[-1] if found else None


def bridges_update(args):
    country = None
    rest = iter(args)
    for arg in rest:
        if arg == "--country":
            country = next(rest, "").lower()
            if not re.fullmatch(r"[a-z]{2}", country):
                die("usage: skvpn tor bridges update [--country CC] — a two-letter country code")
        else:
            die("usage: skvpn tor bridges update [--country CC]")
    need_root()
    need_tor()
    if country is None:
        countries = preset_countries()
        if len(countries) != 1:
            found = f"the base routes {', '.join(countries)} direct" if countries else "no preset names one"
            die(f"which country's bridges? {found} — pass --country CC")
        country = countries[0]
    transports = tor_transports()
    if not transports:
        die(f"{TORRC} runs no transport plugin, so no bridge would work")
    bridges = moat_bridges(country, transports)
    TOR_BRIDGES.mkdir(parents=True, exist_ok=True)
    # Tor reads it as its own user; Moat hands these out to anyone who asks
    lines = [f"# country {country}"] + [f"Bridge {line}" for _, line in bridges]
    write_private(MOAT_BRIDGES, "\n".join(lines) + "\n", 0o644)
    for kind in dict.fromkeys(kind for kind, _ in bridges):
        print(f"  +  {kind} ×{sum(1 for k, _ in bridges if k == kind)}")
    tor_reload()


def tor_reload():
    """Tor rereads its config on a reload, bridges included, and a unit the empty
    directory kept from starting starts now. With no bridge left, Tor would refuse the
    config and keep running on the old one, so it stops instead."""
    if not bridge_lines(MOAT_BRIDGES) and not bridge_lines(OWN_BRIDGES):
        result = probe("stop", TOR_UNIT)
        if result.returncode != 0:
            die(f"{failure(result)} — see journalctl -u {TOR_UNIT}")
        print(f"  ■  {TOR_UNIT}: no bridges left")
        return
    result = probe("reload-or-restart", TOR_UNIT)
    if result.returncode != 0:
        die(f"{failure(result)} — see journalctl -u {TOR_UNIT}")
    print(f"  ↻  {TOR_UNIT}")


def bridge_address(line):
    """The host:port of a bridge line without its `Bridge` word."""
    return line.split()[1]


def own_bridge(line, transports):
    """A pasted line as a bridge line without the `Bridge` word, or the reason it is
    refused. Bots hand out lines with and without that word."""
    words = line.split()
    if words[:1] == ["Bridge"]:
        words = words[1:]
    if len(words) < 3:
        return None, f"not a bridge line: {line}"
    if words[0] not in transports:
        return None, f"{words[0]}: this Tor runs only {', '.join(transports)}"
    host, _, port = words[1].rpartition(":")
    if not host or not port.isdigit() or not 0 < int(port) < 65536:
        return None, f"no address:port in: {line}"
    bridge = " ".join(words)
    if not reachable_bridge(words[0], bridge):
        return None, f"{words[1]}: a local address, never reachable"
    return bridge, None


def bridges_add(args):
    """Own bridges, from the arguments or, with none, one per line from stdin."""
    need_root()
    need_tor()
    transports = tor_transports()
    pasted = args or sys.stdin.read().splitlines()
    lines = [line.strip() for line in pasted]
    lines = [line for line in lines if line and not line.startswith("#")]
    if not lines:
        die("usage: skvpn tor bridges add [LINE…] — or paste the lines on stdin")
    found = [own_bridge(line, transports) for line in lines]
    errors = [error for _, error in found if error]
    if errors:
        die("; ".join(errors))
    own = bridge_lines(OWN_BRIDGES)
    added = [bridge for bridge, _ in found if bridge not in own]
    added = list(dict.fromkeys(added))
    TOR_BRIDGES.mkdir(parents=True, exist_ok=True)
    write_private(OWN_BRIDGES, "".join(f"Bridge {b}\n" for b in own + added), 0o644)
    for bridge in added:
        print(f"  +  {bridge.split()[0]} {bridge_address(bridge)}")
    if not added:
        print("  =  every line is already there")
        return
    tor_reload()


def bridges_rm(args):
    """Own bridges out, by the address `bridges ls` shows."""
    if not args:
        die("usage: skvpn tor bridges rm ADDRESS…")
    need_root()
    need_tor()
    own = bridge_lines(OWN_BRIDGES)
    unknown = [a for a in args if a not in map(bridge_address, own)]
    if unknown:
        die(f"no own bridge at {', '.join(unknown)} — `skvpn tor bridges ls` lists them")
    kept = [bridge for bridge in own if bridge_address(bridge) not in args]
    if kept:
        write_private(OWN_BRIDGES, "".join(f"Bridge {b}\n" for b in kept), 0o644)
    else:
        OWN_BRIDGES.unlink()
    for address in args:
        print(f"  -  {address}")
    tor_reload()


TOR_USAGE = (
    "usage: skvpn tor [status | bridges [ls | update [--country CC]"
    " | add [LINE…] | rm ADDRESS…]]"
)


def cmd_tor(args):
    """skvpn's own Tor: its state, and the bridges it reaches the network through."""
    if args[:1] == ["bridges"]:
        handlers = {"update": bridges_update, "add": bridges_add, "rm": bridges_rm}
        if args[1:2] and args[1] in handlers:
            handlers[args[1]](args[2:])
            return
        if args[1:] not in ([], ["ls"]):
            die(TOR_USAGE)
        need_tor()
        print(bridges_line())
        for bridge in bridge_lines(OWN_BRIDGES):
            print(f"            {bridge.split()[0]} {bridge_address(bridge)}")
        return
    if args not in ([], ["status"]):
        die(TOR_USAGE)
    need_tor()
    state = probe("is-active", TOR_UNIT).stdout.strip() or "unknown"
    print(f"  tor       {state}")
    bootstrap = tor_bootstrap() if state == "active" else None
    if bootstrap:
        print(f"  bootstrap {bootstrap}")
    print(bridges_line())
    socks = tor_socks()
    if socks:
        print(f"  socks     {socks}")
    if running() == TOR_NAME:
        print("  all traffic goes through Tor")


def tor_profile(via):
    """The `tor` profile: tor.json as rendered, and with a node to go through, that node
    under VIA_TAG where Tor's own traffic would have left direct."""
    try:
        config = json.loads(TOR_PROFILE.read_text())
    except (OSError, ValueError):
        die(f"{TOR_PROFILE} is not readable JSON")
    if via is None:
        return config
    if via == TOR_NAME or not profile_path(via).exists():
        die(f"no such node to go through: {via}")
    node = read_profile(via)
    if node is None:
        die(f"broken profile: {via}")
    config["outbounds"].append({**node, "tag": VIA_TAG})
    for rule in config.get("route", {}).get("rules", []):
        if "user" in rule and rule.get("outbound") == "direct":
            rule["outbound"] = VIA_TAG
    return config


# --- commands ---------------------------------------------------------------


def cmd_sub(args):
    need_root()
    if args[:1] == ["set"]:
        if len(args) != 2:
            die("usage: skvpn sub set <url>")
        CONF.mkdir(parents=True, exist_ok=True)
        write_private(SUB_URL, args[1] + "\n", 0o600)
        print("  stored")
        sync()
    elif args[:1] == ["sync"] or not args:
        sync(if_stale="--if-stale" in args)
    else:
        die("usage: skvpn sub [set <url> | sync [--if-stale]]")


def cmd_add(args):
    need_root()
    if not args:
        die("usage: skvpn add <uri>…")
    for uri in args:
        try:
            name, config = uri_to_profile(uri)
        except ValueError as exc:
            print(f"  skip  {exc}")
            continue
        print(f"  +  {write_profile(name, config).stem}")


def cmd_rm(args):
    need_root()
    if not args:
        die("usage: skvpn rm <name>…")
    active = running()
    for name in args:
        path = profile_path(name)
        if not path.exists():
            die(f"no such profile: {name}")
        if active == path.stem:
            die(f"{path.stem} is up — `skvpn down` first")
        path.unlink()
        print(f"  -  {path.stem}")
        forget(path.stem)
        disown(path.stem)


def cmd_ls(args):
    # Names only, no root: the profiles directory is world-listable while the files stay
    # 0640, and this is what shell completion calls on every TAB
    if args == ["--names"]:
        for name in profile_names():
            print(name)
        return
    servers, args = take_flag(args, "--servers")
    if args:
        die("usage: skvpn ls [--names | --servers]")
    active = running()
    if not os.access(PROFILES, os.R_OK):
        die(f"cannot read {PROFILES} — try `sudo skvpn ls`")
    for name in profile_names():
        # The directory lists for everyone, the contents carry node credentials and do not
        try:
            node = read_profile(name)
        except PermissionError:
            die("profile contents are root-only — try `sudo skvpn ls`")
        if node is None:
            # Named instead of a traceback
            print(f"   {name:<24} broken profile")
            continue
        print(profile_line(name, node, active, servers=servers))


def cmd_up(args):
    need_root()
    via = None
    if len(args) == 3 and args[1] == "--via":
        via = slug(args[2])
    elif len(args) != 1:
        die("usage: skvpn up <name> | up tor [--via <name>]")
    name = slug(args[0])
    if via is not None and name != TOR_NAME:
        die(f"--via goes with `up {TOR_NAME}`: only Tor's own traffic has a node to go through")
    if name == TOR_NAME:
        need_tor()
    elif not profile_path(name).exists():
        die(f"no such profile: {name}")
    sync(if_stale=True, fatal=False)
    # Written after the sync, so a node it just refreshed is the one Tor goes through, and
    # on every up, so the profile follows tor.json across a rebuild
    if name == TOR_NAME:
        write_profile(TOR_NAME, tor_profile(via))
    # The sync may just have pruned the very profile asked for; starting it anyway would
    # fail at the unit and still be remembered as the boot choice
    if not profile_path(name).exists():
        die(f"the subscription no longer carries {name}")
    hold()
    stop_active()
    ACTIVE.unlink(missing_ok=True)
    result = probe("start", UNIT.format(name))
    if result.returncode != 0:
        # Restart=on-failure would bring it back beside the guard, and its next failure
        # would hold the network the guard serves
        probe("stop", UNIT.format(name))
        # The old profile is already stopped: fall back to off, which is the guarded state
        if GUARD.exists():
            start_guard()
            die(failure(result))
        die(f"{failure(result)}\n  {HELD}")
    # Remembered only once it is up, so a broken profile is not replayed on every boot
    ACTIVE.parent.mkdir(parents=True, exist_ok=True)
    ACTIVE.write_text(name + "\n")
    print(f"  →  {name}")


def cmd_down(args):
    """Stop the profile and forget the boot choice; the guard takes over, or with
    --no-guard nothing does — off entirely, until the next up or boot."""
    no_guard, args = take_flag(args, "--no-guard")
    if args:
        die("usage: skvpn down [--no-guard]")
    need_root()
    guarded = GUARD.exists() and not no_guard
    if guarded:
        hold()
    stop_active()
    ACTIVE.unlink(missing_ok=True)
    if guarded:
        start_guard()
    else:
        # Off is the open network, a hold a crash left behind included
        release()


def cmd_restart(_args):
    """Start the active profile over on the base as it is now — the way a changed split
    list, or any other base.d edit, gets onto the wire. With no profile up, the guard."""
    need_root()
    active = running()
    if active is None and not guard_active():
        die("nothing is up — `skvpn up <name>` starts a profile")
    unit = GUARD_UNIT if active is None else UNIT.format(active)
    hold()
    result = probe("restart", unit)
    if result.returncode != 0:
        die(f"{failure(result)}\n  {HELD}")
    print(f"  ↻  {active or 'guard'}")


def cmd_restore(_args):
    """Boot-time half of `up` — no fetching and no choosing, just the pin or what was
    last up; the guard when there is nothing to bring back."""
    need_root()
    name, _ = boot_choice()
    if name is None:
        start_guard(wait=False)
        return
    if not profile_path(name).exists():
        # Off is the guarded state, and boot is never left unguarded over a missing file
        start_guard(wait=False)
        die(f"remembered profile is gone: {name}")
    systemctl("start", "--no-block", UNIT.format(name))
    print(f"  →  {name}")


def boot_line():
    name, is_pin = boot_choice()
    if name is None:
        return "  on boot   nothing"
    return f"  on boot   {name}" if is_pin else f"  on boot   {name} (last up)"


def cmd_boot(args):
    """Pin a profile for boot regardless of what is up, or go back to following `up`.
    `last` is the word for the latter, so a profile of that name cannot be pinned."""
    if not args:
        print(boot_line())
        return
    if len(args) != 1:
        die("usage: skvpn boot [<name> | last]")
    need_root()
    if args[0] == "last":
        BOOT.unlink(missing_ok=True)
        print("  ⚓  last up")
        return
    name = slug(args[0])
    if not profile_path(name).exists():
        die(f"no such profile: {name}")
    BOOT.parent.mkdir(parents=True, exist_ok=True)
    BOOT.write_text(name + "\n")
    print(f"  ⚓  {name}")


def cmd_ping(args):
    """Latency to the ping site through every profile — or the named ones — measured
    by one throwaway sing-box, so nothing is switched. `set` is reserved for the target,
    so a profile of that name is only reachable through the bare form."""
    need_root()
    if args[:1] == ["set"]:
        if len(args) != 2:
            die("usage: skvpn ping set <host|url>")
        url = normalize_ping_target(args[1])
        CONF.mkdir(parents=True, exist_ok=True)
        write_private(PING_URL, url + "\n", 0o644)
        print(f"  stored  {url}")
        return
    servers, args = take_flag(args, "--servers")
    names = [slug(arg) for arg in args] or node_names()
    if not names:
        die("no profiles")
    for name in names:
        if not profile_path(name).exists():
            die(f"no such profile: {name}")
    print_pings(measure(names), servers)


def cmd_measure(args):
    """Latency, time to first byte, download speed and UDP round trip and loss through
    every profile — or the named ones — by the same kind of throwaway sing-box `ping`
    starts. With --textfile the numbers go to a node_exporter textfile instead of the
    screen. `set` is reserved for the download target, as it is for ping's."""
    need_root()
    if args[:1] == ["set"]:
        url = args[1] if len(args) == 2 else ""
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname:
            die("usage: skvpn measure set <https url of a file of at least a few megabytes>")
        CONF.mkdir(parents=True, exist_ok=True)
        write_private(MEASURE_URL, url + "\n", 0o644)
        print(f"  stored  {url}")
        return
    textfile = None
    names = []
    rest = iter(args)
    for arg in rest:
        if arg == "--textfile":
            textfile = next(rest, None)
            if not textfile:
                die("usage: skvpn measure [--textfile PATH] [<name>…]")
            textfile = Path(textfile)
        elif arg.startswith("-"):
            die("usage: skvpn measure [--textfile PATH] [<name>…]")
        else:
            names.append(slug(arg))
    names = names or node_names()
    # On a timer the textfile is the answer even with nothing to measure: it must also
    # clear the samples of a profile that is gone, and a red unit would say nothing more
    if not names and textfile is None:
        die("no profiles")
    for name in names:
        if not profile_path(name).exists():
            die(f"no such profile: {name}")
    if textfile is not None and not textfile.parent.is_dir():
        die(f"no such directory: {textfile.parent}")
    started = time.monotonic()
    results = measure_exits(names) if names else {}
    if textfile is None:
        print_measures(results)
        return
    try:
        write_textfile(textfile, render_metrics(results, time.time(), time.monotonic() - started))
    except OSError as exc:
        die(f"cannot write {textfile}: {exc}")
    print(f"  wrote  {textfile}")


def cmd_status(args):
    servers, args = take_flag(args, "--servers")
    if args not in ([], ["--ping"]) or (servers and not args):
        die("usage: skvpn status [--ping [--servers]]")
    if args:
        need_root()
    active = running()
    if active is None and guard_active():
        print("  profile   none, guard on")
    else:
        print(f"  profile   {active or 'none'}")
    # A choice is kept either way, but with restore off it is not what boot does
    if boot_choice()[0] is not None and restore_enabled():
        print(boot_line())
    if STAMP.exists():
        age = int((time.time() - STAMP.stat().st_mtime) / 60)
        print(f"  synced    {age} min ago")
    if args and node_names():
        print()
        print_pings(measure(node_names()), servers)


# --- top --------------------------------------------------------------------


def clash_api():
    """(address, secret) of the Clash API the live base opens, read from the base itself:
    the file is what the running sing-box was started with. None when it opens none."""
    if not BASE_D.is_dir():
        return None
    for path in sorted(BASE_D.glob("*.json")):
        try:
            api = json.loads(path.read_text())["experimental"]["clash_api"]
            if api["external_controller"]:
                return api["external_controller"], api.get("secret", "")
        except (OSError, ValueError, LookupError, TypeError):
            continue
    return None


def scaled(value):
    for unit, size in (("GB", 1e9), ("MB", 1e6), ("kB", 1e3)):
        if value >= size:
            return f"{value / size:.1f} {unit}"
    return f"{value:.0f} B"


def traffic_stream(address, secret, events):
    """Feeds ('sample', up, down) per second from the Clash API's /traffic into `events`,
    then a final ('error', why): the stream has no end of its own but a failure."""
    headers = {"Authorization": f"Bearer {secret}"} if secret else {}
    # Loopback, so an http_proxy in the environment must not get in the way
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(urllib.request.Request(f"http://{address}/traffic", headers=headers), timeout=10) as resp:
            for line in resp:
                sample = json.loads(line)
                events.put(("sample", int(sample["up"]), int(sample["down"])))
        events.put(("error", "the Clash API closed the stream — did the tunnel restart?"))
    except urllib.error.HTTPError as exc:
        hint = " — the secret in base.d is not the one the running sing-box has, restart the tunnel" if exc.code == 401 else ""
        events.put(("error", f"the Clash API answered {exc.code}{hint}"))
    except (OSError, ValueError, LookupError, TypeError) as exc:
        events.put(("error", f"the Clash API stream failed: {exc}"))


def tunnel_download(events):
    """The download key: the measure target by the host's own route, which is the live
    tunnel — the one place a download goes through it on purpose."""
    got = download(measure_url())
    if got is None or got["bps"] is None:
        events.put(("download", "failed"))
    else:
        events.put(("download", f"{got['bps'] * 8 / 1e6:.1f} Mbit/s, first byte {milliseconds(got['ttfb'])}"))


def spark(values):
    top = max(values, default=0)
    return "".join("▁▂▃▄▅▆▇█"[min(7, int(7 * v / top))] if top else "▁" for v in values)


def draw_top(state):
    lines = [
        f"skvpn top  {state['profile']}",
        "",
        f"  rx  {scaled(state['down'])}/s   peak {scaled(state['peak_down'])}/s",
        f"  tx  {scaled(state['up'])}/s   peak {scaled(state['peak_up'])}/s",
        "",
        f"  {spark(state['history'])}",
        "",
        f"  total  rx {scaled(state['total_down'])}  tx {scaled(state['total_up'])}  in {state['seconds']} s",
        "",
        "  d  measure download speed through the tunnel (the monitor counts that download too)",
        "  q  quit",
    ]
    if state["download"]:
        lines += ["", f"  download  {state['download']}"]
    # Home, then every line cleared to its end, then what is left of the screen
    sys.stdout.write("\x1b[H" + "".join(f"{line}\x1b[K\n" for line in lines) + "\x1b[J")
    sys.stdout.flush()


def top_screen(events, profile):
    """The live view: redrawn on each sample and key. Returns the error that ended it,
    None for q."""
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    state = {
        "profile": profile,
        "up": 0,
        "down": 0,
        "peak_up": 0,
        "peak_down": 0,
        "total_up": 0,
        "total_down": 0,
        "seconds": 0,
        "history": [],
        "download": "",
    }
    failure = None
    try:
        tty.setcbreak(fd)
        sys.stdout.write("\x1b[?1049h\x1b[?25l")
        draw_top(state)
        while failure is None:
            dirty = False
            if select.select([fd], [], [], 0.2)[0]:
                key = os.read(fd, 1)
                if key == b"q":
                    return None
                if key == b"d" and not state["download"].startswith("running"):
                    state["download"] = "running… the monitor counts it in rx"
                    threading.Thread(target=tunnel_download, args=(events,), daemon=True).start()
                    dirty = True
            while True:
                try:
                    event = events.get_nowait()
                except queue.Empty:
                    break
                dirty = True
                if event[0] == "sample":
                    _, up, down = event
                    state.update(up=up, down=down, seconds=state["seconds"] + 1)
                    state["peak_up"], state["peak_down"] = max(state["peak_up"], up), max(state["peak_down"], down)
                    state["total_up"] += up
                    state["total_down"] += down
                    state["history"] = (state["history"] + [down])[-60:]
                elif event[0] == "download":
                    state["download"] = event[1]
                else:
                    failure = event[1]
            if dirty:
                draw_top(state)
        return failure
    finally:
        sys.stdout.write("\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def cmd_top(args):
    """Live rx and tx speed through the tunnel, from the Clash API of the running
    sing-box. On a terminal it is a screen with a download key; piped it prints one line
    per second, and `--count N` stops after N of them."""
    need_root()
    count = None
    if args[:1] == ["--count"] and len(args) == 2 and args[1].isdigit() and int(args[1]) > 0:
        count = int(args[1])
    elif args:
        die("usage: skvpn top [--count N]")
    api = clash_api()
    if api is None:
        die("the live base opens no Clash API — turn on services.skvpn.monitor.enable and restart the tunnel once")
    address, secret = api
    # The secret goes in a header: an API anywhere but here would carry it off the host
    if address.rsplit(":", 1)[0] not in LOOPBACK_HOSTS:
        die(f"the Clash API listens on {address}, not on loopback — refusing to send the secret there")
    events = queue.Queue()
    threading.Thread(target=traffic_stream, args=(address, secret, events), daemon=True).start()
    try:
        if sys.stdin.isatty() and sys.stdout.isatty():
            failure = top_screen(events, running() or "no profile")
            if failure:
                die(failure)
            return
        seen = 0
        while True:
            event = events.get()
            if event[0] == "error":
                die(event[1])
            print(f"rx {scaled(event[2])}/s  tx {scaled(event[1])}/s", flush=True)
            seen += 1
            if count is not None and seen >= count:
                return
    except KeyboardInterrupt:
        # Ctrl-C is how a piped run ends, and the screen has put the terminal back by now
        return


# --- export -----------------------------------------------------------------

# Kept out of the phone's TUN, so that the LAN reaches the phone: a VPN that takes these
# answers a LAN peer from inside the tunnel, and Syncthing on the LAN never connects
PRIVATE = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "fc00::/7",
    "fe80::/10",
]


def rule_set_sources():
    """{tag: URL} for every rule-set policy.json names, under the tags the base and the
    guard give them. A phone fetches by URL what the host reads from disk, and the tag is
    what identifies the file: its path on the host carries a store hash, or another name"""
    data = policy()
    sources = data["ruleSets"]

    def url(kind, name):
        return f"https://raw.githubusercontent.com/{sources[kind]}/{sources['branch']}/{name}"

    tags = {}
    for preset in data["presets"]:
        tags[f"geosite-{preset['tag']}"] = url("geosite", preset["geosite"])
        tags[f"geoip-{preset['tag']}"] = url("geoip", preset["geoip"])
    tags[f"geosite-{data['guard']['tag']}"] = url("geosite", data["guard"]["geosite"])
    return tags


def load_base():
    path = BASE_D / "00-base.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        die(f"no readable base at {path}")


def sfa_config(names, active, tailscale, tor=False):
    """A whole config for sing-box for Android: every profile in one selector, the host's
    direct policy with its rule-sets fetched by URL, and the tailnet as an endpoint
    when asked. The phone has no other source for any of it. With `tor`, Orbot's SOCKS
    port is one more exit in the selector and where .onion names go: SFA runs no Tor of
    its own, and Orbot without its VPN leaves the one VPN slot to SFA."""
    base = load_base()
    sources = rule_set_sources()
    nodes = []
    for name in names:
        node = read_profile(name)
        if node is None:
            die(f"broken profile: {name}")
        nodes.append({**node, "tag": name})

    rule_sets = {}

    def fetchable(tags):
        """The tags a phone can fetch, each declared once; the rest named and left out."""
        kept = []
        for tag in tags:
            if tag not in sources:
                print(f"skvpn: {tag} has no public source — left out", file=sys.stderr)
                continue
            kept.append(tag)
            rule_sets[tag] = {
                "tag": tag,
                "type": "remote",
                "format": "binary",
                "url": sources[tag],
                "http_client": "through-proxy",
            }
        return kept

    # Domain and address kinds of both split lists; base zones are domain rules too.
    # Process rules name the host's programs, which a phone does not have
    declared, imperative = split_declared(), split_load()
    zones = list(dict.fromkeys(declared["domain"] + imperative["domain"]))
    ips = list(dict.fromkeys(declared["ip"] + imperative["ip"]))
    tags = fetchable(
        tag
        for rule in base.get("route", {}).get("rules", [])
        if rule.get("outbound") == "direct"
        for tag in as_list(rule.get("rule_set"))
    )
    geosite = [tag for tag in tags if tag.startswith("geosite-")]
    remote = next(s for s in base["dns"]["servers"] if s.get("tag") == "remote")

    # The host's guard, as the Direct mode the phone switches to instead of stopping:
    # what the guard refuses stays refused, and the rest leaves direct
    guarded = []
    if GUARD.exists():
        for rule in json.loads(GUARD.read_text()).get("route", {}).get("rules", []):
            if rule.get("action") != "reject":
                continue
            if rule.get("domain_suffix"):
                guarded.append({"domain_suffix": rule["domain_suffix"]})
            kept = fetchable(as_list(rule.get("rule_set")))
            if kept:
                guarded.append({"rule_set": kept})

    dns_rules = []
    route_rules = [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}]
    tor_policy = policy()["tor"]
    if tor:
        # Orbot's own names, ahead of everything: through the selector they would wait on
        # the `tor` exit, which is Orbot, and Orbot cannot reach a bridge without them
        dns_rules.append({"package_name": [tor_policy["orbot"]["package"]], "action": "route", "server": "local"})
        dns_rules.append({"domain_suffix": [tor_policy["onion"]], "action": "route", "server": "onion"})
        route_rules += [
            # Orbot's own traffic, ahead of everything: through the `tor` exit it would
            # be its own input. Direct, since Orbot brings its own bridges
            {"package_name": [tor_policy["orbot"]["package"]], "outbound": "direct"},
            {"domain_suffix": [tor_policy["onion"]], "outbound": "tor"},
        ]
    if tailscale:
        # The server itself says which names are the tailnet's, short ones included
        dns_rules.append({"preferred_by": "tailnet", "action": "route", "server": "tailnet"})
        route_rules.append({"ip_cidr": policy()["tailnet"], "outbound": "tailnet"})
    if guarded:
        for match in guarded:
            dns_rules.append({"clash_mode": "Direct", **match, "action": "predefined", "rcode": "REFUSED"})
            route_rules.append({"clash_mode": "Direct", **match, "action": "reject"})
        dns_rules.append({"clash_mode": "Direct", "action": "route", "server": "local"})
        route_rules.append({"clash_mode": "Direct", "outbound": "direct"})
    route_rules.append({"ip_is_private": True, "outbound": "direct"})
    if zones:
        dns_rules.append({"domain_suffix": zones, "action": "route", "server": "local"})
        route_rules.append({"domain_suffix": zones, "outbound": "direct"})
    if geosite:
        dns_rules.append({"rule_set": geosite, "action": "route", "server": "local"})
    if tags:
        route_rules.append({"rule_set": tags, "outbound": "direct"})
    if ips:
        route_rules.append({"ip_cidr": ips, "outbound": "direct"})

    servers = [
        {"tag": "local", "type": "local"},
        {**remote, "domain_resolver": "local"},
    ]
    if tailscale:
        servers.append({
            "tag": "tailnet",
            "type": "tailscale",
            "endpoint": "tailnet",
            "accept_default_resolvers": False,
            # A phone has no search domain: `se-1` resolves only if the tailnet expands it
            "accept_search_domain": True,
        })
    exits = list(names)
    if tor:
        servers.append({"tag": "onion", "type": "fakeip", "inet4_range": tor_policy["fakeip"]})
        nodes.append({
            "type": "socks",
            "tag": "tor",
            "server": "127.0.0.1",
            "server_port": tor_policy["orbot"]["socksPort"],
        })
        exits.append("tor")
    config = {
        "log": {"level": "warn", "timestamp": True},
        "dns": {
            "servers": servers,
            "rules": dns_rules,
            "final": "remote",
            "strategy": base["dns"].get("strategy", "ipv4_only"),
            "reverse_mapping": True,
        },
        "inbounds": [{
            "type": "tun",
            "tag": "tun-in",
            # The host's own choice, an IPv6 address included only where it kept one
            "address": base["inbounds"][0]["address"],
            "auto_route": True,
            "strict_route": True,
            "stack": "mixed",
            "route_exclude_address": PRIVATE,
        }],
        "outbounds": [
            {
                "type": "selector",
                "tag": "proxy",
                "outbounds": exits,
                "default": active if active in names else names[0],
            },
            *nodes,
            {"type": "direct", "tag": "direct"},
        ],
        # The rule-sets come through the node: a direct download from raw.github is
        # what gets slowed or cut where the node is needed in the first place
        "http_clients": [{"tag": "through-proxy", "detour": "proxy"}],
        "route": {
            "auto_detect_interface": True,
            "default_domain_resolver": "local",
            "rules": route_rules,
            "rule_set": list(rule_sets.values()),
            "final": "proxy",
        },
        # A remote rule-set the phone cannot fetch at start stops sing-box altogether;
        # the cache is what lets a later start go on without the network
        "experimental": {"cache_file": {"enabled": True}},
    }
    if guarded:
        # No controller to listen on: the mode is what SFA switches, and the cache keeps
        # the choice across restarts
        config["experimental"]["clash_api"] = {"default_mode": "Rule"}
    if tailscale:
        # sing-box keeps the node's key in its own default state directory, which a
        # re-imported config reuses: the phone stays the same tailnet node
        config["endpoints"] = [{"type": "tailscale", "tag": "tailnet"}]
    return config


def cmd_export(args):
    """The config a profile runs with here, merged by sing-box itself — or, with --sfa,
    a whole config for a phone. Root: the profiles carry the nodes' credentials."""
    need_root()
    sfa, args = take_flag(args, "--sfa")
    no_tailscale, args = take_flag(args, "--no-tailscale")
    tor, args = take_flag(args, "--tor")
    if (no_tailscale or tor) and not sfa:
        die("--no-tailscale and --tor go with --sfa")
    if sfa:
        names = [slug(arg) for arg in args] or node_names()
        if not names:
            die("no profiles")
        for name in names:
            if name == TOR_NAME:
                die(f"{TOR_NAME} is this host's own Tor — `--tor` gives the phone Orbot instead")
            if not profile_path(name).exists():
                die(f"no such profile: {name}")
        base = load_base()
        # The host keeps the tailnet out of its TUN exactly when it runs Tailscale
        tailscale = not no_tailscale and set(policy()["tailnet"]) <= set(
            base["inbounds"][0].get("route_exclude_address", [])
        )
        print(json.dumps(sfa_config(names, running(), tailscale, tor), indent=2))
        return
    if len(args) > 1:
        die("usage: skvpn export [<name>] | export --sfa [--no-tailscale] [--tor] [<name>…]")
    name = slug(args[0]) if args else running()
    if name is None:
        die("nothing is up — name the profile to export")
    if not profile_path(name).exists():
        die(f"no such profile: {name}")
    with tempfile.TemporaryDirectory(prefix="skvpn-export-") as tmp:
        out = Path(tmp) / "config.json"
        result = subprocess.run(
            [sing_box_binary(), "merge", str(out), "-C", str(BASE_D), "-c", str(profile_path(name))],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            die(result.stderr.strip() or "sing-box merge failed")
        print(out.read_text().rstrip())


def shipped(name):
    """A data file of the repository: beside the script in a checkout, under share/ once
    installed (install.sh and the Nix package both put it there); None when absent."""
    here = Path(__file__).resolve().parent
    for candidate in (here / name, here.parent / "share/skvpn" / name):
        if candidate.is_file():
            return candidate
    return None


def policy():
    """Presets, the tailnet and where the rule-sets come from — the file the NixOS
    module and the installer's renderer read too."""
    path = shipped("policy.json")
    if path is None:
        die("policy.json is missing from this install")
    return json.loads(path.read_text())


def version():
    path = shipped("VERSION")
    return path.read_text().strip() if path else "unknown"


COMMANDS = {
    "sub": cmd_sub,
    "add": cmd_add,
    "rm": cmd_rm,
    "ls": cmd_ls,
    "up": cmd_up,
    "down": cmd_down,
    "restart": cmd_restart,
    "restore": cmd_restore,
    "boot": cmd_boot,
    "split": cmd_split,
    "ping": cmd_ping,
    "measure": cmd_measure,
    "top": cmd_top,
    "status": cmd_status,
    "export": cmd_export,
    "tor": cmd_tor,
}


def main():
    if len(sys.argv) >= 2 and sys.argv[1] in ("-v", "--version"):
        print(f"skvpn {version()}")
        return
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die(f"usage: skvpn {{{'|'.join(COMMANDS)}}} … | --version")
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
