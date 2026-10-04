#!/usr/bin/env bash
# Runtime proof for the Tailscale bypass: a packet tailscaled marks for its own bypass
# leaves past the TUN, except to an address named by --tailscale-via-tunnel, which the
# real sing-box must see. Runs in a network namespace of its own, so it needs no root
# and leaves the host's routes alone.
set -euo pipefail

: "${SING_BOX:?set SING_BOX to the sing-box binary}"
: "${NFT:?set NFT to the nft binary}"

if [[ "${1:-}" != --inside ]]; then
  exec unshare --map-root-user --net --mount bash "$0" --inside
fi

# A network namespace hides the host's network but not its files: on a TUN start
# sing-box asks systemd-resolved over the system bus to set the link's DNS, and on a
# desktop polkit answers that with a password prompt per run. An empty directory over
# the bus socket, in this mount namespace only, keeps the test to itself
if [[ -d /run/dbus ]]; then
  mount -t tmpfs none /run/dbus
fi

tmp=$(mktemp -d)
sing_box_pid=""
stop_sing_box() {
  if [[ -n "$sing_box_pid" ]]; then
    kill "$sing_box_pid" >/dev/null 2>&1 || true
    wait "$sing_box_pid" >/dev/null 2>&1 || true
    sing_box_pid=""
  fi
  # The next sing-box must find neither this one's table, which would take the rules,
  # nor its interface, whose name it could not open again
  for _ in {1..50}; do
    if ! "$NFT" list table inet sing-box >/dev/null 2>&1 &&
      [[ ! -e /sys/class/net/skvpn-ts-tun ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "tailscale-routing: the stopped sing-box left its table or interface behind" >&2
  exit 1
}
cleanup() {
  stop_sing_box
  rm -rf "$tmp"
}
trap cleanup EXIT

# A physical-looking uplink with a default route in both families, as auto_route expects
ip link set lo up
ip link add uplink type dummy
ip addr add 10.9.0.2/24 dev uplink
ip addr add 2001:db8:9::2/64 dev uplink nodad
ip link set uplink up
ip route add default via 10.9.0.1
ip -6 route add default via 2001:db8:9::1

cat >"$tmp/config.json" <<'EOF'
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "tun",
    "tag": "tun-in",
    "interface_name": "skvpn-ts-tun",
    "address": ["172.30.255.1/30", "fdfe:dcba:9876::1/126"],
    "auto_route": true,
    "auto_redirect": true,
    "strict_route": false,
    "stack": "system"
  }],
  "outbounds": [{ "type": "block", "tag": "proxy" }],
  "route": { "final": "proxy" }
}
EOF
"$SING_BOX" check -c "$tmp/config.json"

# A fresh sing-box per scenario: it drops its table on exit, and the rules of one
# scenario must not answer for the next
start_sing_box() {
  "$SING_BOX" run -c "$tmp/config.json" >"$tmp/sing-box.log" 2>&1 &
  sing_box_pid=$!
  for _ in {1..50}; do
    "$NFT" list chain inet sing-box output_udp_icmp >/dev/null 2>&1 && return 0
    kill -0 "$sing_box_pid" 2>/dev/null || break
    sleep 0.1
  done
  cat "$tmp/sing-box.log" >&2
  exit 1
}

# 0x80000 is tailscaled's bypass mark; SO_MARK is 36 in SOL_SOCKET
send() { # MARK ADDRESS
  python3 - "$@" <<'EOF'
import socket
import sys

mark, address = int(sys.argv[1], 0), sys.argv[2]
family = socket.AF_INET6 if ":" in address else socket.AF_INET
with socket.socket(family, socket.SOCK_DGRAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, 36, mark)
    sock.sendto(b"probe", (address, 41641))
EOF
}

reached_tun() { # ADDRESS: sing-box logged a connection to it from the TUN
  grep -qF "inbound packet connection to $1" "$tmp/sing-box.log" ||
    grep -qF "inbound packet connection to [$1]" "$tmp/sing-box.log"
}

status=0
check() { # WANT ADDRESS WHY
  local got=bypassed
  reached_tun "$2" && got=tun
  if [[ "$got" == "$1" ]]; then
    echo "  ✓ $2: $got"
  else
    echo "  ✗ $2: $got, want $1 — $3"
    status=1
  fi
}

# Runs the very script the units run, with the given exit addresses, then sends
# tailscaled-marked packets to an exit and to an ordinary peer in both families
scenario() { # TITLE [EXIT_ADDRESS...]
  local title=$1 address flags=()
  shift
  for address in "$@"; do
    flags+=(--tailscale-via-tunnel "$address")
  done
  echo "$title"
  start_sing_box
  NFT="$NFT" bash "$(dirname "$0")/../nft-bypass.sh" apply --tailscale "${flags[@]}"
  for address in 192.0.2.20 2001:db8::20 192.0.2.10 2001:db8::10; do
    send 0x80000 "$address"
  done
  # Unmarked traffic always takes the TUN: the sign that the log has caught up
  send 0 192.0.2.30
  send 0 2001:db8::30
  for _ in {1..50}; do
    reached_tun 192.0.2.30 && reached_tun 2001:db8::30 && break
    sleep 0.1
  done
  check tun 192.0.2.30 "unmarked traffic missed the TUN, so nothing below is meaningful"
  check tun 2001:db8::30 "unmarked traffic missed the TUN, so nothing below is meaningful"
  check bypassed 192.0.2.20 "tailscaled's packet to an ordinary peer was pulled into the TUN"
  check bypassed 2001:db8::20 "tailscaled's packet to an ordinary peer was pulled into the TUN"
}

scenario "an exit in both families" 192.0.2.10 2001:db8::10
check tun 192.0.2.10 "tailscaled's packet to the exit kept its bypass"
check tun 2001:db8::10 "tailscaled's packet to the exit kept its bypass"
stop_sing_box

# The usual exit has only IPv4: the IPv6 side keeps the whole bypass
scenario "an exit with only an IPv4 address" 192.0.2.10
check tun 192.0.2.10 "tailscaled's packet to the exit kept its bypass"
check bypassed 2001:db8::10 "an IPv6 peer lost its bypass to an IPv4-only exit"

if ((status)); then
  "$NFT" list table inet sing-box >&2
  cat "$tmp/sing-box.log" >&2
  exit 1
fi
