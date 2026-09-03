#!/usr/bin/env bash
# Distro tests for skvpn: run install.sh for real, as root, inside a container of an
# actual distribution — the one thing tests/run.sh cannot do. There the installer writes
# a scratch SYSCONFDIR with systemd stubbed; here it writes a real /etc, with the real
# package manager having put the real dependencies there, by running the very commands
# the preflight printed when it refused. Each outer container also starts its own dockerd
# and proves an inner Ubuntu container can use its repositories while the TUN is active.
#
#   tests/distro.sh              every distribution below
#   tests/distro.sh debian       just one
#
# Needs docker or podman. In CI this runs on push to master, weekly, and by hand — never
# on pull requests: a flaky mirror must not redden someone's change. Images are :latest
# on purpose — the weekly run is the upstream-drift detector, so no assertion may depend
# on what an image happens to carry already
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$HERE")

declare -A IMAGE=(
  [debian]=docker.io/library/debian:latest
  [ubuntu]=docker.io/library/ubuntu:latest
  [arch]=docker.io/library/archlinux:latest
  [fedora]=docker.io/library/fedora:latest
)

# Containers have no PID-1 systemd; --no-systemd is a real install that skips the live
# systemctl calls, which is exactly what it exists for. The split entries are the
# declared layer of the split test below: curl goes direct by process name, and the
# path wildcard and the CIDR are there for the installed sing-box to accept — a field
# the distribution's build does not know would refuse the whole base
INSTALL_FLAGS=(--no-systemd --docker --split curl --split path '/opt/*/bin/tor' --split ip 10.99.0.0/16 --split domain https://ubuntu.com/)
UNINSTALL_FLAGS=(--no-systemd)

# Bootstrap: only what the harness itself needs in a minimal image — never a dependency
# the preflight's guidance is supposed to provide, or the guidance test would pass
# because the answer was planted. Two kinds live here: the package manager's own
# prerequisite (Arch's sync database — the printed pacman -S cannot work against an
# empty one, and no reader of a refusal is ever told to type the refresh), and the
# platform baseline — skvpn is a tool for systemd Linux, every real host has
# systemd-sysusers for the sing-box package's postinst, and these images do not
declare -A BOOTSTRAP=(
  [debian]='apt-get update -qq && apt-get install -y -qq systemd'
  [ubuntu]='apt-get update -qq && apt-get install -y -qq systemd'
  [arch]='pacman -Sy --noconfirm'
  [fedora]='dnf install -y -q systemd'
)

# Test-harness dependency only. install.sh never installs Docker and does not require it;
# these commands equip each disposable outer container to run the DinD smoke test below.
declare -A DIND_INSTALL=(
  [debian]='apt-get install -y -qq docker.io'
  [ubuntu]='apt-get install -y -qq docker.io'
  [arch]='pacman -S --noconfirm docker'
  [fedora]='dnf install -y -q moby-engine'
)

smoke() { # runs inside the container after a successful install
  local prefix="$1" out
  out=$("$prefix/bin/skvpn" 2>&1 || true)
  grep -qF 'usage: skvpn' <<<"$out"
  "$prefix/bin/skvpn" --version | grep -qxF "skvpn $(cat VERSION)"
  # No jq in these images; python3 is a preflight dependency, so it is what reads JSON
  python3 - <<'EOF'
import json
base = json.load(open("/etc/sing-box/base.d/00-base.json"))
rules = base["route"]["rules"]
assert {"process_name": ["curl"], "outbound": "direct"} in rules, rules
assert {"process_path_regex": ["^/opt/[^/]*/bin/tor$"], "outbound": "direct"} in rules, rules
assert {"ip_cidr": ["10.99.0.0/16"], "outbound": "direct"} in rules, rules
assert {"domain_suffix": ["ubuntu.com"], "outbound": "direct"} in rules, rules
assert {"process_name": ["curl"], "server": "bootstrap"} in base["dns"]["rules"]
assert {"domain_suffix": ["ubuntu.com"], "server": "bootstrap"} in base["dns"]["rules"]
EOF
  # The declared list is what `split ls` reads back, marked as not its own
  "$prefix/bin/skvpn" split ls | grep -qE '^  name +curl +declared$'
  "$prefix/bin/skvpn" split ls | grep -qE '^  path +/opt/\*/bin/tor +declared$'
  "$prefix/bin/skvpn" split ls | grep -qE '^  domain +ubuntu\.com +declared$'
  test -f /etc/systemd/system/sing-box@.service.d/skvpn.conf
}

# The imperative layer, written before the fixture sing-box starts so it reads the file
# like a restarted instance would; the merge itself is the real -C, checked by the real
# sing-box below. python3 by resolved path — the wildcard form, so that field is on the
# wire too — while bash stays unlisted as the control
split_setup() {
  local prefix="$1" python_dir python_bin out
  python_bin=$(readlink -f "$(command -v python3)")
  python_dir=$(dirname "$python_bin")
  out=$("$prefix/bin/skvpn" split add path "$python_dir/python3*")
  grep -qF 'takes effect on the next' <<<"$out"
  test -f /etc/sing-box/base.d/70-split.json
  "$prefix/bin/skvpn" split ls | grep -qF "  path  $python_dir/python3*"
}

# With the proxy outbound blocking, the only way out is a split rule. curl carries the
# declared name rule, python3 the imperative path rule, and bash — unlisted — proves
# the domain rule: the same request gets an answer from archive.ubuntu.com, a split
# domain, and none from 1.1.1.1 by address, or the rest passed for the wrong reason.
# Connecting is not the test: auto_redirect has the kernel accept the connection for
# sing-box before any rule runs, and the block only closes it afterwards — so the
# control asks for a response line
split_smoke() {
  timeout 30 curl -fsSI http://archive.ubuntu.com/ >/dev/null ||
    timeout 30 curl -fsSI http://archive.ubuntu.com/ >/dev/null
  timeout 30 python3 -c 'import urllib.request; urllib.request.urlopen("http://archive.ubuntu.com/", timeout=20).read(1)'
  # shellcheck disable=SC2016 # the inner bash expands $line, this one must not
  bash_head() {
    timeout 15 bash -c '
      exec 3<>"/dev/tcp/$1/80" || exit 1
      printf "HEAD / HTTP/1.0\r\nHost: %s\r\n\r\n" "$1" >&3
      read -t 10 -r line <&3 && [[ -n "$line" ]]
    ' _ "$1" 2>/dev/null
  }
  bash_head archive.ubuntu.com || bash_head archive.ubuntu.com || {
    echo "  !! an unlisted process got no answer from a split domain" >&2
    return 1
  }
  if bash_head 1.1.1.1; then
    echo "  !! an unlisted process got an answer past the blocking outbound" >&2
    return 1
  fi
  # The same split domain with a request the sniffer cannot read — no Host, no TLS, the
  # shape of a game or any binary protocol. The connection carries no name, so only the
  # reverse mapping of the DNS answer can match it to the domain rule; the server's
  # 400 is the proof it got out
  # shellcheck disable=SC2016
  bash_blind() {
    timeout 15 bash -c '
      exec 3<>"/dev/tcp/$1/80" || exit 1
      printf "NOTHTTP\r\n\r\n" >&3
      read -t 10 -r line <&3 && [[ -n "$line" ]]
    ' _ "$1" 2>/dev/null
  }
  bash_blind archive.ubuntu.com || bash_blind archive.ubuntu.com || {
    echo "  !! a nameless connection to a split domain got no answer — reverse mapping is off" >&2
    return 1
  }
}

# The probe sing-box runs while the blocking TUN is up: DIRECT answers in milliseconds
# only if the probe's mark takes its sockets past the redirect the way sing-box's own
# go — inside the tunnel it would be blocked like everything else. BLOCK is the profile
# that can never answer, and the distribution's sing-box has to carry the Clash API for
# any of this to start
ping_smoke() {
  local prefix="$1" out
  install -m 640 -g sing-box /dev/stdin /etc/sing-box/profiles/DIRECT.json <<'EOF'
{"outbounds":[{"type":"direct","tag":"proxy"}]}
EOF
  install -m 640 -g sing-box /dev/stdin /etc/sing-box/profiles/BLOCK.json <<'EOF'
{"outbounds":[{"type":"block","tag":"proxy"}]}
EOF
  "$prefix/bin/skvpn" ping set https://archive.ubuntu.com/ | grep -qF 'stored'
  out=$("$prefix/bin/skvpn" ping 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  printf '%s\n' "$out"
  grep -qE '^   DIRECT .* [0-9]+ ms$' <<<"$out" || return 1
  grep -qE '^   BLOCK .* (unreachable|timeout)$' <<<"$out" || return 1
  rm -f /etc/sing-box/profiles/DIRECT.json /etc/sing-box/profiles/BLOCK.json
}

dind_smoke() {
  local prefix="$1"
  local docker_host="unix:///run/skvpn-dind.sock"
  local dockerd_pid="" sing_box_pid=""
  local -a firewall_backend=()

  dind_cleanup() {
    local pid
    for pid in "$sing_box_pid" "$dockerd_pid"; do
      [[ -n "$pid" ]] || continue
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }
  trap dind_cleanup RETURN

  if dockerd --help 2>&1 | grep -q -- '--firewall-backend'; then
    firewall_backend=(--firewall-backend=nftables)
  fi

  dockerd \
    --host "$docker_host" \
    --data-root /var/lib/skvpn-dind \
    --exec-root /run/skvpn-dind \
    --pidfile /run/skvpn-dind.pid \
    --storage-driver vfs \
    "${firewall_backend[@]}" \
    --bip 10.250.0.1/24 \
    --default-address-pool base=10.250.0.0/16,size=24 \
    >/tmp/skvpn-dockerd.log 2>&1 &
  dockerd_pid=$!

  for _ in {1..100}; do
    DOCKER_HOST=$docker_host docker info >/dev/null 2>&1 && break
    kill -0 "$dockerd_pid" 2>/dev/null || {
      cat /tmp/skvpn-dockerd.log >&2
      return 1
    }
    sleep 0.1
  done
  DOCKER_HOST=$docker_host docker info >/dev/null
  DOCKER_HOST=$docker_host docker pull -q ubuntu:latest >/dev/null ||
    DOCKER_HOST=$docker_host docker pull -q ubuntu:latest >/dev/null

  cat >/tmp/skvpn-block-profile.json <<'EOF'
{"outbounds":[{"type":"block","tag":"proxy"}]}
EOF
  split_setup "$prefix"
  # The real merge of base, extra and the imperative split file, judged by the real
  # sing-box — a field its build does not know refuses the lot right here
  sing-box check -C /etc/sing-box/base.d -c /tmp/skvpn-block-profile.json
  # As the unit would run it: the service user with the unit's capabilities, not root.
  # Process rules live or die on CAP_SYS_PTRACE and CAP_DAC_READ_SEARCH — a fixture run
  # as root would match processes the unit never could, and pass for the wrong reason
  local caps=+net_admin,+net_raw,+net_bind_service,+sys_ptrace,+dac_read_search
  install -d -o sing-box -g sing-box /tmp/skvpn-sing-box
  chmod 644 /tmp/skvpn-block-profile.json
  setpriv --reuid=sing-box --regid=sing-box --init-groups \
    --inh-caps="$caps" --ambient-caps="$caps" \
    sing-box -D /tmp/skvpn-sing-box -C /etc/sing-box/base.d \
    -c /tmp/skvpn-block-profile.json run >/tmp/skvpn-sing-box.log 2>&1 &
  sing_box_pid=$!

  for _ in {1..50}; do
    [[ -e /sys/class/net/skvpn-tun ]] && break
    kill -0 "$sing_box_pid" 2>/dev/null || {
      cat /tmp/skvpn-sing-box.log >&2
      return 1
    }
    sleep 0.1
  done
  [[ -e /sys/class/net/skvpn-tun ]] || return 1

  DOCKER_HOST=$docker_host docker run --rm --dns 1.1.1.1 ubuntu:latest bash -euc '
    for attempt in 1 2; do
      rm -rf /var/lib/apt/lists/* /tmp/ca-certificates_*.deb
      if apt-get update && cd /tmp && apt-get download ca-certificates &&
        compgen -G "ca-certificates_*.deb" >/dev/null; then
        exit 0
      fi
      sleep 3
    done
    exit 1
  '

  say "split entries leave past the blocking TUN, an unlisted process does not"
  split_smoke

  say "skvpn ping measures outside the active TUN, through the distribution's sing-box"
  ping_smoke "$prefix"

  dind_cleanup
  trap - RETURN
}

# ======================================================================================
# host half: find an engine, pull fresh, re-execute this script inside the container
# ======================================================================================

if [[ "${1:-}" != "--inside" ]]; then
  engine=""
  for candidate in "${CONTAINER_ENGINE:-}" docker podman; do
    [[ -n "$candidate" ]] || continue
    if command -v "$candidate" >/dev/null && "$candidate" info >/dev/null 2>&1; then
      engine="$candidate"
      break
    fi
  done
  if [[ -z "$engine" ]]; then
    echo "tests/distro.sh: needs a working docker or podman" >&2
    exit 1
  fi

  wanted=("$@")
  ((${#wanted[@]})) || wanted=(debian ubuntu arch fedora)

  fails=0
  for distro in "${wanted[@]}"; do
    image="${IMAGE[$distro]:-}"
    if [[ -z "$image" ]]; then
      echo "tests/distro.sh: no such distribution: $distro" >&2
      exit 1
    fi
    printf '\n== %s (%s)\n' "$distro" "$image"
    # One retry on the pull: a mirror hiccup is not a verdict on anything
    "$engine" pull -q "$image" >/dev/null || "$engine" pull -q "$image" >/dev/null
    # The checkout goes in read-only — the run must not be able to edit it. The resolver
    # is named because the engine would otherwise copy the observer's: a developer's host
    # running skvpn lists its own TUN's DNS there, and inside the container that address
    # is the fixture's blocking TUN — every direct lookup would sink into it
    if ! "$engine" run --rm --privileged --dns 1.1.1.1 -v "$REPO:/src:ro" "$image" \
      bash /src/tests/distro.sh --inside "$distro"; then
      printf '  %s: FAILED\n' "$distro"
      fails=$((fails + 1))
    else
      printf '  %s: passed\n' "$distro"
    fi
  done
  ((fails)) && exit 1
  echo
  echo "all distributions passed"
  exit 0
fi

# ======================================================================================
# container half
# ======================================================================================

distro="$2"

say() { printf '\n  -- %s\n' "$1"; }
die() {
  printf '  !! %s\n' "$1" >&2
  exit 1
}

say "bootstrap ($distro)"
bash -c "${BOOTSTRAP[$distro]}" >/dev/null

# The checkout is mounted read-only; work on a copy a package manager cannot be blamed for
cp -r /src /work
cd /work

prefix=/usr/local
bin_path="$prefix/bin/skvpn"
share_dir="$prefix/share/skvpn"

say "a relative PREFIX is rejected"
! PREFIX=usr ./install.sh "${INSTALL_FLAGS[@]}" >/dev/null 2>&1 ||
  die "install.sh accepted a relative PREFIX"

say "install, running the printed guidance when the preflight refuses"
rc=0
out=$(./install.sh "${INSTALL_FLAGS[@]}" 2>&1) || rc=$?
if ((rc != 0)); then
  # The refusal must be complete and clean: name what is missing, write nothing
  printf '%s\n' "$out" | grep -q 'missing dependencies' ||
    die "the refusal did not say what is missing: $out"
  [[ ! -e "$bin_path" && ! -e "$share_dir" && ! -e /etc/sing-box ]] ||
    die "a refused install left files behind"
  printf '%s\n' "$out" | grep -qE 'command not found|: line [0-9]' &&
    die "the preflight listed what is missing and then carried on: $out"

  # Runnable guidance lines are `  $ command`; they are run exactly as printed.
  # Non-interactivity is arranged around the command — DEBIAN_FRONTEND, yes on stdin —
  # never inside it: the printed line has no -y because a human reads it
  commands=$(printf '%s\n' "$out" | sed -n 's/^  \$ //p')
  if [[ -z "$commands" ]]; then
    echo "::notice title=skvpn distro test::SKIP on $distro — guidance is manual-only"
    printf '  SKIP: no runnable guidance on %s\n' "$distro"
    exit 0
  fi
  # The container is root and none of these images ships sudo. Answered with a shim, not
  # by editing the line: a sudo can sit mid-pipeline (| sudo tee) where stripping a
  # prefix cannot reach, and an edited line is no longer the line the reader was given
  if ! command -v sudo >/dev/null; then
    printf '#!/bin/sh\nexec "$@"\n' >/usr/local/bin/sudo
    chmod +x /usr/local/bin/sudo
  fi
  export DEBIAN_FRONTEND=noninteractive
  while IFS= read -r cmd; do
    printf '  running printed guidance: %s\n' "$cmd"
    # yes answers "y" to [Y/n]-style prompts; dnf treats an empty answer as No. Fed by
    # process substitution, not a pipe: pipefail would turn yes's own SIGPIPE death —
    # normal for a command that never reads stdin — into a failed pipeline
    bash -c "$cmd" < <(yes 2>/dev/null) || die "printed guidance failed: $cmd"
  done <<<"$commands"

  say "install succeeds once the guidance has been followed"
  ./install.sh "${INSTALL_FLAGS[@]}" || die "install failed after following the guidance"
else
  echo "  (every dependency was already present — the refusal path ran elsewhere)"
fi

say "the installed tool answers"
[[ -e "$bin_path" ]] || die "no $bin_path after install"
[[ -f "$share_dir/install-manifest" ]] || die "no install-manifest after install"
version_out=$("$bin_path" --version)
[[ "$version_out" == "skvpn $(cat VERSION)" ]] ||
  die "--version does not match VERSION: $version_out"
./install.sh --help >/dev/null || die "--help failed"
smoke "$prefix" || die "smoke test failed"

say "Docker-in-Docker reaches Ubuntu repositories through the active TUN"
bash -c "${DIND_INSTALL[$distro]}" >/dev/null
dind_smoke "$prefix"

say "uninstall removes exactly what the manifest names"
mapfile -t manifest_paths < <(grep -v '^#' "$share_dir/install-manifest")
./install.sh --uninstall "${UNINSTALL_FLAGS[@]}" || die "--uninstall failed"
for path in "${manifest_paths[@]}"; do
  [[ ! -e "$path" && ! -L "$path" ]] || die "uninstall left $path behind"
done
[[ ! -e "$share_dir" ]] || die "uninstall left $share_dir behind"
# State outlives the install, like the profiles and the subscription
[[ -f /etc/sing-box/base.d/70-split.json ]] || die "uninstall took the imperative split list with it"

say "a second uninstall is quiet and succeeds"
./install.sh --uninstall "${UNINSTALL_FLAGS[@]}" >/dev/null || die "uninstall is not idempotent"

echo
echo "  $distro: full cycle passed"
