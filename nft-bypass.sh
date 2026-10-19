#!/usr/bin/env bash
# Needs bash 3.2 and POSIX tools only
#
# apply runs as the unit's ExecStartPost (NixOS postStart, the installer's drop-in), under
# the unit's user with CAP_NET_ADMIN. The chain names are sing-tun's own auto_redirect
# table; a sing-box that renames them fails the wait below rather than inserting nowhere.
# WORKAROUNDS.md has the mechanism behind the rules and how to tell when they can go:
# "auto_redirect marks tailscaled's packets into the TUN" and "Replies to inbound UDP
# leave through the TUN"
set -euo pipefail

usage() {
  cat <<'EOF'
nft-bypass.sh — let traffic that must keep its own path past skvpn's TUN, and hold the
network while no TUN carries it

  nft-bypass.sh apply   [--tailscale] [--docker] [--syncthing]
  nft-bypass.sh hold    [--if-failed] [--tailscale] [--docker] [--syncthing]
  nft-bypass.sh release [--tailscale] [--docker] [--syncthing]

apply    waits for sing-box's `inet sing-box` table, inserts return rules into it, and
         lets a hold go in the same transaction. Always: replies to inbound UDP leave by
         the host's routes, not through the TUN
hold     makes the `inet skvpn-hold` table: this host's outgoing traffic is refused,
         except what never enters the TUN or leaves it direct anyway — loopback, replies
         to inbound connections, DHCP, private and link-local addresses, and what the
         flags below let past the TUN
release  removes the hold; nothing to remove is not an error

  --tailscale   packets tailscaled marks for its own bypass (0x80000) skip the TUN;
                a hold also lets traffic out through tailscale0
  --docker      traffic from dynamically named br-* Docker bridges skips the TUN; a hold
                covers this host's own traffic only, so it has nothing to add
  --syncthing   UDP from Syncthing's default listening port, 22000, skips the TUN,
                so its QUIC keeps the source port peers know it by
  --if-failed   hold only when systemd's SERVICE_RESULT is not "success": a unit that
                failed holds, one stopped on purpose does not. Without SERVICE_RESULT
                the hold is made

Every subcommand takes the same flags, so one flag set serves all of them

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
HOLD="inet skvpn-hold"
# Adding first makes the delete safe on a table that is not there, in one transaction;
# `destroy` would say it in one word but needs nftables 1.0.8
DROP_HOLD="add table $HOLD
delete table $HOLD"

tailscale=0
docker=0
syncthing=0
if_failed=0
parse_flags() {
  while (($#)); do
    case "$1" in
      --tailscale) tailscale=1 ;;
      --docker) docker=1 ;;
      --syncthing) syncthing=1 ;;
      --if-failed) if_failed=1 ;;
      *) die "no such flag: $1" ;;
    esac
    shift
  done
}

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
  local rules chain
  ((! if_failed)) || die "--if-failed is a flag of hold"

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
  # The TUN is ready once its rules are in, so the hold goes with them, never before
  printf '%s\n%s\n' "$rules" "$DROP_HOLD" | "$NFT" -f - || fail "nft refused the bypass rules"
}

# Only this host's output: sing-box carries forwarded traffic too, but a hold is for the
# clients on the host. The private ranges are those sing-box's ip_is_private routes direct
# (netip's IsPrivate, IsLoopback, IsMulticast, IsLinkLocalUnicast), plus the broadcast
# address. A reject rather than a drop, so a client fails at once instead of timing out
cmd_hold() {
  local rules
  if ((if_failed)) && [[ "${SERVICE_RESULT:-}" == success ]]; then
    return 0
  fi
  rules="table $HOLD {
  chain output {
    type filter hook output priority 0; policy accept;
    oifname \"lo\" accept
    ct direction reply accept
    udp sport 68 udp dport 67 accept
    udp sport 546 udp dport 547 accept
    ip daddr { 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } accept
    ip6 daddr { ::1, fc00::/7, fe80::/10, ff00::/8 } accept"
  if ((tailscale)); then
    rules+=$'\n'"    meta mark & 0x00ff0000 == 0x00080000 accept"
    rules+=$'\n'"    oifname \"tailscale0\" accept"
  fi
  if ((syncthing)); then
    rules+=$'\n'"    udp sport 22000 accept"
  fi
  rules+="
    meta l4proto tcp counter reject with tcp reset
    counter reject with icmpx admin-prohibited
  }
}"
  # Replaced whole in one transaction: a second hold never leaves a moment without one
  printf '%s\n%s\n' "$DROP_HOLD" "$rules" | "$NFT" -f - || fail "nft refused the hold"
}

cmd_release() {
  ((! if_failed)) || die "--if-failed is a flag of hold"
  printf '%s\n' "$DROP_HOLD" | "$NFT" -f - || fail "nft could not remove the hold"
}

cmd="${1:-}"
(($# == 0)) || shift
case "$cmd" in
  apply | hold | release) parse_flags "$@" ;;
esac
case "$cmd" in
  apply) cmd_apply ;;
  hold) cmd_hold ;;
  release) cmd_release ;;
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
