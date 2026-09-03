#!/usr/bin/env python3
"""Manage sing-box profiles as systemd template instances.

A profile is one file in /etc/sing-box/profiles holding a single outbound tagged `proxy`; the
shared base comes from the NixOS module. Switching is `systemctl start sing-box@<name>`.
"""

import base64
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
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
STAMP = ROOT / "var/lib/skvpn/last-sync"
ACTIVE = ROOT / "var/lib/skvpn/active"
# A profile pinned for boot by hand; without it boot follows ACTIVE, the last `up`
BOOT = ROOT / "var/lib/skvpn/boot"
UNIT = "sing-box@{}.service"
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


def systemctl(*args):
    result = probe(*args)
    if result.returncode != 0:
        die(result.stderr.strip().splitlines()[0] if result.stderr.strip() else "systemctl failed")


def running():
    # Asked of systemd, not of the profile directory, which an unprivileged user cannot read
    result = probe("list-units", "--plain", "--no-legend", "--state=active", "sing-box@*")
    for line in result.stdout.splitlines():
        unit = line.split()[0]
        if unit.startswith("sing-box@") and unit.endswith(".service"):
            return unit.removeprefix("sing-box@").removesuffix(".service")
    return None


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


def probe_config(names, port):
    """One throwaway sing-box: every asked profile as an outbound tagged with its name,
    no inbounds, the Clash API on loopback to ask for delays."""
    outbounds = []
    for name in names:
        node = read_profile(name)
        if node is None:
            die(f"broken profile: {name}")
        outbounds.append({**node, "tag": name})
    return {
        "log": {"level": "error"},
        # The system resolver, as the base's own bootstrap: it only ever resolves the
        # nodes' hostnames — the site's name travels to the node and is resolved there,
        # the way it does through the tunnel — so no resolver of the probe's own could
        # be blocked on the way. ipv4_only as in the base, and not for taste: an AAAA
        # query that never comes back holds the lookup for seconds, and the delay test's
        # budget is spent waiting on it before a single packet reaches the site
        "dns": {
            "servers": [{"tag": "bootstrap", "type": "local"}],
            "final": "bootstrap",
            "strategy": "ipv4_only",
        },
        "outbounds": outbounds,
        "route": {
            "auto_detect_interface": True,
            "default_mark": redirect_mark(),
            "default_domain_resolver": "bootstrap",
        },
        "experimental": {"clash_api": {"external_controller": f"127.0.0.1:{port}"}},
    }


def free_port():
    with socket.socket() as probe_socket:
        probe_socket.bind(("127.0.0.1", 0))
        return probe_socket.getsockname()[1]


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


def measure(names):
    """{name: delay(...)} for every name, through one probe sing-box that lives only as
    long as this call — the config carries node credentials, so it sits in a private
    directory and goes with it."""
    binary = sing_box_binary()
    url = ping_url()
    port = free_port()
    work = Path(tempfile.mkdtemp(prefix="skvpn-ping-"))
    config = work / "config.json"
    stderr_path = work / "stderr"
    proc = None
    try:
        write_private(config, json.dumps(probe_config(names, port)) + "\n", 0o600)
        # A file, not a pipe: a chatty child would fill the pipe and hang the parent
        with open(stderr_path, "w") as stderr:
            proc = subprocess.Popen(
                [binary, "-D", str(work), "-c", str(config), "run"],
                stdout=subprocess.DEVNULL,
                stderr=stderr,
            )
        wait_for_port(proc, port, stderr_path)
        with ThreadPoolExecutor(max_workers=min(16, len(names))) as pool:
            return dict(zip(names, pool.map(lambda n: delay(port, n, url), names)))
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        shutil.rmtree(work, ignore_errors=True)


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
    if len(args) != 1:
        die("usage: skvpn up <name>")
    name = slug(args[0])
    if not profile_path(name).exists():
        die(f"no such profile: {name}")
    sync(if_stale=True, fatal=False)
    # The sync may just have pruned the very profile asked for; starting it anyway would
    # fail at the unit and still be remembered as the boot choice
    if not profile_path(name).exists():
        die(f"the subscription no longer carries {name}")
    cmd_down([])
    systemctl("start", UNIT.format(name))
    # Remembered only once it is up, so a broken profile is not replayed on every boot
    ACTIVE.parent.mkdir(parents=True, exist_ok=True)
    ACTIVE.write_text(name + "\n")
    print(f"  →  {name}")


def cmd_down(_args):
    need_root()
    active = running()
    if active:
        systemctl("stop", UNIT.format(active))
        print(f"  ×  {active}")
    ACTIVE.unlink(missing_ok=True)


def cmd_restart(_args):
    """Start the active profile over on the base as it is now — the way a changed split
    list, or any other base.d edit, gets onto the wire."""
    need_root()
    active = running()
    if active is None:
        die("nothing is up — `skvpn up <name>` starts a profile")
    systemctl("restart", UNIT.format(active))
    print(f"  ↻  {active}")


def cmd_restore(_args):
    """Boot-time half of `up` — no fetching and no choosing, just the pin or what was
    last up."""
    need_root()
    name, _ = boot_choice()
    if name is None:
        return
    if not profile_path(name).exists():
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
    names = [slug(arg) for arg in args] or profile_names()
    if not names:
        die("no profiles")
    for name in names:
        if not profile_path(name).exists():
            die(f"no such profile: {name}")
    print_pings(measure(names), servers)


def cmd_status(args):
    servers, args = take_flag(args, "--servers")
    if args not in ([], ["--ping"]) or (servers and not args):
        die("usage: skvpn status [--ping [--servers]]")
    if args:
        need_root()
    active = running()
    print(f"  profile   {active or 'none'}")
    # A choice is kept either way, but with restore off it is not what boot does
    if boot_choice()[0] is not None and restore_enabled():
        print(boot_line())
    if STAMP.exists():
        age = int((time.time() - STAMP.stat().st_mtime) / 60)
        print(f"  synced    {age} min ago")
    if args and profile_names():
        print()
        print_pings(measure(profile_names()), servers)


def version():
    # Beside the script in a checkout; under share/ once installed (install.sh and the
    # Nix package both put it there)
    here = Path(__file__).resolve().parent
    for candidate in (here / "VERSION", here.parent / "share/skvpn/VERSION"):
        if candidate.is_file():
            return candidate.read_text().strip()
    return "unknown"


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
    "status": cmd_status,
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
