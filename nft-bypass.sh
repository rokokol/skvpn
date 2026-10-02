#!/usr/bin/env bash
# Needs bash 3.2 and POSIX tools only
#
# Runs as the unit's ExecStartPost (NixOS postStart, the installer's drop-in), under the
# unit's user with CAP_NET_ADMIN. The chain names are sing-tun's own auto_redirect table;
# a sing-box that renames them fails the wait below rather than inserting nowhere.
# WORKAROUNDS.md has the mechanism behind the rules and how to tell when they can go:
# "auto_redirect marks tailscaled's packets into the TUN" and "Replies to inbound UDP
# leave through the TUN"
set -euo pipefail

usage() {
  cat <<'EOF'
nft-bypass.sh — let traffic that must keep its own path past skvpn's TUN

  nft-bypass.sh apply [--tailscale] [--docker] [--syncthing]

Waits for sing-box's `inet sing-box` table, then inserts return rules into it.
Always: replies to inbound UDP leave by the host's routes, not through the TUN.

  --tailscale   packets tailscaled marks for its own bypass (0x80000) skip the TUN
  --docker      traffic from dynamically named br-* Docker bridges skips the TUN
  --syncthing   UDP from Syncthing's default listening port, 22000, skips the TUN,
                so its QUIC keeps the source port peers know it by

Environment: NFT is the nft binary (default: nft from PATH)
Nothing here reaches the network
Exit 0 done, 1 when the table never appeared or nft refused a rule, 2 on a usage error
EOF
}

fail() { # the thing asked about is wrong
  printf 'nft-bypass.sh: %s\n' "$1" >&2
  exit 1
}

die() { # the request itself is wrong
  printf 'nft-bypass.sh: %s\n' "$1" >&2
  exit 2
}

NFT="${NFT:-nft}"
TABLE="inet sing-box"

# sing-box creates the table a moment after the unit counts as started; five seconds
wait_for_chains() {
  local chain tick missing
  for ((tick = 0; tick < 50; tick++)); do
    missing=0
    for chain in "$@"; do
      "$NFT" list chain inet sing-box "$chain" >/dev/null 2>&1 || {
        missing=1
        break
      }
    done
    ((missing)) || return 0
    sleep 0.1
  done
  fail "sing-box never created chains $* in $TABLE"
}

cmd_apply() {
  local tailscale=0 docker=0 syncthing=0 rules chain
  while (($#)); do
    case "$1" in
      --tailscale)
        tailscale=1
        shift
        ;;
      --docker)
        docker=1
        shift
        ;;
      --syncthing)
        syncthing=1
        shift
        ;;
      *) die "no such flag: $1" ;;
    esac
  done

  # output_udp_icmp is the chain that marks UDP for the TUN without asking whether the
  # packet answers a connection that arrived from outside
  rules="insert rule $TABLE output_udp_icmp ct direction reply return comment \"skvpn: replies to inbound UDP\""
  if ((tailscale)); then
    # All three output chains: prematch would hand the packet to sing-box, the nat chain
    # would redirect tailscaled's TCP to DERP, and the route chain would overwrite the mark
    for chain in output_prematch output output_udp_icmp; do
      rules+=$'\n'"insert rule $TABLE $chain meta mark & 0x00ff0000 == 0x00080000 return comment \"skvpn: bypass Tailscale\""
    done
  fi
  if ((syncthing)); then
    for chain in output_prematch output_udp_icmp; do
      rules+=$'\n'"insert rule $TABLE $chain udp sport 22000 return comment \"skvpn: bypass Syncthing\""
    done
  fi
  if ((docker)); then
    # sing-box only takes exact names in exclude_interface, and Docker names user-defined
    # bridges br-<network-id>; a wildcard here also covers bridges created later
    for chain in prerouting prerouting_udp_icmp; do
      rules+=$'\n'"insert rule $TABLE $chain iifname \"br-*\" return comment \"skvpn: bypass Docker bridges\""
    done
  fi

  wait_for_chains output_prematch output output_udp_icmp prerouting prerouting_udp_icmp
  printf '%s\n' "$rules" | "$NFT" -f - || fail "nft refused the bypass rules"
}

cmd="${1:-}"
(($# == 0)) || shift
case "$cmd" in
  apply) cmd_apply "$@" ;;
  -h | --help | help) usage ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    printf 'nft-bypass.sh: no such subcommand: %s\n\n' "$cmd" >&2
    usage >&2
    exit 2
    ;;
esac
