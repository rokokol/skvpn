#!/usr/bin/env bash
# Runtime proof for the NixOS Docker policy: a bridge created after the TUN starts must
# still reach the internet through the nftables br-* bypass.
set -euo pipefail

[[ $EUID == 0 ]] || {
  echo "docker-routing: run as root" >&2
  exit 1
}
: "${SING_BOX:?set SING_BOX to the sing-box binary}"
: "${NFT:?set NFT to the nft binary}"

network="skvpn-routing-test-$$"
tmp=$(mktemp -d)
sing_box_pid=""

cleanup() {
  docker rm -f "$network-container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  if [[ -n "$sing_box_pid" ]]; then
    kill "$sing_box_pid" >/dev/null 2>&1 || true
    wait "$sing_box_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Image acquisition is not what this test isolates: the TUN's final outbound below is
# deliberately blocked so only traffic arriving from the dynamic bridge can succeed.
docker pull -q ubuntu:latest >/dev/null || docker pull -q ubuntu:latest >/dev/null

cat >"$tmp/config.json" <<'EOF'
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "tun",
    "tag": "tun-in",
    "interface_name": "skvpn-ci-tun",
    "address": ["172.30.255.1/30"],
    "auto_route": true,
    "auto_redirect": true,
    "strict_route": false,
    "stack": "system",
    "route_exclude_address": ["10.250.0.0/16"],
    "exclude_interface": ["docker0"]
  }],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "proxy" }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      { "port": 53, "outbound": "direct" }
    ],
    "final": "proxy"
  }
}
EOF

"$SING_BOX" check -c "$tmp/config.json"
"$SING_BOX" run -c "$tmp/config.json" >"$tmp/sing-box.log" 2>&1 &
sing_box_pid=$!

for _ in {1..50}; do
  [[ -e /sys/class/net/skvpn-ci-tun ]] && break
  kill -0 "$sing_box_pid" 2>/dev/null || {
    cat "$tmp/sing-box.log" >&2
    exit 1
  }
  sleep 0.1
done
[[ -e /sys/class/net/skvpn-ci-tun ]] || {
  echo "docker-routing: TUN did not appear" >&2
  exit 1
}

cat >"$tmp/docker-bypass.nft" <<'EOF'
insert rule inet sing-box prerouting iifname "br-*" return comment "skvpn: bypass Docker bridges"
insert rule inet sing-box prerouting_udp_icmp iifname "br-*" return comment "skvpn: bypass Docker bridges"
EOF
"$NFT" -f "$tmp/docker-bypass.nft"

# Created after sing-box starts: no static interface-name list can know this br-* name.
docker network create --subnet 10.250.1.0/24 "$network" >/dev/null

docker run --name "$network-container" --network "$network" ubuntu:latest bash -euc '
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
