#!/usr/bin/env bash
# SKVPN_ROOT relocates every path the tool touches, so nothing here needs root and
# nothing can name a path outside $WORK; systemctl is stubbed, so "what is running" is
# something the suite decides rather than inherits from the machine

set -euo pipefail

usage() {
  cat <<'EOF'
tests/run.sh — the fast suite for skvpn: drives it against a scratch SKVPN_ROOT and
checks what lands on disk and what reaches systemd

  tests/run.sh            run the suite
  tests/run.sh --update   rewrite tests/golden from the current parser output

SKVPN picks the binary driven (default: skvpn.py next to tests/)

Nothing here reaches the network
Exit: 0 all passed, 1 a check failed
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]] && {
  usage
  exit 0
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$HERE")
SKVPN="${SKVPN:-$REPO/skvpn.py}"

UPDATE=0
[[ "${1:-}" == --update ]] && UPDATE=1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export PATH="$HERE/stub:$PATH"

# A stub that is not executable, or one the PATH does not reach first, silently hands the
# suite the real tool — and for systemctl that is the developer's own live units
for stub in "$HERE"/stub/*; do
  tool=$(basename "$stub")
  if [[ ! -x $stub ]]; then
    printf 'tests/stub/%s is not executable\n' "$tool" >&2
    exit 1
  fi
  if [[ "$(command -v "$tool")" != "$stub" ]]; then
    printf '%s resolves to %s, not to the stub\n' "$tool" "$(command -v "$tool")" >&2
    exit 1
  fi
done

fails=0
case_name=""

fail() {
  printf '  ✗ %s: %s\n' "$case_name" "$1"
  fails=$((fails + 1))
}

ok() {
  printf '  ✓ %s\n' "$case_name"
}

# A scratch world per case: fresh root, fresh systemctl log, nothing remembered as running
world() {
  case_name="$1"
  export SKVPN_ROOT="$WORK/$1"
  rm -rf "$SKVPN_ROOT"
  mkdir -p "$SKVPN_ROOT"
  export SYSTEMCTL_LOG="$SKVPN_ROOT/systemctl.log"
  : >"$SYSTEMCTL_LOG"
  export JOURNALCTL_LOG="$SKVPN_ROOT/journalctl.log"
  : >"$JOURNALCTL_LOG"
  # The probe sing-box that `ping` starts: where the stub keeps the config it was handed
  # and the requests it answered
  export SING_BOX_CONFIG="$SKVPN_ROOT/probe-config.json"
  export SING_BOX_LOG="$SKVPN_ROOT/sing-box.log"
  : >"$SING_BOX_LOG"
  unset FAKE_ACTIVE
  unset FAKE_ACTIVATING
  unset SYSTEMCTL_FAIL
  unset FAKE_DELAYS
  unset SING_BOX_FAIL
  unset FAKE_TOR_STATE
  unset FAKE_JOURNAL
  # What `measure` and `top` add: the curl stub's log and its answers, the UDP resolver
  # behind each exit, and the live instance's traffic stream
  export CURL_LOG="$SKVPN_ROOT/curl.log"
  : >"$CURL_LOG"
  unset FAKE_CURL
  unset FAKE_UDP
  unset FAKE_TRAFFIC
  unset FAKE_TRAFFIC_HOLD
  # A query nobody answers would hold a case for the production wait on each of them
  export SKVPN_UDP_TIMEOUT=0.3
  # An override exported in the developer's shell would reach past the stub unnoticed
  unset SKVPN_SING_BOX
}

sv() { python3 "$SKVPN" "$@"; }

profile() { printf '%s/etc/sing-box/profiles/%s.json' "$SKVPN_ROOT" "$1"; }
active_file() { printf '%s/var/lib/skvpn/active' "$SKVPN_ROOT"; }
# A Tor constant from policy.json, which the renderers and the CLI read too
tor_policy() { jq -r ".tor.$1" "$REPO/policy.json"; }

echo "parsers"

# One link per parser, every optional field on: what the golden files pin is the exact
# sing-box outbound each share link becomes
VLESS_REALITY='vless://11111111-2222-3333-4444-555555555555@node.example.com:8443?security=reality&pbk=PUBKEY&sid=abcd&fp=chrome&flow=xtls-rprx-vision&type=tcp#SE-1%20main'
VLESS_WS='vless://11111111-2222-3333-4444-555555555555@cdn.example.com:443?security=tls&sni=cdn.example.com&alpn=h2,http/1.1&type=ws&path=/ws&host=cdn.example.com#WS'
HY2='hysteria2://secret@node.example.com:443?sni=node.example.com&insecure=1&obfs=salamander&obfs-password=obfspass#HY2'
TROJAN='trojan://secret@node.example.com?sni=node.example.com&alpn=h2#TROJAN-node'

golden() {
  local name="$1" file
  file=$(profile "$name")
  if ((UPDATE)); then
    cp "$file" "$HERE/golden/$name.json"
    printf '  ~ %s updated\n' "$name"
    return
  fi
  if diff -u "$HERE/golden/$name.json" "$file"; then
    ok
  else
    fail "the parsed outbound drifted from golden"
  fi
}

world vless-reality-parses
sv add "$VLESS_REALITY" >/dev/null
golden SE-1-main

world vless-ws-parses
sv add "$VLESS_WS" >/dev/null
golden WS

world hysteria2-parses
sv add "$HY2" >/dev/null
golden HY2

world trojan-parses
sv add "$TROJAN" >/dev/null
golden TROJAN-node

world trojan-ws-parses
sv add 'trojan://secret@node.example.com:443?sni=node.example.com&type=ws&path=/ws&host=cdn.example.com#TROJAN-ws' >/dev/null
golden TROJAN-ws

world unsupported-scheme-is-skipped
out=$(sv add 'ss://something@node.example.com:443#SS' 2>&1)
if [[ "$out" == *skip* && ! -e $(profile SS) ]]; then
  ok
else
  fail "an unsupported scheme did not skip"
fi

world unsupported-transport-is-skipped
out=$(sv add 'vless://u@node.example.com:443?type=xhttp#X' 2>&1)
out2=$(sv add 'trojan://p@node.example.com:443?type=xhttp#TX' 2>&1)
if [[ "$out" == *skip* && ! -e $(profile X) && "$out2" == *skip* && ! -e $(profile TX) ]]; then
  ok
else
  fail "a transport sing-box cannot speak did not skip"
fi

world serverless-link-is-skipped-not-a-traceback
out=$(sv add 'vless://' 2>&1)
if [[ "$out" == *skip* ]]; then
  ok
else
  fail "a bare scheme crashed instead of skipping — in sync it would kill the whole run"
fi

echo "profiles"

world profile-files-keep-credentials-close
sv add "$TROJAN" >/dev/null
perms=$(stat -c %a "$(profile TROJAN-node)")
if [[ "$perms" == 640 ]]; then
  ok
else
  fail "profile file is $perms, and it holds node credentials"
fi

world ls-names-needs-no-contents
sv add "$HY2" >/dev/null
sv add "$TROJAN" >/dev/null
if [[ "$(sv ls --names)" == $'HY2\nTROJAN-node' ]]; then
  ok
else
  fail "ls --names did not list the stems sorted"
fi

world rm-deletes-and-refuses-the-running-one
sv add "$HY2" >/dev/null
sv add "$TROJAN" >/dev/null
FAKE_ACTIVE='TROJAN-node'
export FAKE_ACTIVE
if sv rm TROJAN-node >/dev/null 2>&1; then
  fail "the running profile was deleted"
elif ! sv rm HY2 >/dev/null || [[ -e $(profile HY2) ]]; then
  fail "an idle profile did not get deleted"
else
  ok
fi

world rm-clears-the-boot-choice
sv add "$HY2" >/dev/null
mkdir -p "$(dirname "$(active_file)")"
printf 'HY2\n' >"$(active_file)"
sv rm HY2 >/dev/null
if [[ ! -e $(active_file) ]]; then
  ok
else
  fail "a deleted profile is still the boot choice"
fi

echo "switching"

world up-starts-and-remembers
sv add "$HY2" >/dev/null
sv up HY2 >/dev/null
if grep -q 'start sing-box@HY2.service' "$SYSTEMCTL_LOG" &&
  [[ "$(cat "$(active_file)")" == HY2 ]]; then
  ok
else
  fail "up did not start the unit or remember the choice"
fi

world up-refuses-an-unknown-profile
if sv up nope >/dev/null 2>&1; then
  fail "starting a profile that does not exist was allowed"
else
  ok
fi

world up-stops-the-previous-profile
sv add "$HY2" >/dev/null
FAKE_ACTIVE='TROJAN-node'
export FAKE_ACTIVE
sv up HY2 >/dev/null
if grep -q 'stop sing-box@TROJAN-node.service' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "the previous profile kept running"
fi

world down-stops-and-forgets
FAKE_ACTIVE=HY2
export FAKE_ACTIVE
mkdir -p "$(dirname "$(active_file)")"
printf 'HY2\n' >"$(active_file)"
sv down >/dev/null
if grep -q 'stop sing-box@HY2.service' "$SYSTEMCTL_LOG" && [[ ! -e $(active_file) ]]; then
  ok
else
  fail "down did not stop the unit or forget the choice"
fi

world restore-brings-the-choice-back
sv add "$HY2" >/dev/null
mkdir -p "$(dirname "$(active_file)")"
printf 'HY2\n' >"$(active_file)"
sv restore >/dev/null
if grep -q 'start --no-block sing-box@HY2.service' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "restore did not start the remembered profile"
fi

world restore-is-quiet-with-no-choice
if sv restore >/dev/null 2>&1 && ! grep -q start "$SYSTEMCTL_LOG"; then
  ok
else
  fail "restore invented a profile where none was remembered"
fi

boot_file() { printf '%s/var/lib/skvpn/boot' "$SKVPN_ROOT"; }

# A pin beats the last `up`: what restore starts is the choice made by hand
world boot-pins-a-profile-for-restore
sv add "$HY2" "$TROJAN" >/dev/null
sv up HY2 >/dev/null
sv boot TROJAN-node >/dev/null
: >"$SYSTEMCTL_LOG"
sv restore >/dev/null
if [[ "$(cat "$(boot_file)")" == TROJAN-node && "$(cat "$(active_file)")" == HY2 ]] &&
  grep -q 'start --no-block sing-box@TROJAN-node.service' "$SYSTEMCTL_LOG" &&
  [[ "$(sv boot)" == "  on boot   TROJAN-node" ]]; then
  ok
else
  fail "the pin did not reach restore, or replaced the last up"
fi

world boot-last-follows-the-last-up
sv add "$HY2" "$TROJAN" >/dev/null
sv boot TROJAN-node >/dev/null
sv up HY2 >/dev/null
sv boot last >/dev/null
: >"$SYSTEMCTL_LOG"
sv restore >/dev/null
if [[ ! -e $(boot_file) ]] &&
  grep -q 'start --no-block sing-box@HY2.service' "$SYSTEMCTL_LOG" &&
  [[ "$(sv boot)" == "  on boot   HY2 (last up)" ]]; then
  ok
else
  fail "boot last did not drop the pin, or restore ignored the last up"
fi

world boot-refuses-an-unknown-profile
if sv boot nope >/dev/null 2>&1; then
  fail "a profile that does not exist was pinned for boot"
elif [[ ! -e $(boot_file) ]]; then
  ok
else
  fail "a refused pin still landed on disk"
fi

world rm-clears-a-pin
sv add "$HY2" >/dev/null
sv boot HY2 >/dev/null
sv rm HY2 >/dev/null
if [[ ! -e $(boot_file) ]]; then
  ok
else
  fail "a deleted profile stayed pinned for boot"
fi

# The choice is kept either way, but with the restore unit off it is not what boot does
world status-shows-the-boot-choice-only-when-restore-is-enabled
sv add "$HY2" "$TROJAN" >/dev/null
sv up HY2 >/dev/null
export FAKE_ACTIVE=HY2
following=$(sv status)
sv boot TROJAN-node >/dev/null
pinned=$(sv status)
export SYSTEMCTL_FAIL='is-enabled'
off=$(sv status)
if [[ "$following" == *"  profile   HY2"* && "$following" == *"  on boot   HY2 (last up)"* &&
  "$pinned" == *"  on boot   TROJAN-node"* && "$pinned" != *"(last up)"* &&
  "$off" == *"  profile   HY2"* && "$off" != *"on boot"* ]]; then
  ok
else
  fail "status misreported the boot choice, or showed one with restore off"
fi

echo "guard"

# The rendered guard config is the switch: the CLI reads no option, only this file
guard_on() {
  mkdir -p "$SKVPN_ROOT/etc/sing-box"
  printf '{}\n' >"$SKVPN_ROOT/etc/sing-box/guard.json"
}

# Line number of the first systemctl call matching $1, so the order of two can be asked:
# a profile and the guard make the same TUN, and only stop-then-start can work
# No match prints nothing and is not an error: the case names the miss, set -e must not
call_at() { { grep -n -m1 -F "$1" "$SYSTEMCTL_LOG" || true; } | cut -d: -f1; }

world down-without-guard-starts-nothing
FAKE_ACTIVE=HY2
export FAKE_ACTIVE
sv down >/dev/null
if ! grep -qE '^start (sing-box@|skvpn-guard)' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "down started something with no guard configured"
fi

world down-starts-the-guard
guard_on
FAKE_ACTIVE=HY2
export FAKE_ACTIVE
out=$(sv down)
stopped=$(call_at 'stop sing-box@HY2.service')
started=$(call_at 'start skvpn-guard.service')
if [[ -n "$stopped" && -n "$started" ]] && ((stopped < started)) && [[ "$out" == *guard* ]]; then
  ok
else
  fail "down did not stop the profile before starting the guard"
fi

# A start the unit's own condition skipped answers 0; the CLI must not call that a guard
# Off entirely: the profile and the guard both stop, and nothing starts in their place
world down-no-guard-stops-everything
guard_on
FAKE_ACTIVE=HY2
export FAKE_ACTIVE
sv down --no-guard >/dev/null || true
if grep -q 'stop sing-box@HY2.service' "$SYSTEMCTL_LOG" &&
  grep -q 'stop skvpn-guard.service' "$SYSTEMCTL_LOG" &&
  ! grep -qE '^start (sing-box@|skvpn-guard)' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "down --no-guard left something running or started the guard"
fi

world down-reports-a-guard-that-stayed-down
guard_on
export SYSTEMCTL_FAIL='is-active'
if ! err=$(sv down 2>&1) && [[ "$err" == *"guard did not come up"* ]]; then
  ok
else
  fail "down claimed a guard that never came up"
fi

world up-stops-the-guard
sv add "$HY2" >/dev/null
guard_on
sv up HY2 >/dev/null
stopped=$(call_at 'stop skvpn-guard.service')
started=$(call_at 'start sing-box@HY2.service')
if [[ -n "$stopped" && -n "$started" ]] && ((stopped < started)); then
  ok
else
  fail "up did not stop the guard before starting the profile"
fi

world up-falls-back-to-the-guard
sv add "$HY2" >/dev/null
guard_on
export SYSTEMCTL_FAIL='start sing-box@HY2'
if ! sv up HY2 >/dev/null 2>&1 && grep -q 'start skvpn-guard.service' "$SYSTEMCTL_LOG" &&
  [[ ! -e $(active_file) ]]; then
  ok
else
  fail "a profile that failed to start left the host unguarded, or was remembered"
fi

world restore-starts-the-guard-with-no-choice
guard_on
if sv restore >/dev/null && grep -q 'start --no-block skvpn-guard.service' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "boot with nothing to restore left the host unguarded"
fi

world restore-guards-a-missing-profile
guard_on
mkdir -p "$(dirname "$(active_file)")"
printf 'gone\n' >"$(active_file)"
if ! sv restore >/dev/null 2>&1 && grep -q 'start --no-block skvpn-guard.service' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "a remembered profile that is gone left boot unguarded, or passed quietly"
fi

world restart-restarts-the-guard
guard_on
if sv restart >/dev/null 2>&1 && grep -q 'restart skvpn-guard.service' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "restart with only the guard up did not restart it"
fi

world status-shows-the-guard
guard_on
on=$(sv status)
export SYSTEMCTL_FAIL='is-active'
off=$(sv status)
if [[ "$on" == *"  profile   none, guard on"* && "$off" == *"  profile   none"* && "$off" != *guard* ]]; then
  ok
else
  fail "status did not tell a guarded off from a bare one"
fi

echo "hold"

# Between the old sing-box and the new one nothing carries the traffic, so a switch first
# holds the network; the new unit's bypass step lets it go, never the CLI
HOLD='start skvpn-nft@hold.service'
RELEASE='start skvpn-nft@release.service'
HELD_HINT='skvpn down --no-guard'

world up-holds-before-it-stops
sv add "$HY2" >/dev/null
export FAKE_ACTIVE=TROJAN-node
sv up HY2 >/dev/null
held=$(call_at "$HOLD")
stopped=$(call_at 'stop sing-box@TROJAN-node.service')
started=$(call_at 'start sing-box@HY2.service')
if [[ -n "$held" && -n "$stopped" && -n "$started" ]] && ((held < stopped && stopped < started)) &&
  ! grep -qF "$RELEASE" "$SYSTEMCTL_LOG"; then
  ok
else
  fail "up stopped the old tunnel before holding the network, or let it go itself"
fi

world down-holds-until-the-guard-is-up
guard_on
export FAKE_ACTIVE=HY2
sv down >/dev/null
held=$(call_at "$HOLD")
stopped=$(call_at 'stop sing-box@HY2.service')
if [[ -n "$held" && -n "$stopped" ]] && ((held < stopped)) && ! grep -qF "$RELEASE" "$SYSTEMCTL_LOG"; then
  ok
else
  fail "down stopped the profile before holding the network, or let it go before the guard"
fi

# Off with nothing to guard is the open network, and so is --no-guard: a hold left by a
# crash goes too, after the last sing-box has stopped
world down-without-a-guard-lets-the-network-go
export FAKE_ACTIVE=HY2
sv down >/dev/null
stopped=$(call_at 'stop sing-box@HY2.service')
released=$(call_at "$RELEASE")
if [[ -n "$stopped" && -n "$released" ]] && ((stopped < released)) && ! grep -qF "$HOLD" "$SYSTEMCTL_LOG"; then
  ok
else
  fail "down with no guard left the network held"
fi

world down-no-guard-lets-the-network-go
guard_on
export FAKE_ACTIVE=HY2
sv down --no-guard >/dev/null
stopped=$(call_at 'stop skvpn-guard.service')
released=$(call_at "$RELEASE")
if [[ -n "$stopped" && -n "$released" ]] && ((stopped < released)) && ! grep -qF "$HOLD" "$SYSTEMCTL_LOG"; then
  ok
else
  fail "down --no-guard left the network held"
fi

world restart-holds-first
export FAKE_ACTIVE=HY2
sv restart >/dev/null
held=$(call_at "$HOLD")
restarted=$(call_at 'restart sing-box@HY2.service')
if [[ -n "$held" && -n "$restarted" ]] && ((held < restarted)); then
  ok
else
  fail "restart took the tunnel down before holding the network"
fi

world restart-holds-before-the-guard
guard_on
sv restart >/dev/null
held=$(call_at "$HOLD")
restarted=$(call_at 'restart skvpn-guard.service')
if [[ -n "$held" && -n "$restarted" ]] && ((held < restarted)); then
  ok
else
  fail "restart took the guard down before holding the network"
fi

# A switch that cannot hold would leak; the running tunnel stays instead
world a-switch-that-cannot-hold-changes-nothing
sv add "$HY2" >/dev/null
export FAKE_ACTIVE=TROJAN-node
export SYSTEMCTL_FAIL='skvpn-nft@hold'
if ! err=$(sv up HY2 2>&1) && ! grep -qE '^(stop|start sing-box@)' "$SYSTEMCTL_LOG" &&
  [[ "$err" == *hold* ]]; then
  ok
else
  fail "up switched without a hold, or did not say why it refused"
fi

# A unit waiting out RestartSec is not active, and would come back after down
world down-stops-a-profile-waiting-to-restart
export FAKE_ACTIVATING=HY2
sv down --no-guard >/dev/null
if grep -q 'stop sing-box@HY2.service' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "down left a restarting profile to come back"
fi

# Restart=on-failure would bring the failed profile back beside the guard, where its next
# failure holds the network the guard is serving
world up-stops-the-profile-that-failed
sv add "$HY2" >/dev/null
guard_on
export SYSTEMCTL_FAIL='start sing-box@HY2'
sv up HY2 >/dev/null 2>&1 || true
failed=$(call_at 'start sing-box@HY2.service')
stopped=$({ grep -n 'stop sing-box@HY2.service' "$SYSTEMCTL_LOG" || true; } | tail -n1 | cut -d: -f1)
guarded=$(call_at 'start skvpn-guard.service')
if [[ -n "$failed" && -n "$stopped" && -n "$guarded" ]] && ((failed < stopped && stopped < guarded)); then
  ok
else
  fail "a profile that failed to start was left to restart beside the guard"
fi

world a-failed-up-says-the-network-is-held
sv add "$HY2" >/dev/null
export SYSTEMCTL_FAIL='start sing-box@HY2'
if ! err=$(sv up HY2 2>&1) && [[ "$err" == *"$HELD_HINT"* ]]; then
  ok
else
  fail "a failed up did not say how to let the held network go"
fi

world a-guard-that-stayed-down-says-the-network-is-held
guard_on
export SYSTEMCTL_FAIL='is-active'
if ! err=$(sv down 2>&1) && [[ "$err" == *"$HELD_HINT"* ]]; then
  ok
else
  fail "a guard that stayed down did not say how to let the held network go"
fi

echo "export"

# The merge is sing-box's own: the CLI hands it the base directory and the profile, and
# prints what it wrote — the stub records the arguments and writes them back as the result
world export-merges-the-profile-over-the-base
sv add "$HY2" >/dev/null
# A failing export prints nothing here; the case names it rather than set -e ending the run
out=$(sv export HY2 2>/dev/null) || true
if [[ "$(jq -r '.merged | join(" ")' <<<"$out")" == "-C $SKVPN_ROOT/etc/sing-box/base.d -c $(profile HY2)" ]]; then
  ok
else
  fail "export did not hand sing-box the base and the profile, or did not print its result"
fi

world export-defaults-to-the-running-profile
sv add "$HY2" >/dev/null
export FAKE_ACTIVE=HY2
if [[ "$(sv export | jq -r '.merged[-1]')" == "$(profile HY2)" ]]; then
  ok
else
  fail "a bare export did not take the running profile"
fi

world export-needs-a-profile
if ! sv export >/dev/null 2>&1 && ! sv export nope >/dev/null 2>&1; then
  ok
else
  fail "export with nothing running, or of a missing profile, did not fail"
fi

# A base the way the installer renders one, so the phone's policy is read from where the
# host's lives; the custom rule-set has no public source and must be left out, loudly
sfa_base() {
  mkdir -p "$SKVPN_ROOT/etc/sing-box/base.d"
  python3 "$REPO/non-nix/render-base.py" --skip-path-check --preset russia --tailscale \
    --direct-zone .by --direct-geosite custom=/opt/rules/custom.srs --dns-server 1.1.1.1 \
    --split-name firefox --split-ip 10.99.0.0/16 --split-domain example.com \
    >"$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
}

world export-sfa-carries-every-profile-and-the-host-policy
sv add "$HY2" "$TROJAN" >/dev/null
sfa_base
sv split add domain split.example.org >/dev/null
export FAKE_ACTIVE=TROJAN-node
out=$(sv export --sfa 2>"$SKVPN_ROOT/err") || true
direct='[.route.rules[] | select(.outbound == "direct")]'
if jq -e '.outbounds[0] == {"type": "selector", "tag": "proxy", "outbounds": ["HY2", "TROJAN-node"], "default": "TROJAN-node"}' <<<"$out" >/dev/null &&
  jq -e '[.outbounds[1:3][] | .tag] == ["HY2", "TROJAN-node"] and (.outbounds[1].type == "hysteria2")' <<<"$out" >/dev/null &&
  jq -e "$direct | map(.domain_suffix // []) | add | (index(\".ru\") and index(\".by\") and index(\"example.com\") and index(\"split.example.org\"))" <<<"$out" >/dev/null &&
  jq -e "$direct | map(.ip_cidr // []) | add | index(\"10.99.0.0/16\")" <<<"$out" >/dev/null &&
  jq -e '[.route.rules[] | keys[] | select(startswith("process_"))] == []' <<<"$out" >/dev/null &&
  jq -e --slurpfile p "$REPO/policy.json" '$p[0].ruleSets as $s |
    ($p[0].presets[] | select(.name == "russia")) as $ru |
    [.route.rule_set[] | {tag, url}] == [
      {"tag": "geosite-\($ru.tag)", "url": "https://raw.githubusercontent.com/\($s.geosite)/\($s.branch)/\($ru.geosite)"},
      {"tag": "geoip-\($ru.tag)", "url": "https://raw.githubusercontent.com/\($s.geoip)/\($s.branch)/\($ru.geoip)"}
    ]' <<<"$out" >/dev/null &&
  jq -e '.route.rule_set | all(.type == "remote" and .http_client == "through-proxy")' <<<"$out" >/dev/null &&
  jq -e '.http_clients == [{"tag": "through-proxy", "detour": "proxy"}]' <<<"$out" >/dev/null &&
  jq -e '.dns.servers | map(select(.tag == "remote"))[0].server == "1.1.1.1"' <<<"$out" >/dev/null &&
  jq -e '.inbounds[0].route_exclude_address | index("192.168.0.0/16")' <<<"$out" >/dev/null &&
  jq -e '.route.final == "proxy" and .experimental.cache_file.enabled' <<<"$out" >/dev/null &&
  grep -q 'custom' "$SKVPN_ROOT/err"; then
  ok
else
  fail "the phone config lost a profile, a piece of the host's policy, or kept a process rule"
fi

# Tailscale follows the host: a base that keeps the tailnet out of its TUN gets the
# endpoint, its DNS and its route; --no-tailscale and a base without it get none
world export-sfa-follows-the-host-tailnet
sv add "$HY2" >/dev/null
sfa_base
with=$(sv export --sfa 2>/dev/null) || true
without=$(sv export --sfa --no-tailscale 2>/dev/null) || true
python3 "$REPO/non-nix/render-base.py" --skip-path-check >"$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
bare=$(sv export --sfa 2>/dev/null) || true
has_tailnet() {
  jq -e --slurpfile p "$REPO/policy.json" '
    (.endpoints // []) == [{"type": "tailscale", "tag": "tailnet"}] and
    (.route.rules | any(.outbound == "tailnet" and .ip_cidr == $p[0].tailnet)) and
    (.dns.rules | any(.server == "tailnet"))' >/dev/null
}
if has_tailnet <<<"$with" && ! has_tailnet <<<"$without" &&
  jq -e '.endpoints == null' <<<"$without" >/dev/null &&
  jq -e '.endpoints == null' <<<"$bare" >/dev/null; then
  ok
else
  fail "the phone's tailnet did not follow the host's, or --no-tailscale kept it"
fi

# A rule-set's source is found by its tag in policy.json, never by its path: the NixOS
# base names the same file by a store path, which carries a hash and spells `!` as `not-`
world export-sfa-names-rule-sets-by-tag
sv add "$HY2" >/dev/null
sfa_base
jq '.route.rule_set |= map(.path = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-anything.srs")' \
  "$SKVPN_ROOT/etc/sing-box/base.d/00-base.json" >"$SKVPN_ROOT/base.json"
mv "$SKVPN_ROOT/base.json" "$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
out=$(sv export --sfa 2>/dev/null) || true
if jq -e --slurpfile p "$REPO/policy.json" '($p[0].presets[] | select(.name == "russia")) as $ru |
    .route.rule_set | map(select(.tag == "geosite-\($ru.tag)"))[0].url | endswith("/\($ru.geosite)")' \
  <<<"$out" >/dev/null; then
  ok
else
  fail "a rule-set was not named by its tag"
fi

# The host's guard rides along as a clash mode the phone can switch to: in Direct, the
# guarded sites are refused and everything else leaves direct, the tailnet still through
# its endpoint; in Rule, the usual routing. No guard on the host, no mode on the phone
sfa_guard() {
  python3 "$REPO/non-nix/render-base.py" --skip-path-check --render guard --guard-ai \
    --guard-zone example.net >"$SKVPN_ROOT/etc/sing-box/guard.json"
}

world export-sfa-carries-the-guard-as-a-clash-mode
sv add "$HY2" >/dev/null
sfa_base
sfa_guard
out=$(sv export --sfa 2>/dev/null) || true
if jq -e --slurpfile p "$REPO/policy.json" '"geosite-\($p[0].guard.tag)" as $ai |
    .experimental.clash_api.default_mode == "Rule" and
    ([.route.rules[] | select(.clash_mode == "Direct")] == [
      {"clash_mode": "Direct", "domain_suffix": ["example.net"], "action": "reject"},
      {"clash_mode": "Direct", "rule_set": [$ai], "action": "reject"},
      {"clash_mode": "Direct", "outbound": "direct"}
    ]) and
    ([.dns.rules[] | select(.clash_mode == "Direct")] == [
      {"clash_mode": "Direct", "domain_suffix": ["example.net"], "action": "predefined", "rcode": "REFUSED"},
      {"clash_mode": "Direct", "rule_set": [$ai], "action": "predefined", "rcode": "REFUSED"},
      {"clash_mode": "Direct", "action": "route", "server": "local"}
    ]) and
    (.route.rule_set | map(select(.tag == $ai))[0].url | endswith("/\($p[0].guard.geosite)")) and
    ([.route.rules[] | .outbound == "tailnet"] | index(true)) <
      ([.route.rules[] | .clash_mode == "Direct"] | index(true))' <<<"$out" >/dev/null; then
  ok
else
  fail "the host guard did not become a Direct mode that refuses its sites, or it took the tailnet"
fi

# A phone has no search domain, so `se-1` resolves only if the tailnet's own DNS server
# expands it, and only if the first DNS rule hands that server every name it claims
world export-sfa-resolves-short-tailnet-names
sv add "$HY2" >/dev/null
sfa_base
sfa_guard
out=$(sv export --sfa 2>/dev/null) || true
if jq -e '(.dns.servers | map(select(.tag == "tailnet"))[0].accept_search_domain == true) and
    (.dns.rules[0] | .preferred_by == "tailnet" and .action == "route" and .server == "tailnet")' \
  <<<"$out" >/dev/null; then
  ok
else
  fail "the phone's tailnet DNS does not take single-label names first"
fi

world export-sfa-has-no-mode-without-a-guard
sv add "$HY2" >/dev/null
sfa_base
out=$(sv export --sfa 2>/dev/null) || true
if jq -e '(.experimental.clash_api == null) and ([.route.rules[], .dns.rules[] | select(has("clash_mode"))] == [])' \
  <<<"$out" >/dev/null; then
  ok
else
  fail "a phone got a guard mode the host does not have"
fi

# The real sing-box has to accept what the phone gets; the stub is first on PATH, so the
# binary is the next one there. check proves the config parses, not that it starts
# (PITFALLS.md), which the prototype on a phone did
world export-sfa-passes-the-real-sing-box
sv add "$HY2" "$TROJAN" >/dev/null
sfa_base
sfa_guard
real=$(type -ap sing-box | grep -v -x -F "$HERE/stub/sing-box" | head -n 1 || true)
sv export --sfa >"$SKVPN_ROOT/phone.json" 2>/dev/null || true
if [[ -z "$real" ]]; then
  fail "no real sing-box on PATH after the stub"
elif err=$("$real" check -c "$SKVPN_ROOT/phone.json" 2>&1); then
  ok
else
  fail "the real sing-box refused the phone config: $err"
fi

echo "split"

split_file() { printf '%s/etc/sing-box/base.d/70-split.json' "$SKVPN_ROOT"; }

# The rendered file is the state: one direct rule per kind, a bootstrap DNS rule for the
# process kinds — and no restart of its own; dropping the tunnel is the user's call
world split-add-writes-the-rule-file-and-asks-for-a-restart
export FAKE_ACTIVE=HY2
out=$(sv split add firefox)
sv split add path /usr/bin/steam >/dev/null
sv split add ip 10.0.0.0/8 >/dev/null
file=$(split_file)
if jq -e '.route.rules | map(select(.process_name == ["firefox"] and .outbound == "direct")) | length == 1' "$file" >/dev/null &&
  jq -e '.route.rules | any(.process_path == ["/usr/bin/steam"] and .outbound == "direct")' "$file" >/dev/null &&
  jq -e '.route.rules | any(.ip_cidr == ["10.0.0.0/8"] and .outbound == "direct")' "$file" >/dev/null &&
  jq -e '.dns.rules | length == 2 and all(.server == "bootstrap")' "$file" >/dev/null &&
  jq -e '.dns.rules | any(has("ip_cidr")) | not' "$file" >/dev/null &&
  [[ "$(stat -c %a "$file")" == 644 && "$out" == *'HY2 is still on the old rules'* &&
  "$out" == *'sudo skvpn restart'* ]] &&
  ! grep -q restart "$SYSTEMCTL_LOG"; then
  ok
else
  fail "the split rules did not land as direct rules, or the restart was done instead of asked for"
fi

world restart-starts-the-active-profile-over
export FAKE_ACTIVE=HY2
if sv restart >/dev/null && grep -qx 'restart sing-box@HY2.service' "$SYSTEMCTL_LOG"; then
  unset FAKE_ACTIVE
  if sv restart >/dev/null 2>&1; then
    fail "restart with nothing up exited 0"
  else
    ok
  fi
else
  fail "restart did not restart the active unit"
fi

world split-rm-empties-and-removes-the-file
sv split add firefox >/dev/null
sv split add firefox >/dev/null
sv split rm firefox >/dev/null
if [[ ! -e $(split_file) ]] && ! sv split rm firefox >/dev/null 2>&1; then
  ok
else
  fail "an emptied split list left its file, or rm of a missing entry passed"
fi

# Both lists are on the wire, so both are shown: the declared one from the rendered base,
# marked as such and never edited here, then the imperative one
world split-ls-lists-both-lists-in-kind-order
mkdir -p "$SKVPN_ROOT/etc/sing-box/base.d"
printf '{"route":{"rules":[{"process_name":["telegram"],"outbound":"direct"},{"ip_cidr":["192.168.0.0/16"],"outbound":"direct"}]}}\n' \
  >"$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
sv split add ip 10.0.0.0/8 >/dev/null
sv split add path /usr/bin/steam >/dev/null
sv split add firefox >/dev/null
want="  name  $(printf '%-40s' telegram) declared
  name  firefox
  path  /usr/bin/steam
  ip    $(printf '%-40s' 192.168.0.0/16) declared
  ip    10.0.0.0/8"
if [[ "$(sv split ls)" == "$want" && "$(sv split)" == "$want" ]]; then
  ok
else
  fail "split ls did not list both lists in kind order"
fi

# Wildcards: sing-box's exact fields take none, so a name or path with * or ? becomes a
# regex on the executable's path — and comes back as the glob it was in `ls` and `rm`
world split-wildcards-become-a-path-regex
sv split add 'chrom*' >/dev/null
sv split add path '/opt/*/bin/tor' >/dev/null
sv split add path '/nix/store/**/bin/x?' >/dev/null
file=$(split_file)
want=$'  name  chrom*\n  path  /opt/*/bin/tor\n  path  /nix/store/**/bin/x?'
if jq -e '.route.rules == [{"process_path_regex": ["(^|/)chrom[^/]*$", "^/opt/[^/]*/bin/tor$", "^/nix/store/.*/bin/x[^/]$"], "outbound": "direct"}]' "$file" >/dev/null &&
  jq -e '.dns.rules[0].process_path_regex | length == 3' "$file" >/dev/null &&
  [[ "$(sv split ls)" == "$want" ]] &&
  sv split rm 'chrom*' path '/opt/*/bin/tor' >/dev/null 2>&1 ||
  sv split rm 'chrom*' >/dev/null && sv split rm path '/opt/*/bin/tor' >/dev/null &&
  jq -e '.route.rules[0].process_path_regex == ["^/nix/store/.*/bin/x[^/]$"]' "$file" >/dev/null &&
  ! sv split add ip '10.0.*' >/dev/null 2>&1; then
  ok
else
  fail "wildcards did not render as a path regex, or did not read back as globs"
fi

# The installer's renderer makes the very same translation, or a list moved between the
# declared and the imperative layer would change meaning
world installer-renders-split-wildcards-the-same-way
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split 'chrom*' --split path '/opt/*/bin/tor' >/dev/null
base="$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json"
if jq -e '.route.rules[-1] == {"process_path_regex": ["(^|/)chrom[^/]*$", "^/opt/[^/]*/bin/tor$"], "outbound": "direct"}' "$base" >/dev/null &&
  jq -e '.dns.rules[-1].process_path_regex == ["(^|/)chrom[^/]*$", "^/opt/[^/]*/bin/tor$"]' "$base" >/dev/null &&
  jq -e '.route.rules | any(has("process_name")) | not' "$base" >/dev/null; then
  ok
else
  fail "the installer rendered a wildcard differently from the CLI"
fi

# sing-box's own traffic never enters the tunnel, so an entry naming it can do nothing
# right — and a pattern wide enough to catch it catches everything, the tunnel off
world split-refuses-sing-box-itself
if sv split add sing-box >/dev/null 2>&1 ||
  sv split add 'sing*' >/dev/null 2>&1 ||
  sv split add '*' >/dev/null 2>&1 ||
  sv split add path "$HERE/stub/sing-box" >/dev/null 2>&1 ||
  sv split add path '/**' >/dev/null 2>&1; then
  fail "an entry matching sing-box itself was accepted"
elif [[ ! -e $(split_file) ]] && sv split add 'sing-box-ui' >/dev/null &&
  sv split add path "$HERE/stub/sing-box-ui" >/dev/null; then
  ok
else
  fail "the refusal left a file, or caught a name that merely contains sing-box"
fi

world installer-refuses-sing-box-in-split
if "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split sing-box >/dev/null 2>&1 ||
  "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split path /usr/bin/sing-box >/dev/null 2>&1 ||
  "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split '*' >/dev/null 2>&1; then
  fail "the installer accepted a split entry matching sing-box itself"
elif [[ ! -e "$SKVPN_ROOT/stage/usr/local/bin/skvpn" ]] &&
  SING_BOX=/opt/sb/bin/sing-box "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split path /usr/bin/sing-box >/dev/null; then
  ok
else
  fail "the refusal left a partial install, or the installer's own SING_BOX was not what a path is checked against"
fi

# A site as typed — bare, a URL, *.example.com, an IDN — lands as the suffix sing-box
# matches on the name asked for, with its DNS steered to the bootstrap like a direct
# zone; the base's own zones show up in ls as declared domains
world split-domain-entries-become-direct-zones
mkdir -p "$SKVPN_ROOT/etc/sing-box/base.d"
printf '{"route":{"rules":[{"domain_suffix":[".ru",".su"],"outbound":"direct"}]}}\n' \
  >"$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
sv split add domain 'https://Example.com/some/path' >/dev/null
sv split add domain '*.cdn.example.net' >/dev/null
sv split add domain 'пример.рф' >/dev/null
sv split add domain '.by' >/dev/null
file=$(split_file)
# The file keeps the wire form; ls reads it back for a person, wire form in brackets
want="  domain $(printf '%-40s' .ru) declared
  domain $(printf '%-40s' .su) declared
  domain example.com
  domain .cdn.example.net
  domain пример.рф (xn--e1afmkfd.xn--p1ai)
  domain .by"
if jq -e '.route.rules == [{"domain_suffix": ["example.com", ".cdn.example.net", "xn--e1afmkfd.xn--p1ai", ".by"], "outbound": "direct"}]' "$file" >/dev/null &&
  jq -e '.dns.rules == [{"domain_suffix": ["example.com", ".cdn.example.net", "xn--e1afmkfd.xn--p1ai", ".by"], "action": "route", "server": "bootstrap"}]' "$file" >/dev/null &&
  [[ "$(sv split ls)" == "$want" ]] &&
  sv split rm domain example.com >/dev/null &&
  sv split rm domain 'пример.рф' >/dev/null &&
  ! grep -q xn--e1afmkfd "$file" &&
  ! sv split add domain 'not a domain' >/dev/null 2>&1 &&
  ! sv split add domain 'localhost' >/dev/null 2>&1 &&
  ! sv split add domain 'by' >/dev/null 2>&1; then
  ok
else
  fail "a domain entry did not land as a direct zone, or ls hid the declared ones"
fi

world split-add-says-when-the-rule-counts
out=$(sv split add firefox)
if [[ -e $(split_file) && "$out" == *"takes effect on the next"* ]] &&
  ! grep -q restart "$SYSTEMCTL_LOG"; then
  ok
else
  fail "split add with nothing running restarted something, or did not say when the rule counts"
fi

# A kind word without a value is a usage error, not a process called ip; the bad values
# must not leave a half-written file behind
world split-validates-values
if sv split add ip not-an-ip >/dev/null 2>&1 ||
  sv split add path relative/bin >/dev/null 2>&1 ||
  sv split add name /usr/bin/x >/dev/null 2>&1 ||
  sv split add ip >/dev/null 2>&1 ||
  sv split frobnicate >/dev/null 2>&1; then
  fail "an invalid split entry was accepted"
elif [[ ! -e $(split_file) ]] && sv split add name ip >/dev/null &&
  [[ "$(sv split ls)" == "  name  ip" ]]; then
  ok
else
  fail "an invalid split entry left a file, or a process literally called ip cannot be listed"
fi

echo "ping"

# One throwaway sing-box carries every profile as an outbound tagged with its name and
# answers the Clash delay endpoint; the config is what the stub kept, the answers are
# what the stub was told to give
world ping-probes-every-profile-through-a-temporary-sing-box
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42,TROJAN-node=timeout'
probe_dirs() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'skvpn-ping-*' 2>/dev/null | wc -l; }
tmp_before=$(probe_dirs)
out=$(sv ping)
tmp_after=$(probe_dirs)
if [[ "$out" == *"HY2"*"42 ms"* && "$out" == *"TROJAN-node"*"timeout"* ]] &&
  jq -e '.outbounds | map(.tag) | sort == ["HY2", "TROJAN-node"]' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '.route.default_mark == 8228 and .route.auto_detect_interface == true' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e 'has("inbounds") | not' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '.experimental.clash_api.external_controller | startswith("127.0.0.1:")' "$SING_BOX_CONFIG" >/dev/null &&
  grep -q 'url=https%3A%2F%2Fwww.google.com%2Fgenerate_204' "$SING_BOX_LOG" &&
  [[ "$tmp_before" == "$tmp_after" ]] &&
  ! pgrep -f "$SKVPN_ROOT/probe" >/dev/null; then
  ok
else
  fail "the probe carried the wrong outbounds, the wrong mark, the wrong url, or left something behind"
fi

# A node's address is part of what a profile keeps private: no table carries it unless
# asked, and the ask is the same word for ls, ping and status --ping
world servers-show-only-when-asked
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42'
plain_ls=$(sv ls)
full_ls=$(sv ls --servers)
plain_ping=$(sv ping)
full_ping=$(sv ping --servers HY2)
full_status=$(sv status --ping --servers)
if [[ "$plain_ls" != *node.example.com* && "$full_ls" == *"hysteria2 "*node.example.com* &&
  "$plain_ping" == *"HY2"*"hysteria2"*"42 ms"* && "$plain_ping" != *node.example.com* &&
  "$full_ping" == *node.example.com*"42 ms"* && "$full_status" == *node.example.com*"42 ms"* ]] &&
  ! sv status --servers >/dev/null 2>&1; then
  ok
else
  fail "a server showed without --servers, or stayed hidden with it"
fi

world ping-names-only-the-asked-profiles
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42'
sv ping HY2 >/dev/null
if jq -e '.outbounds | map(.tag) == ["HY2"]' "$SING_BOX_CONFIG" >/dev/null; then
  rm -f "$SING_BOX_CONFIG"
  if sv ping nope >/dev/null 2>&1 || [[ -e $SING_BOX_CONFIG ]]; then
    fail "an unknown profile name was probed"
  else
    ok
  fi
else
  fail "ping probed more than it was asked for"
fi

# https only: sing-box's delay test swaps a plain-http url for its own default site
# without a word, so accepting http would measure the wrong thing silently
world ping-set-accepts-a-host-or-an-https-url
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42'
ping_file="$SKVPN_ROOT/etc/sing-box/ping.url"
sv ping set example.org >/dev/null
host_form=$(<"$ping_file")
sv ping >/dev/null
sv ping set https://1.1.1.1/x >/dev/null
url_form=$(<"$ping_file")
if [[ "$host_form" == "https://example.org/" && "$url_form" == "https://1.1.1.1/x" ]] &&
  grep -q 'url=https%3A%2F%2Fexample.org%2F' "$SING_BOX_LOG" &&
  ! sv ping set 'http://x/' >/dev/null 2>&1 &&
  ! sv ping set 'ftp://x' >/dev/null 2>&1 &&
  ! sv ping set 'a/b' >/dev/null 2>&1; then
  ok
else
  fail "ping set mangled the target, or accepted one that is not https"
fi

# The probe resolves like the base's bootstrap — the system resolver, for the nodes'
# own hostnames only; the site's name is the node's to resolve, so no resolver of the
# probe's own is on the wire to be blocked. ipv4_only is load-bearing: the distro suite
# watched an unanswered AAAA hold every lookup for seconds and eat the test's budget
world ping-resolves-node-names-with-the-system-resolver
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42'
sv ping >/dev/null
if jq -e '.dns == {"servers": [{"tag": "bootstrap", "type": "local"}], "final": "bootstrap", "strategy": "ipv4_only"}' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '.route.default_domain_resolver == "bootstrap"' "$SING_BOX_CONFIG" >/dev/null; then
  ok
else
  fail "the probe brought a resolver of its own, or lost the ipv4_only strategy"
fi

world ping-marks-an-unlisted-answer-unreachable
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=10'
if [[ "$(sv ping)" == *"TROJAN-node"*"unreachable"* ]]; then
  ok
else
  fail "a node that could not do the test was not marked unreachable"
fi

world ping-reports-a-probe-that-refuses-to-start
sv add "$HY2" >/dev/null
export SING_BOX_FAIL=1
if out=$(sv ping 2>&1); then
  fail "ping exited 0 with a probe that refused its config"
elif [[ "$out" == *refused* ]]; then
  ok
else
  fail "ping hid why the probe did not start"
fi

world status-ping-appends-the-table-and-plain-status-does-not-probe
sv add "$HY2" >/dev/null
export FAKE_ACTIVE=HY2
export FAKE_DELAYS='HY2=42'
with_ping=$(sv status --ping)
rm -f "$SING_BOX_CONFIG"
sv status >/dev/null
if [[ "$with_ping" == *"  profile   HY2"* && "$with_ping" == *"* HY2"*"42 ms"* &&
  ! -e $SING_BOX_CONFIG ]] && ! sv status --nope >/dev/null 2>&1; then
  ok
else
  fail "status --ping missed the table, or a plain status started a probe"
fi

echo "measure"

# The value of one sample in a textfile: metric FILE NAME [NODE]
metric() {
  local want="$2"
  [[ -z "${3:-}" ]] || want="$2{node=\"$3\"}"
  awk -v want="$want" '$1 == want { print $2 }' "$1"
}
# Numeric equality, and false for an empty side: awk reads nothing as 0
near() {
  [[ -n "$1" && -n "$2" ]] && awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; exit !(d < 1e-9 && d > -1e-9) }'
}
measure_dirs() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'skvpn-measure-*' 2>/dev/null | wc -l; }

# The ping probe grows a pair of inbounds per exit: a mixed one for the curl through the
# exit, a direct UDP one for the DNS queries, each routed to that exit alone. Loopback
# only, every port its own
world measure-probes-each-exit-through-its-own-inbounds
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42,TROJAN-node=42'
export FAKE_CURL='HY2=0.2:5000000:1.2,TROJAN-node=0.3:5000000:1.3'
tmp_before=$(measure_dirs)
sv measure >/dev/null
tmp_after=$(measure_dirs)
if jq -e '. as $c | ($c.outbounds | map(.tag) | sort) == ["HY2", "TROJAN-node"] and
  all($c.outbounds[].tag; . as $t |
    [$c.route.rules[] | select(.outbound == $t) | .inbound[]] as $in |
    ($in | length) == 2 and
    ([$c.inbounds[] | select(.tag as $g | $in | index($g)) | .type] | sort) == ["direct", "mixed"])' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '.inbounds | length == 4 and all(.listen == "127.0.0.1")' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '[.inbounds[].listen_port, (.experimental.clash_api.external_controller | split(":")[1] | tonumber)] | (unique | length) == length' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '.inbounds | map(select(.type == "direct")) | all(.network == "udp" and .override_port == 53 and (.override_address | length > 0))' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '.route.rules | all(.action == "route")' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '.route.default_mark == 8228 and .route.auto_detect_interface == true' "$SING_BOX_CONFIG" >/dev/null &&
  jq -e '.dns == {"servers": [{"tag": "bootstrap", "type": "local"}], "final": "bootstrap", "strategy": "ipv4_only"}' "$SING_BOX_CONFIG" >/dev/null &&
  [[ "$tmp_before" == "$tmp_after" ]]; then
  ok
else
  fail "an exit lacks its own inbound pair, an inbound is off loopback or shares a port, the probe lost its mark, or it left a directory behind"
fi

# The real sing-box parses the inbounds and rules. check proves only that: a throwaway
# run of the same shape against a dummy outbound is in PITFALLS.md's company
world measure-config-passes-the-real-sing-box
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42' FAKE_CURL='HY2=0.2:5000000:1.2'
sv measure >/dev/null
real=$(type -ap sing-box | grep -v -x -F "$HERE/stub/sing-box" | head -n 1 || true)
if [[ -z "$real" ]]; then
  fail "no real sing-box on PATH after the stub"
elif err=$("$real" check -c "$SING_BOX_CONFIG" 2>&1); then
  ok
else
  fail "the real sing-box refused the measure probe: $err"
fi

# TTFB and throughput come from one request through the exit's mixed port; the speed
# is the bytes over the time after the first byte, so a slow first byte is not a slow link
world measure-textfile-carries-every-metric
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42,TROJAN-node=timeout'
export FAKE_CURL='HY2=0.2:5000000:1.2'
export FAKE_UDP='TROJAN-node=drop'
prom="$SKVPN_ROOT/out/skvpn.prom"
mkdir -p "$SKVPN_ROOT/out"
before=$(date +%s)
sv measure --textfile "$prom" >/dev/null
after=$(date +%s)
if near "$(metric "$prom" skvpn_exit_up HY2)" 1 &&
  near "$(metric "$prom" skvpn_tcp_latency_seconds HY2)" 0.042 &&
  near "$(metric "$prom" skvpn_tcp_ttfb_seconds HY2)" 0.2 &&
  near "$(metric "$prom" skvpn_tcp_download_bytes_per_second HY2)" 5000000 &&
  near "$(metric "$prom" skvpn_udp_up HY2)" 1 &&
  [[ -n "$(metric "$prom" skvpn_udp_rtt_seconds HY2)" ]] &&
  near "$(metric "$prom" skvpn_udp_loss_ratio HY2)" 0 &&
  near "$(metric "$prom" skvpn_exit_up TROJAN-node)" 0 &&
  near "$(metric "$prom" skvpn_udp_up TROJAN-node)" 0 &&
  near "$(metric "$prom" skvpn_udp_loss_ratio TROJAN-node)" 1 &&
  [[ -z "$(metric "$prom" skvpn_tcp_latency_seconds TROJAN-node)" ]] &&
  [[ -z "$(metric "$prom" skvpn_tcp_ttfb_seconds TROJAN-node)" ]] &&
  [[ -z "$(metric "$prom" skvpn_tcp_download_bytes_per_second TROJAN-node)" ]] &&
  [[ -z "$(metric "$prom" skvpn_udp_rtt_seconds TROJAN-node)" ]] &&
  [[ "$(metric "$prom" skvpn_measure_timestamp_seconds)" -ge "$before" && "$(metric "$prom" skvpn_measure_timestamp_seconds)" -le "$after" ]] &&
  [[ -n "$(metric "$prom" skvpn_measure_duration_seconds)" ]] &&
  grep -q '^# TYPE skvpn_exit_up gauge$' "$prom" && grep -q '^# HELP skvpn_udp_rtt_seconds ' "$prom"; then
  ok
else
  fail "a metric is missing, wrong, or present for an exit that could not produce it"
fi

# Only the profile name labels a sample: a node's address and credentials are what a
# profile keeps private, and a scrape lands on a dashboard
world measure-metrics-name-the-profile-only
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42' FAKE_CURL='HY2=0.2:5000000:1.2'
prom="$SKVPN_ROOT/skvpn.prom"
sv measure --textfile "$prom" >/dev/null
labels=$(grep -o '{[^}]*}' "$prom" | sort -u)
if [[ "$labels" == '{node="HY2"}' ]] && ! grep -qE 'node\.example\.com|obfspass|secret|salamander' "$prom"; then
  ok
else
  fail "a sample carries a label beyond the profile name, or a node detail"
fi

world measure-udp-loss-is-the-share-of-unanswered-queries
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42' FAKE_CURL='HY2=0.2:5000000:1.2' FAKE_UDP='HY2=half'
prom="$SKVPN_ROOT/skvpn.prom"
sv measure --textfile "$prom" >/dev/null
if near "$(metric "$prom" skvpn_udp_loss_ratio HY2)" 0.5 && near "$(metric "$prom" skvpn_udp_up HY2)" 1; then
  ok
else
  fail "half the queries went unanswered and the loss ratio is not one half"
fi

# A datagram that is not the answer to the query asked is no answer: the query sent back
# whole, or an answer under another id, may be a stale reply or a reflection
world measure-udp-counts-only-answers-to-its-own-query
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42,TROJAN-node=42' FAKE_CURL='HY2=0.2:5000000:1.2,TROJAN-node=0.2:5000000:1.2'
export FAKE_UDP='HY2=echo,TROJAN-node=wrongid'
prom="$SKVPN_ROOT/skvpn.prom"
sv measure --textfile "$prom" >/dev/null
if near "$(metric "$prom" skvpn_udp_loss_ratio HY2)" 1 && near "$(metric "$prom" skvpn_udp_up HY2)" 0 &&
  near "$(metric "$prom" skvpn_udp_loss_ratio TROJAN-node)" 1 && near "$(metric "$prom" skvpn_udp_up TROJAN-node)" 0; then
  ok
else
  fail "a reflected query or an answer under another id counted as an answer"
fi

# A download cut at the time limit with bytes in hand is still a measurement of the link
# (the limit is what bounds it); an error page is not a measurement of anything
world measure-counts-a-cut-download-and-not-an-error-page
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42,TROJAN-node=42'
export FAKE_CURL='HY2=partial,TROJAN-node=notfound'
prom="$SKVPN_ROOT/skvpn.prom"
sv measure --textfile "$prom" >/dev/null
# 3 000 000 bytes between the first byte at 0.2 s and the cut at 15 s
if near "$(metric "$prom" skvpn_tcp_download_bytes_per_second HY2)" "$(awk 'BEGIN { printf "%.9g", 3000000 / 14.8 }')" &&
  [[ -z "$(metric "$prom" skvpn_tcp_download_bytes_per_second TROJAN-node)" ]] &&
  [[ -z "$(metric "$prom" skvpn_tcp_ttfb_seconds TROJAN-node)" ]]; then
  ok
else
  fail "a cut download was dropped, or an error page was taken for a download"
fi

# Throughput is the one measurement that saturates the link, so two exits never share it
world measure-downloads-run-one-at-a-time
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42,TROJAN-node=42'
export FAKE_CURL='HY2=0.2:5000000:1.2,TROJAN-node=0.3:5000000:1.3'
sv measure >/dev/null
order=$(awk '{ print $1 }' "$CURL_LOG" | paste -sd' ' -)
if [[ "$order" == "start end start end" ]]; then
  ok
else
  fail "downloads overlapped or never ran: $order"
fi

# The request is curl through the exit's socks5h port, so the name is the exit's to
# resolve; the target is https, bounded in bytes and in time
world measure-request-is-bounded-and-https
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42' FAKE_CURL='HY2=0.2:5000000:1.2'
sv measure >/dev/null
request=$(grep '^start HY2 ' "$CURL_LOG")
if [[ "$request" == *"socks5h://127.0.0.1:"* && "$request" == *" https://"* &&
  "$request" == *"--max-time"* && "$request" == *"--range 0-"* && "$request" != *node.example.com* ]]; then
  ok
else
  fail "the download is not socks5h, https, and bounded: $request"
fi

world measure-set-stores-an-https-target-and-curl-gets-it
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42' FAKE_CURL='HY2=0.2:5000000:1.2'
url_file="$SKVPN_ROOT/etc/sing-box/measure.url"
sv measure set https://files.example.org/blob.bin >/dev/null
stored=$(<"$url_file")
sv measure >/dev/null
if [[ "$stored" == "https://files.example.org/blob.bin" ]] &&
  grep -q '^start HY2 .* https://files.example.org/blob.bin$' "$CURL_LOG" &&
  ! sv measure set 'http://x/f' >/dev/null 2>&1 &&
  ! sv measure set example.org >/dev/null 2>&1 &&
  ! sv measure set >/dev/null 2>&1; then
  ok
else
  fail "measure set stored the wrong target, or took one that is not an https url"
fi

# A reader of the textfile directory must never meet half a file, and a failed run must
# not wipe the last good one
world measure-textfile-is-written-atomically
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42' FAKE_CURL='HY2=0.2:5000000:1.2'
dir="$SKVPN_ROOT/collector"
mkdir -p "$dir"
printf 'stale\n' >"$dir/skvpn.prom"
inode_before=$(stat -c %i "$dir/skvpn.prom")
sv measure --textfile "$dir/skvpn.prom" >/dev/null
inode_after=$(stat -c %i "$dir/skvpn.prom")
fresh=$(<"$dir/skvpn.prom")
mode=$(stat -c %a "$dir/skvpn.prom")
leftovers=$(find "$dir" -type f ! -name skvpn.prom | wc -l)
printf 'last-good\n' >"$dir/skvpn.prom"
export SING_BOX_FAIL=1
if sv measure --textfile "$dir/skvpn.prom" >/dev/null 2>&1; then
  fail "measure exited 0 with a probe that refused its config"
elif [[ "$fresh" == *skvpn_exit_up* && "$mode" == 644 && "$leftovers" == 0 && "$inode_before" != "$inode_after" &&
  "$(<"$dir/skvpn.prom")" == last-good && "$(find "$dir" -type f | wc -l)" == 1 ]]; then
  ok
else
  fail "the textfile was not replaced whole, was left with a temp file, or a failed run damaged it"
fi

# A write that fails half way — here the target is a directory, so the rename cannot
# land — leaves the collector's directory as it was
world measure-textfile-failure-leaves-no-temporary-file
sv add "$HY2" >/dev/null
export FAKE_DELAYS='HY2=42' FAKE_CURL='HY2=0.2:5000000:1.2'
dir="$SKVPN_ROOT/collector"
mkdir -p "$dir/skvpn.prom"
if sv measure --textfile "$dir/skvpn.prom" >/dev/null 2>&1; then
  fail "measure exited 0 although the textfile could not be written"
elif [[ "$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l)" == 1 ]]; then
  ok
else
  fail "a failed write left a temporary file in the collector's directory"
fi

world measure-human-output-without-the-flag
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42,TROJAN-node=timeout' FAKE_CURL='HY2=0.2:5000000:1.2' FAKE_UDP='TROJAN-node=drop'
out=$(sv measure)
hy2_row=$(grep ' HY2 ' <<<"$out")
trojan_row=$(grep ' TROJAN-node ' <<<"$out")
if [[ "$hy2_row" == *"42 ms"* && "$hy2_row" == *"40.0 Mbit/s"* && "$hy2_row" == *"200 ms"* &&
  "$hy2_row" == *"0% loss"* && "$trojan_row" == *"timeout"* && "$trojan_row" == *"100% loss"* &&
  "$out" != *node.example.com* ]]; then
  ok
else
  fail "the table misses a measurement or shows a node address: $out"
fi

world measure-names-only-the-asked-profiles-and-refuses-a-bad-call
sv add "$HY2" "$TROJAN" >/dev/null
export FAKE_DELAYS='HY2=42' FAKE_CURL='HY2=0.2:5000000:1.2'
sv measure HY2 >/dev/null
only=$(jq -c '.outbounds | map(.tag)' "$SING_BOX_CONFIG")
rm -f "$SING_BOX_CONFIG"
if [[ "$only" == '["HY2"]' ]] &&
  ! sv measure nope >/dev/null 2>&1 && [[ ! -e $SING_BOX_CONFIG ]] &&
  ! sv measure --textfile "$SKVPN_ROOT/missing-dir/x.prom" >/dev/null 2>&1 &&
  ! sv measure --textfile >/dev/null 2>&1 &&
  [[ ! -e $SING_BOX_CONFIG ]]; then
  ok
else
  fail "measure probed more than it was asked for, or took a call it should refuse"
fi

# The timer runs this before any subscription is synced, and after the last profile goes:
# no exits is a measurement of nothing, not a failed unit — and it clears the old samples
world measure-textfile-with-no-profiles-is-an-empty-measurement
prom="$SKVPN_ROOT/skvpn.prom"
printf 'skvpn_exit_up{node="GONE"} 1\n' >"$prom"
if sv measure --textfile "$prom" >/dev/null 2>&1 && [[ ! -e $SING_BOX_CONFIG ]] &&
  ! grep -q 'node=' "$prom" && [[ -n "$(metric "$prom" skvpn_measure_timestamp_seconds)" ]] &&
  ! sv measure >/dev/null 2>&1; then
  ok
else
  fail "no profiles failed the textfile run, started a probe, kept a sample of a profile that is gone, or passed on the screen"
fi

world measure-reports-a-probe-that-refuses-to-start
sv add "$HY2" >/dev/null
export SING_BOX_FAIL=1
if out=$(sv measure 2>&1); then
  fail "measure exited 0 with a probe that refused its config"
elif [[ "$out" == *refused* ]]; then
  ok
else
  fail "measure hid why the probe did not start"
fi

echo "top"

# A live instance for `top` to read: the sing-box stub started from the config the module
# writes into base.d, a secret in it. clash_base_file PORT SECRET writes that file
clash_base_file() {
  mkdir -p "$SKVPN_ROOT/etc/sing-box/base.d"
  jq -n --arg controller "$1" --arg secret "$2" \
    '{experimental: {clash_api: {external_controller: $controller, secret: $secret}}}' \
    >"$SKVPN_ROOT/etc/sing-box/base.d/60-clash.json"
}
LIVE_PID=""
live_stop() {
  if [[ -n "$LIVE_PID" ]]; then
    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
    LIVE_PID=""
  fi
}
trap 'live_stop; rm -rf "$WORK"' EXIT
# live_start SECRET — the stub on a free port with that secret; sets LIVE_PORT
live_start() {
  LIVE_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  jq -n --arg controller "127.0.0.1:$LIVE_PORT" --arg secret "$1" \
    '{experimental: {clash_api: {external_controller: $controller, secret: $secret}}}' \
    >"$SKVPN_ROOT/live.json"
  SING_BOX_CONFIG="$SKVPN_ROOT/live-copy.json" sing-box -c "$SKVPN_ROOT/live.json" run >/dev/null 2>&1 &
  LIVE_PID=$!
  for _ in $(seq 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$LIVE_PORT") 2>/dev/null && return
    sleep 0.1
  done
  fail "the live stub never listened"
}

world top-prints-one-line-per-second-of-the-stream
export FAKE_TRAFFIC='1000:5000,2000:6000,3000:7000'
live_start s3cret
clash_base_file "127.0.0.1:$LIVE_PORT" s3cret
out=$(sv top --count 3 2>&1) || true
live_stop
if [[ "$(grep -c '^rx ' <<<"$out")" == 3 && "$out" == *"rx 6.0 kB/s"*"tx 2.0 kB/s"* ]]; then
  ok
else
  fail "top did not print the three samples as speeds: $out"
fi

world top-says-so-when-the-stream-ends
export FAKE_TRAFFIC='1000:5000'
live_start s3cret
clash_base_file "127.0.0.1:$LIVE_PORT" s3cret
if out=$(sv top 2>&1); then
  fail "top exited 0 after the stream ended"
elif [[ "$out" == *"stream"* ]]; then
  ok
else
  fail "top hid why it stopped: $out"
fi
live_stop

world top-sends-the-secret-and-reports-a-refusal
export FAKE_TRAFFIC='1000:5000'
live_start s3cret
clash_base_file "127.0.0.1:$LIVE_PORT" wrong
if out=$(sv top --count 1 2>&1); then
  fail "top exited 0 against an API that refused its secret"
elif [[ "$out" == *"401"* || "$out" == *"secret"* ]]; then
  ok
else
  fail "top did not say the API refused it: $out"
fi
live_stop

world top-without-a-clash-api-says-how-to-get-one
sv add "$HY2" >/dev/null
if out=$(sv top 2>&1); then
  fail "top exited 0 with nothing to read"
elif [[ "$out" == *"monitor"* ]]; then
  ok
else
  fail "top did not name the option that opens the API: $out"
fi

# The secret travels in a header: an API that is not on loopback would carry it off the
# machine, so a base that points elsewhere is refused before any connection
world top-refuses-a-non-loopback-api
clash_base_file "0.0.0.0:9097" s3cret
if out=$(sv top --count 1 2>&1); then
  fail "top exited 0 with an API off loopback"
elif [[ "$out" == *"loopback"* ]]; then
  ok
else
  fail "top did not say why it refused the address: $out"
fi

# The d key starts a download through the live tunnel, and the screen says the monitor
# counts it. Driven on a pty, since the interactive path only runs with a terminal
world top-download-key-measures-through-the-tunnel
export FAKE_TRAFFIC='1000:5000,2000:6000,3000:7000,4000:8000,5000:9000,6000:10000,7000:11000,8000:12000,9000:13000,1000:2000'
export FAKE_CURL='tunnel=0.1:10000000:2.1'
export FAKE_TRAFFIC_HOLD=1
live_start s3cret
clash_base_file "127.0.0.1:$LIVE_PORT" s3cret
out=$(
  python3 - "$SKVPN" <<'EOF'
import os
import pty
import re
import select
import subprocess
import sys
import time

master, slave = pty.openpty()
proc = subprocess.Popen([sys.executable, sys.argv[1], "top"], stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
seen = b""


def read_until(needle, seconds):
    global seen
    end = time.monotonic() + seconds
    while time.monotonic() < end and needle not in seen:
        if select.select([master], [], [], 0.2)[0]:
            try:
                seen += os.read(master, 65536)
            except OSError:
                return


read_until(b"rx", 5)
# The warning has to be on the screen before the key is pressed, not only after
before = seen
os.write(master, b"d")
read_until(b"Mbit/s", 8)
os.write(master, b"q")
try:
    code = proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    code = "hung"
text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", seen.decode(errors="replace"))
print(text)
print(f"warned={b'counts' in before}")
print(f"exit={code}")
EOF
)
live_stop
# No proxy of the tunnel's own, and none from the environment either: curl obeys
# http_proxy unless told not to, and that would send the download somewhere else
if [[ "$out" == *"warned=True"* && "$out" == *"40.0 Mbit/s"* && "$out" == *"exit=0"* ]] &&
  grep -q '^start tunnel .*--noproxy' "$CURL_LOG" && ! grep '^start tunnel ' "$CURL_LOG" | grep -q -- '--proxy\|-x '; then
  ok
else
  fail "the d key did not run a direct download, show its result and the warning, or q did not quit: $out"
fi

echo "subscription"

# file:// is a scheme urlopen speaks, which is what lets the sync logic run offline
sub_body() {
  printf '%s\n' "$@" >"$SKVPN_ROOT/subscription.txt"
  printf 'file://%s/subscription.txt' "$SKVPN_ROOT"
}

world sub-set-stores-and-syncs
url=$(sub_body "$HY2" "$TROJAN")
sv sub set "$url" >/dev/null
if [[ -e $(profile HY2) && -e $(profile TROJAN-node) &&
"$(stat -c %a "$SKVPN_ROOT/etc/sing-box/subscription.url")" == 600 ]]; then
  ok
else
  fail "sub set did not write both profiles and guard the url"
fi

world sync-stamp-carries-no-secret
url=$(sub_body "$HY2")
sv sub set "$url" >/dev/null
if [[ -e "$SKVPN_ROOT/var/lib/skvpn/last-sync" && ! -s "$SKVPN_ROOT/var/lib/skvpn/last-sync" ]]; then
  ok
else
  fail "the sync stamp is missing or holds the subscription url, which is a bearer secret"
fi

world sync-never-overwrites-a-handmade-profile
sv add "$TROJAN" >/dev/null
url=$(sub_body 'trojan://evil@evil.example.com?sni=evil.example.com#TROJAN-node' "$HY2")
sv sub set "$url" >/dev/null
if grep -q 'node.example.com' "$(profile TROJAN-node)" &&
  ! grep -q 'evil' "$(profile TROJAN-node)"; then
  ok
else
  fail "a subscription entry replaced the node behind a hand-added name"
fi

world sync-prunes-what-the-subscription-dropped
url=$(sub_body "$HY2" "$TROJAN")
sv sub set "$url" >/dev/null
sub_body "$HY2" >/dev/null
sv sub sync >/dev/null
if [[ -e $(profile HY2) && ! -e $(profile TROJAN-node) ]]; then
  ok
else
  fail "a profile the subscription dropped survived the sync"
fi

world sync-spares-the-running-profile
url=$(sub_body "$HY2" "$TROJAN")
sv sub set "$url" >/dev/null
sub_body "$HY2" >/dev/null
FAKE_ACTIVE='TROJAN-node'
export FAKE_ACTIVE
sv sub sync >/dev/null
if [[ -e $(profile TROJAN-node) ]] &&
  grep -q TROJAN-node "$SKVPN_ROOT/etc/sing-box/subscription.profiles"; then
  ok
else
  fail "the running profile was pruned, or fell out of the manifest"
fi

world sync-leaves-handmade-profiles-alone
url=$(sub_body "$HY2")
sv add "$TROJAN" >/dev/null
sv sub set "$url" >/dev/null
sv sub sync >/dev/null
if [[ -e $(profile TROJAN-node) ]]; then
  ok
else
  fail "a profile added by hand was pruned as if it came from the subscription"
fi

world sub-set-over-handmade-copies-stays-green
sv add "$TROJAN" >/dev/null
url=$(sub_body "$TROJAN")
if sv sub set "$url" >/dev/null 2>&1 && sv sub sync >/dev/null 2>&1; then
  # Migration to a subscription of the very same nodes must not turn the daily sync red
  ok
else
  fail "a subscription whose every node is already hand-added made sync fail forever"
fi

world rm-hands-the-name-back-to-the-user
url=$(sub_body "$HY2" "$TROJAN")
sv sub set "$url" >/dev/null
sv rm HY2 >/dev/null
sv add 'hysteria2://mine@my.example.com:443?sni=my.example.com#HY2' >/dev/null
sub_body "$HY2" "$TROJAN" >/dev/null
sv sub sync >/dev/null
if grep -q 'my.example.com' "$(profile HY2)"; then
  ok
else
  fail "the manifest still claimed a deleted name, and the sync took the profile back"
fi

world sync-without-a-subscription-dies
if sv sub sync >/dev/null 2>&1; then
  fail "sync without a stored subscription exited 0"
elif sv sub sync --if-stale >/dev/null 2>&1; then
  # The timer runs this before any subscription is stored; that is not a failure
  ok
else
  fail "--if-stale failed where the timer calls it on a fresh machine"
fi

world up-refuses-a-profile-the-sync-just-dropped
url=$(sub_body "$HY2" "$TROJAN")
sv sub set "$url" >/dev/null
sub_body "$HY2" >/dev/null
touch -d '25 hours ago' "$SKVPN_ROOT/var/lib/skvpn/last-sync"
if sv up TROJAN-node >/dev/null 2>&1 ||
  grep -q 'start sing-box@TROJAN-node.service' "$SYSTEMCTL_LOG" ||
  [[ -e $(active_file) ]]; then
  fail "up started a unit for a profile its own sync had just pruned"
else
  ok
fi

world up-survives-a-dead-subscription
url=$(sub_body "$HY2")
sv sub set "$url" >/dev/null
rm "$SKVPN_ROOT/subscription.txt"
touch -d '25 hours ago' "$SKVPN_ROOT/var/lib/skvpn/last-sync"
if sv up HY2 >/dev/null 2>&1 && grep -q 'start sing-box@HY2.service' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "an unreachable subscription blocked the switch — the one moment it matters most"
fi

world ls-names-a-broken-profile-instead-of-crashing
sv add "$HY2" >/dev/null
printf '{"outb' >"$(profile broken)"
printf 'null\n' >"$(profile wrong-shape)"
if [[ "$(sv ls 2>/dev/null | grep -c 'broken profile')" == 2 ]]; then
  ok
else
  fail "a truncated or wrong-shaped profile file crashed ls"
fi

echo "cli"

world installer-leaves-host-policy-alone-by-default
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" >/dev/null
dropin="$SKVPN_ROOT/stage/etc/systemd/system/sing-box@.service.d/skvpn.conf"
if grep -qx 'AmbientCapabilities=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH' "$dropin" &&
  [[ -x "$SKVPN_ROOT/stage/usr/local/bin/skvpn" &&
    -e "$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json" &&
    -e "$SKVPN_ROOT/stage/etc/systemd/system/skvpn-restore.service" &&
    -e "$SKVPN_ROOT/stage/etc/systemd/system/skvpn-sync.timer" &&
    ! -e "$SKVPN_ROOT/stage/etc/sysctl.d/90-skvpn.conf" ]]; then
  ok
else
  fail "the default install missed the CLI or invented host policy"
fi

world installer-can-fix-discord-voice
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --fix-discord-voice >/dev/null
if [[ "$(cat "$SKVPN_ROOT/stage/etc/sysctl.d/90-skvpn.conf")" == *"net.ipv4.conf.all.rp_filter = 2"* ]]; then
  ok
else
  fail "--fix-discord-voice did not install loose reverse-path filtering"
fi

world installer-renders-non-nix-options
printf '{"log":{"level":"debug"}}\n' >"$SKVPN_ROOT/extra.json"
"$REPO/install.sh" \
  --destdir "$SKVPN_ROOT/stage" \
  --tailscale \
  --direct-russia \
  --direct-zone .by \
  --direct-geosite geosite-ru=/rules/site.srs \
  --direct-geoip custom-ip=/rules/ip.srs \
  --tun-interface friend-tun \
  --tun-address 10.42.0.1/30 \
  --dns-server 9.9.9.9 \
  --stack gvisor \
  --split firefox \
  --split path /usr/bin/steam \
  --split ip 10.0.0.0/8 \
  --split name ip \
  --split domain 'https://Example.com/x' \
  --extra-settings "$SKVPN_ROOT/extra.json" \
  --no-restore \
  --sync-interval weekly \
  --trusted-user alice >/dev/null
base="$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json"
if jq -e '
	.inbounds[0].interface_name == "friend-tun" and
	.inbounds[0].address == ["10.42.0.1/30"] and
	.inbounds[0].stack == "gvisor" and
	(.inbounds[0].route_exclude_address | length == 2)
' "$base" >/dev/null &&
  jq -e '.dns.servers[1].server == "9.9.9.9"' "$base" >/dev/null &&
  jq -e '.route.rules | any(.domain_suffix? | index(".ru"))' "$base" >/dev/null &&
  jq -e '.route.rules | any(.domain_suffix? | index("example.com"))' "$base" >/dev/null &&
  jq -e '.dns.rules | any(.domain_suffix? | index("example.com"))' "$base" >/dev/null &&
  jq -e '.route.rules[-3] == {"process_name": ["firefox", "ip"], "outbound": "direct"}' "$base" >/dev/null &&
  jq -e '.route.rules[-2] == {"process_path": ["/usr/bin/steam"], "outbound": "direct"}' "$base" >/dev/null &&
  jq -e '.route.rules[-1] == {"ip_cidr": ["10.0.0.0/8"], "outbound": "direct"}' "$base" >/dev/null &&
  jq -e '.dns.rules[-2] == {"process_name": ["firefox", "ip"], "action": "route", "server": "bootstrap"}' "$base" >/dev/null &&
  jq -e '.dns.rules[-1] == {"process_path": ["/usr/bin/steam"], "action": "route", "server": "bootstrap"}' "$base" >/dev/null &&
  jq -e '.dns.rules | all(.action == "route")' "$base" >/dev/null &&
  jq -e '.route.rule_set | map(.tag) | sort == ["custom-ip", "geoip-ru", "geosite-ru"]' "$base" >/dev/null &&
  jq -e '.route.rule_set | map(select(.tag == "geosite-ru"))[0].path == "/rules/site.srs"' "$base" >/dev/null &&
  grep -q '^OnCalendar=weekly$' "$SKVPN_ROOT/stage/etc/systemd/system/skvpn-sync.timer" &&
  [[ ! -e "$SKVPN_ROOT/stage/etc/systemd/system/skvpn-restore.service" &&
    -e "$SKVPN_ROOT/stage/etc/sing-box/base.d/50-extra.json" &&
    -e "$SKVPN_ROOT/stage/etc/sudoers.d/skvpn" ]]; then
  ok
else
  fail "non-Nix options did not reach their config, unit, or policy files"
fi

# The same policy as the NixOS option: the sniffed protocol direct, and the clients joining
# the split names under both their own name and the one a Nix wrapper runs as
world installer-routes-bittorrent-direct
base="$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json"
if "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --direct-bittorrent --split firefox >/dev/null 2>&1 &&
  jq -e '.route.rules | map(select(.protocol == ["bittorrent"])) == [{"protocol": ["bittorrent"], "outbound": "direct"}]' "$base" >/dev/null &&
  jq -e --slurpfile p "$REPO/policy.json" '
	(["firefox"] + [$p[0].bittorrent.clients[] | ., ".\(.)-wrapped"]) as $want |
	[.route.rules[], .dns.rules[] | select(has("process_name")) | .process_name] |
	length == 2 and all(. as $names | $want - $names == [])
' "$base" >/dev/null; then
  ok
else
  fail "--direct-bittorrent did not route the protocol and every client direct"
fi

# The TUN's v6 address is the one default a host without IPv6 has to be able to drop, and
# --tun-address is not that lever: it replaces the pair rather than trimming it
world installer-drops-the-tun-ipv6-address
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --no-ipv6 >/dev/null
base="$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json"
if jq -e '.inbounds[0].address == ["172.19.0.1/30"] and .inbounds[0].stack == "system"' \
  "$base" >/dev/null &&
  jq -e '.route.rules | length == 3' "$base" >/dev/null &&
  jq -e '.dns.reverse_mapping == true' "$base" >/dev/null; then
  ok
else
  fail "--no-ipv6 left the TUN a v6 address, the default stack drifted, or a rule came from nowhere"
fi

# The same default resolver as the NixOS option: one that sends no client subnet
world installer-defaults-to-cloudflare-dns
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" >/dev/null
if jq -e '.dns.servers | map(select(.tag == "remote"))[0].server == "1.1.1.1"' \
  "$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json" >/dev/null; then
  ok
else
  fail "a bare install does not resolve through Cloudflare"
fi

world installer-rejects-bad-split-values
rc=0
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split ip not-an-ip >/dev/null 2>&1 || rc=$?
if ((rc != 2)); then
  fail "--split ip not-an-ip exited $rc, not the usage-error code 2"
else
  rc=0
  "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split path relative/bin >/dev/null 2>&1 || rc=$?
  if ((rc != 2)); then
    fail "--split path relative/bin exited $rc, not the usage-error code 2"
  else
    rc=0
    "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split >/dev/null 2>&1 || rc=$?
    if ((rc == 2)) && [[ ! -e "$SKVPN_ROOT/stage/usr/local/bin/skvpn" ]]; then
      ok
    else
      fail "a bare --split exited $rc, not the usage-error code 2, or left a partial installation"
    fi
  fi
fi

# An unknown flag, a relative directory, a value flag given no value, and --uninstall
# combined with a configuration flag are all requests that were simply malformed, so
# every one of them answers 2 through install.sh's own die() — never 1, the family's
# finding-printed code
world installer-refuses-bad-arguments-with-exit-2
rc=0
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --no-such-flag >/dev/null 2>&1 || rc=$?
if ((rc != 2)); then
  fail "an unknown flag exited $rc, not the usage-error code 2"
else
  rc=0
  "$REPO/install.sh" --prefix relative/path >/dev/null 2>&1 || rc=$?
  if ((rc != 2)); then
    fail "a relative --prefix exited $rc, not the usage-error code 2"
  else
    rc=0
    "$REPO/install.sh" --destdir >/dev/null 2>&1 || rc=$?
    if ((rc != 2)); then
      fail "--destdir with no value exited $rc, not the usage-error code 2"
    else
      rc=0
      "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --uninstall --fix-discord-voice >/dev/null 2>&1 || rc=$?
      if ((rc != 2)); then
        fail "--uninstall combined with --fix-discord-voice exited $rc, not the usage-error code 2"
      else
        rc=0
        "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --uninstall --tailscale >/dev/null 2>&1 || rc=$?
        if ((rc == 2)); then
          ok
        else
          fail "--uninstall combined with --tailscale exited $rc, not the usage-error code 2"
        fi
      fi
    fi
  fi
fi

world installer-help-lists-every-feature
help=$("$REPO/install.sh" --help)
missing=""
for option in help version prefix destdir uninstall no-systemd tailscale docker syncthing \
  guard-ai guard-zone guard-geosite direct-russia direct-china direct-iran direct-bittorrent direct-zone direct-geosite \
  direct-geoip split tun-interface tun-address dns-server extra-settings no-restore sync-interval \
  trusted-user fix-discord-voice stack no-ipv6 tor tor-socks-port; do
  [[ "$help" == *"--$option"* ]] || missing+=" $option"
done
if [[ -z "$missing" ]]; then
  ok
else
  fail "installer help omits:$missing"
fi

world installer-prints-its-version
want="skvpn $(cat "$REPO/VERSION")"
if [[ "$("$REPO/install.sh" --version)" == "$want" && "$("$REPO/install.sh" -v)" == "$want" ]]; then
  ok
else
  fail "--version does not answer with the VERSION file's number"
fi

world installer-reports-all-missing-dependencies
printf 'ID=ubuntu\nID_LIKE=debian\n' >"$SKVPN_ROOT/os-release"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$SKVPN_ROOT/missing-sing-box"
  "NFT=$SKVPN_ROOT/missing-nft"
  "SERVICE_USER=missing-sing-box-user"
  "OS_RELEASE=$SKVPN_ROOT/os-release"
  "SYSTEMCTL_FAIL=cat sing-box@.service"
)
# The guidance lines are matched whole (grep -qxF): the harness that runs them in the
# distro tests extracts exactly these, so a substring match here could bless a line
# nobody can actually type
rc=0
out=$(env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" 2>&1) || rc=$?
if ((rc == 0)); then
  fail "installation continued with missing runtime dependencies"
elif ((rc != 1)); then
  fail "the preflight exited $rc, not the missing-dependency code 1"
elif [[ "$out" == *"sing-box ($SKVPN_ROOT/missing-sing-box)"* &&
  "$out" == *"sing-box@.service"* &&
  "$out" == *"sing-box service user (missing-sing-box-user)"* &&
  "$out" == *"official APT repository"* ]] &&
  grep -qxF '  $ sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc' <<<"$out" &&
  grep -qxF '  $ sudo apt-get install sing-box' <<<"$out" &&
  [[ "$out" == *"nft ($SKVPN_ROOT/missing-nft)"* ]] &&
  grep -qxF '  $ sudo apt-get install nftables' <<<"$out" &&
  [[ ! -e "$SKVPN_ROOT/usr/bin/skvpn" ]]; then
  ok
else
  fail "dependency preflight did not aggregate failures or show the Ubuntu guidance"
fi

world installer-gives-arch-package-command
printf 'ID=cachyos\nID_LIKE=arch\n' >"$SKVPN_ROOT/os-release"
rc=0
out=$(OS_RELEASE="$SKVPN_ROOT/os-release" SING_BOX="$SKVPN_ROOT/missing" \
  "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" 2>&1) || rc=$?
if ((rc == 0)); then
  fail "installation continued without sing-box on CachyOS"
elif ((rc != 1)); then
  fail "the preflight exited $rc, not the missing-dependency code 1"
elif grep -qxF '  $ sudo pacman -S --needed sing-box' <<<"$out"; then
  ok
else
  fail "the CachyOS preflight did not print the package command"
fi

world installer-rejects-non-object-extra-settings
printf '[]\n' >"$SKVPN_ROOT/extra.json"
if "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --extra-settings "$SKVPN_ROOT/extra.json" >/dev/null 2>&1; then
  fail "an array was accepted as sing-box extra settings"
elif [[ ! -e "$SKVPN_ROOT/stage/usr/local/bin/skvpn" ]]; then
  ok
else
  fail "invalid extra settings left a partial installation"
fi

world installer-refuses-unmanaged-config
mkdir -p "$SKVPN_ROOT/etc/sing-box/base.d"
printf 'mine\n' >"$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
)
if env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" >/dev/null 2>&1; then
  fail "the installer overwrote a config it did not own"
elif [[ "$(<"$SKVPN_ROOT/etc/sing-box/base.d/00-base.json")" == mine ]]; then
  ok
else
  fail "an unmanaged config changed before the installer refused it"
fi

# The single flag is declarative: a run without it converges the system back, the way
# unsetting the NixOS option does on rebuild — there is no --no-fix-discord-voice
world discord-voice-fix-is-idempotent-and-reversible
export SYSCTL_STATE="$SKVPN_ROOT/rp-filter"
printf '1\n' >"$SYSCTL_STATE"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
)
install_args=(
  --prefix "$SKVPN_ROOT/usr"
  --fix-discord-voice
)
env "${installer_env[@]}" "$REPO/install.sh" "${install_args[@]}" >/dev/null
env "${installer_env[@]}" "$REPO/install.sh" "${install_args[@]}" >/dev/null
saved="$SKVPN_ROOT/var/lib/skvpn/install-state/rp-filter-before-discord-voice"
env "${installer_env[@]}" \
  "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" >/dev/null
if [[ "$(<"$SYSCTL_STATE")" == 1 && ! -e "$saved" &&
! -e "$SKVPN_ROOT/etc/sysctl.d/90-skvpn.conf" ]]; then
  ok
else
  fail "a repeated install lost the old rp_filter value, or a flagless run did not restore it"
fi

world uninstall-removes-every-installed-file
export SYSCTL_STATE="$SKVPN_ROOT/rp-filter"
printf '0\n' >"$SYSCTL_STATE"
common_args=(
  --prefix "$SKVPN_ROOT/usr"
)
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
)
env "${installer_env[@]}" "$REPO/install.sh" "${common_args[@]}" --fix-discord-voice >/dev/null
manifest="$SKVPN_ROOT/usr/share/skvpn/install-manifest"
manifest_complete=1
if [[ ! -f "$manifest" ]]; then
  manifest_complete=0
else
  # Every path the manifest names must exist before the uninstall and be gone after it —
  # a manifest that names nothing would pass a bare existence check
  while IFS= read -r path; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    [[ -e "$path" ]] || manifest_complete=0
  done <"$manifest"
fi
mapfile -t manifest_paths < <(grep -v '^#' "$manifest" 2>/dev/null || true)
env "${installer_env[@]}" "$REPO/install.sh" "${common_args[@]}" --uninstall >/dev/null
env "${installer_env[@]}" "$REPO/install.sh" "${common_args[@]}" --uninstall >/dev/null
leftover=""
for path in "${manifest_paths[@]}"; do
  [[ ! -e "$path" ]] || leftover+=" $path"
done
if [[ "$(<"$SYSCTL_STATE")" == 0 && "$manifest_complete" == 1 &&
"${#manifest_paths[@]}" -ge 8 && -z "$leftover" &&
! -e "$manifest" && ! -e "$SKVPN_ROOT/usr/bin/skvpn" &&
! -e "$SKVPN_ROOT/etc/sing-box/base.d/00-base.json" &&
! -e "$SKVPN_ROOT/systemd/sing-box@.service.d/skvpn.conf" &&
! -e "$SKVPN_ROOT/systemd/skvpn-restore.service" &&
! -e "$SKVPN_ROOT/systemd/skvpn-sync.service" &&
! -e "$SKVPN_ROOT/systemd/skvpn-sync.timer" &&
! -e "$SKVPN_ROOT/etc/sysctl.d/90-skvpn.conf" ]]; then
  ok
else
  fail "uninstall did not consume the manifest, restore policy, or repeat quietly"
fi

# An install with no manifest is one older than 1.1: the fixed-list fallback that used
# to guess its files is gone, so it is named and left alone — before anything else is
# touched, so the refusal stops no unit and restores no sysctl
world uninstall-refuses-an-install-without-a-manifest
export SYSCTL_STATE="$SKVPN_ROOT/rp-filter"
printf '0\n' >"$SYSCTL_STATE"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
)
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --fix-discord-voice >/dev/null
rm -rf "$SKVPN_ROOT/usr/share/skvpn"
: >"$SYSTEMCTL_LOG"
if out=$(env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --uninstall 2>&1); then
  fail "an install without a manifest was uninstalled by guesswork"
elif [[ "$out" == *"older than 1.1"* && -e "$SKVPN_ROOT/usr/bin/skvpn" &&
  -e "$SKVPN_ROOT/etc/sing-box/base.d/00-base.json" &&
  "$(<"$SYSCTL_STATE")" == 2 && -z "$(<"$SYSTEMCTL_LOG")" ]]; then
  ok
else
  fail "the refusal did not name the cause, or touched the system before refusing"
fi

world installer-renders-docker-exclusion
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --docker >/dev/null
base="$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json"
"$REPO/install.sh" --destdir "$SKVPN_ROOT/bare-stage" >/dev/null
bare_base="$SKVPN_ROOT/bare-stage/etc/sing-box/base.d/00-base.json"
if jq -e '.inbounds[0].exclude_interface == ["docker0"]' "$base" >/dev/null &&
  jq -e '.inbounds[0] | has("exclude_interface") | not' "$bare_base" >/dev/null; then
  ok
else
  fail "--docker did not reach exclude_interface, or a bare render carries it"
fi

# The rules themselves live in nft-bypass.sh; the installer only picks its flags, and the
# reply rule needs none, so even a bare install runs the script
world installer-wires-the-bypass-rules
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --tailscale --docker --syncthing >/dev/null
"$REPO/install.sh" --destdir "$SKVPN_ROOT/bare-stage" >/dev/null
dropin="$SKVPN_ROOT/stage/etc/systemd/system/sing-box@.service.d/skvpn.conf"
bare_dropin="$SKVPN_ROOT/bare-stage/etc/systemd/system/sing-box@.service.d/skvpn.conf"
if grep -qx 'ExecStartPost=/usr/local/lib/skvpn/nft-bypass apply --tailscale --docker --syncthing' "$dropin" &&
  grep -qx 'Environment=NFT=/usr/sbin/nft' "$dropin" &&
  grep -qx 'ExecStartPost=/usr/local/lib/skvpn/nft-bypass apply' "$bare_dropin" &&
  [[ -x "$SKVPN_ROOT/stage/usr/local/lib/skvpn/nft-bypass" ]] &&
  grep -qx '/usr/local/lib/skvpn/nft-bypass' "$SKVPN_ROOT/stage/usr/local/share/skvpn/install-manifest"; then
  ok
else
  fail "the bypass script is missing, unrecorded, or the unit runs it with the wrong flags"
fi

# The hold takes the bypass flags wherever it is set: after a crash, and by the CLI's unit
world installer-wires-the-hold
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --tailscale --syncthing --guard-zone .example.com >/dev/null
dropin="$SKVPN_ROOT/stage/etc/systemd/system/sing-box@.service.d/skvpn.conf"
nft_unit="$SKVPN_ROOT/stage/etc/systemd/system/skvpn-nft@.service"
if grep -qx 'ExecStopPost=/usr/local/lib/skvpn/nft-bypass hold --if-failed --tailscale --syncthing' "$dropin" &&
  grep -qx 'ExecStopPost=/usr/local/lib/skvpn/nft-bypass hold --if-failed --tailscale --syncthing' \
    "$SKVPN_ROOT/stage/etc/systemd/system/skvpn-guard.service" &&
  grep -qx 'ExecStart=/usr/local/lib/skvpn/nft-bypass %i --tailscale --syncthing' "$nft_unit" &&
  grep -qx 'Type=oneshot' "$nft_unit" &&
  grep -qx 'Environment=NFT=/usr/sbin/nft' "$nft_unit" &&
  grep -qx '/etc/systemd/system/skvpn-nft@.service' "$SKVPN_ROOT/stage/usr/local/share/skvpn/install-manifest"; then
  ok
else
  fail "a crash or the CLI cannot hold the network, or holds it without the bypass flags"
fi

guard_stage() { printf '%s/stage/etc/%s' "$SKVPN_ROOT" "$1"; }

# The same guard nix/module.nix renders: every source refused in DNS and in routing, `proxy`
# made direct, the remaining names to the bootstrap
world installer-renders-the-guard
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --guard-ai --guard-zone .example.com \
  --guard-geosite geosite-test=/rules/test.srs --tun-interface friend-tun --tailscale >/dev/null
guard="$(guard_stage sing-box/guard.json)"
unit="$(guard_stage systemd/system/skvpn-guard.service)"
if jq -e --slurpfile p "$REPO/policy.json" '.dns.rules == [
    {"domain_suffix": [".example.com"], "action": "predefined", "rcode": "REFUSED"},
    {"rule_set": ["geosite-\($p[0].guard.tag)", "geosite-test"], "action": "predefined", "rcode": "REFUSED"},
    {"action": "route", "server": "bootstrap"}
  ]' "$guard" >/dev/null &&
  jq -e --slurpfile p "$REPO/policy.json" '.route.rules == [
    {"domain_suffix": [".example.com"], "action": "reject"},
    {"rule_set": ["geosite-\($p[0].guard.tag)", "geosite-test"], "action": "reject"}
  ]' "$guard" >/dev/null &&
  jq -e '.outbounds == [{"type": "direct", "tag": "proxy", "domain_resolver": "bootstrap"}]' "$guard" >/dev/null &&
  jq -e --slurpfile p "$REPO/policy.json" '.route.rule_set[0].path == "/usr/share/sing-box/rule-set/\($p[0].guard.geosite)"' "$guard" >/dev/null &&
  grep -qx 'ConditionPathExists=!/sys/class/net/friend-tun' "$unit" &&
  grep -qx 'ExecStart=/usr/bin/sing-box -D /var/lib/skvpn-guard -C /etc/sing-box/base.d -c /etc/sing-box/guard.json run' "$unit" &&
  grep -qx 'ExecStartPost=/usr/local/lib/skvpn/nft-bypass apply --tailscale' "$unit" &&
  grep -qx 'AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH' "$unit"; then
  ok
else
  fail "the installer's guard drifted from the module's, or its unit cannot run it"
fi

# Declarative: a run without the guard flags takes the guard away, the way unsetting the
# NixOS options does
world installer-drops-the-guard-without-its-flags
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --guard-zone .example.com >/dev/null
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" >/dev/null
if [[ ! -e "$(guard_stage sing-box/guard.json)" && ! -e "$(guard_stage systemd/system/skvpn-guard.service)" ]] &&
  ! grep -q guard "$SKVPN_ROOT/stage/usr/local/share/skvpn/install-manifest"; then
  ok
else
  fail "a flagless run left the guard behind"
fi

# Boot wants the guard only when nothing restores, since restore starts it itself
world installer-enables-the-guard-only-without-restore
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
  "RESTART_SETTLE_TICKS=0"
)
# Whole lines: "disable skvpn-guard.service" contains "enable skvpn-guard.service"
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --guard-zone .example.com >/dev/null
mv "$SYSTEMCTL_LOG" "$SKVPN_ROOT/with-restore.log"
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --guard-zone .example.com --no-restore >/dev/null
mv "$SYSTEMCTL_LOG" "$SKVPN_ROOT/without-restore.log"
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --uninstall >/dev/null
if grep -qx 'disable skvpn-guard.service' "$SKVPN_ROOT/with-restore.log" &&
  ! grep -qx 'enable skvpn-guard.service' "$SKVPN_ROOT/with-restore.log" &&
  grep -qx 'enable skvpn-guard.service' "$SKVPN_ROOT/without-restore.log" &&
  grep -qx 'disable skvpn-guard.service' "$SYSTEMCTL_LOG" &&
  [[ ! -e "$SKVPN_ROOT/systemd/skvpn-guard.service" && ! -e "$SKVPN_ROOT/usr/lib/skvpn" ]]; then
  ok
else
  fail "boot wants the guard beside restore, misses it without, or uninstall leaves it"
fi

# A transport plugin is any executable of that name on PATH; these do nothing
fake_plugins() {
  mkdir -p "$SKVPN_ROOT/plugins"
  for plugin in "$@"; do
    printf '#!/bin/sh\n' >"$SKVPN_ROOT/plugins/$plugin"
    chmod +x "$SKVPN_ROOT/plugins/$plugin"
  done
}

# The same pair the module renders, and one plugin line per binary found: lyrebird runs
# every transport, so nothing older is run beside it
world installer-renders-tor-from-the-plugins-found
fake_plugins obfs4proxy snowflake-client
PATH="$SKVPN_ROOT/plugins:$PATH" "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --tor --tor-socks-port 19050 >/dev/null
torrc="$(guard_stage sing-box/torrc)"
plugins=$(grep '^ClientTransportPlugin' "$torrc" 2>/dev/null || true)
fake_plugins lyrebird
PATH="$SKVPN_ROOT/plugins:$PATH" "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --tor >/dev/null
with_lyrebird=$(grep '^ClientTransportPlugin' "$torrc" 2>/dev/null || true)
unit="$(guard_stage systemd/system/skvpn-tor.service)"
user=$(tor_policy user)
if [[ "$plugins" == "ClientTransportPlugin obfs4 exec $SKVPN_ROOT/plugins/obfs4proxy"$'\n'"ClientTransportPlugin snowflake exec $SKVPN_ROOT/plugins/snowflake-client" &&
  "$with_lyrebird" == "ClientTransportPlugin obfs4,webtunnel,snowflake exec $SKVPN_ROOT/plugins/lyrebird" ]] &&
  grep -qx 'DataDirectory /var/lib/skvpn-tor' "$torrc" &&
  grep -qx '%include /var/lib/skvpn/tor-bridges.conf' "$torrc" &&
  jq -e --slurpfile want <(python3 "$REPO/non-nix/render-base.py" --skip-path-check --tor \
    --tor-plugin obfs4=/x --render tor) '. == $want[0]' "$(guard_stage sing-box/tor.json)" >/dev/null &&
  jq -e --arg o "$(tor_policy onion)" '.route.rules | any(.domain_suffix == [$o] and .outbound == "tor")' \
    "$(guard_stage sing-box/base.d/00-base.json)" >/dev/null &&
  grep -qx 'ExecStart=/usr/bin/tor -f /etc/sing-box/torrc' "$unit" &&
  grep -qx "User=$user" "$unit" &&
  grep -qx 'ConditionPathExists=/var/lib/skvpn/tor-bridges.conf' "$unit" &&
  grep -qx 'nameserver 172.19.0.2' "$(guard_stage sing-box/tor-resolv.conf)" &&
  grep -q '/tor-resolv\.conf$' "$SKVPN_ROOT/stage/usr/local/share/skvpn/install-manifest" &&
  grep -q '/tor-nsswitch\.conf$' "$SKVPN_ROOT/stage/usr/local/share/skvpn/install-manifest" &&
  grep -qx "u $user - \"skvpn Tor\"" "$(guard_stage sysusers.d/skvpn-tor.conf)" &&
  grep -q 'skvpn-tor.service' "$SKVPN_ROOT/stage/usr/local/share/skvpn/install-manifest"; then
  ok
else
  fail "the installer's Tor drifted from the renderer's, ran a transport twice, or cannot start"
fi

world installer-drops-tor-without-its-flag
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --tor >/dev/null
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" >/dev/null
if [[ ! -e "$(guard_stage sing-box/tor.json)" && ! -e "$(guard_stage sing-box/torrc)" &&
! -e "$(guard_stage sing-box/tor-resolv.conf)" && ! -e "$(guard_stage sing-box/tor-nsswitch.conf)" &&
! -e "$(guard_stage systemd/system/skvpn-tor.service)" && ! -e "$(guard_stage sysusers.d/skvpn-tor.conf)" ]] &&
  ! grep -qE 'skvpn-tor|/torrc$|/tor\.json$' "$SKVPN_ROOT/stage/usr/local/share/skvpn/install-manifest" &&
  jq -e '.outbounds | all(.tag != "tor")' "$(guard_stage sing-box/base.d/00-base.json)" >/dev/null; then
  ok
else
  fail "a run without --tor left Tor behind"
fi

world installer-refuses-tor-options-alone
rc=0
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --tor-socks-port 9150 >/dev/null 2>&1 || rc=$?
rc_uninstall=0
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --uninstall --tor >/dev/null 2>&1 || rc_uninstall=$?
rc_port=0
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --tor --tor-socks-port 70000 >/dev/null 2>&1 || rc_port=$?
if ((rc == 2 && rc_uninstall == 2 && rc_port == 2)); then
  ok
else
  fail "a Tor option without --tor, beside --uninstall or out of range did not exit 2: $rc $rc_uninstall $rc_port"
fi

# Tor and every transport missing: named, and each distribution's guidance printed whole
world installer-reports-a-missing-tor
printf 'ID=ubuntu\nID_LIKE=debian\n' >"$SKVPN_ROOT/os-release-ID=ubuntu"
printf 'ID=fedora\n' >"$SKVPN_ROOT/os-release-ID=fedora"
printf 'ID=arch\n' >"$SKVPN_ROOT/os-release-ID=arch"
tor_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "TOR_BIN=$SKVPN_ROOT/missing-tor"
)
outs=()
for distro in ID=ubuntu ID=fedora ID=arch; do
  rc=0
  outs+=("$(env "${tor_env[@]}" "OS_RELEASE=$SKVPN_ROOT/os-release-$distro" "$REPO/install.sh" \
    --prefix "$SKVPN_ROOT/usr" --no-systemd --tor 2>&1)") || rc=$?
  ((rc == 1)) || outs[-1]="exit $rc"
done
if [[ "${outs[0]}" == *"tor ($SKVPN_ROOT/missing-tor)"* && "${outs[0]}" == *"a Tor transport plugin"* ]] &&
  grep -qxF '  $ sudo apt-get install tor obfs4proxy snowflake-client' <<<"${outs[0]}" &&
  grep -qxF '  $ sudo dnf install tor obfs4' <<<"${outs[1]}" &&
  grep -qxF '  $ sudo pacman -S --needed tor' <<<"${outs[2]}" && [[ "${outs[2]}" == *lyrebird-proxy* ]] &&
  [[ ! -e "$SKVPN_ROOT/usr/bin/skvpn" ]]; then
  ok
else
  fail "the preflight let a missing Tor through, or lost a distribution's guidance: ${outs[*]}"
fi

# Live: the user is made, the unit enabled and a running Tor restarted onto the new torrc;
# uninstall stops it and leaves nothing of it behind
world installer-enables-tor-and-uninstall-stops-it
fake_plugins lyrebird
tor_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "TOR_BIN=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
  "RESTART_SETTLE_TICKS=0"
  "PATH=$SKVPN_ROOT/plugins:$PATH"
)
env "${tor_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --tor >/dev/null
mv "$SYSTEMCTL_LOG" "$SKVPN_ROOT/install.log"
env "${tor_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --uninstall >/dev/null
if grep -qx "systemd-sysusers $SKVPN_ROOT/etc/sysusers.d/skvpn-tor.conf" "$SKVPN_ROOT/install.log" &&
  grep -qx 'enable skvpn-tor.service' "$SKVPN_ROOT/install.log" &&
  grep -qx 'try-restart skvpn-tor.service' "$SKVPN_ROOT/install.log" &&
  grep -qx 'disable --now skvpn-tor.service' "$SYSTEMCTL_LOG" &&
  [[ ! -e "$SKVPN_ROOT/systemd/skvpn-tor.service" && ! -e "$SKVPN_ROOT/etc/sing-box/torrc" ]]; then
  ok
else
  fail "a live install did not make the Tor user and enable its unit, or uninstall left Tor running"
fi

# --no-systemd is a real install that must not say a word to systemd; the stub log is
# the whole record of what would have been said
world no-systemd-install-stays-silent-toward-systemd
export SYSCTL_STATE="$SKVPN_ROOT/rp-filter"
printf '0\n' >"$SYSCTL_STATE"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
)
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --no-systemd --fix-discord-voice >/dev/null
install_log="$(<"$SYSTEMCTL_LOG")"
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --no-systemd --uninstall >/dev/null
if [[ -z "$install_log" && -z "$(<"$SYSTEMCTL_LOG")" &&
"$(<"$SYSCTL_STATE")" == 0 &&
! -e "$SKVPN_ROOT/usr/bin/skvpn" &&
! -e "$SKVPN_ROOT/etc/sing-box/base.d/00-base.json" ]]; then
  ok
else
  fail "--no-systemd talked to systemd or sysctl, or its uninstall left files"
fi

world uninstall-keeps-files-when-stop-fails
export SYSCTL_STATE="$SKVPN_ROOT/rp-filter"
printf '0\n' >"$SYSCTL_STATE"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
)
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" >/dev/null
export FAKE_ACTIVE=SE-exit
export SYSTEMCTL_FAIL='stop sing-box@SE-exit.service'
if env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --uninstall >/dev/null 2>&1; then
  fail "uninstall ignored a failed active-instance stop"
elif [[ -e "$SKVPN_ROOT/usr/bin/skvpn" &&
  -e "$SKVPN_ROOT/etc/sing-box/base.d/00-base.json" &&
  -e "$SKVPN_ROOT/systemd/sing-box@.service.d/skvpn.conf" ]]; then
  ok
else
  fail "uninstall deleted runtime files after an active-instance stop failed"
fi

# A settings change must not take the tunnel down: the active instance is restarted by
# name onto the new base, and the boot choice on disk is none of the installer's business
world reinstall-keeps-the-active-profile-up
export SYSCTL_STATE="$SKVPN_ROOT/rp-filter"
printf '0\n' >"$SYSCTL_STATE"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
  "RESTART_SETTLE_TICKS=0"
)
sv add "$HY2" >/dev/null
sv up HY2 >/dev/null
profile_before=$(<"$(profile HY2)")
export FAKE_ACTIVE=HY2
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" >/dev/null
: >"$SYSTEMCTL_LOG"
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --dns-server 9.9.9.9 >/dev/null
base="$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
if grep -qx 'restart sing-box@HY2.service' "$SYSTEMCTL_LOG" &&
  grep -q 'is-active --quiet sing-box@HY2.service' "$SYSTEMCTL_LOG" &&
  ! grep -q 'stop sing-box@' "$SYSTEMCTL_LOG" &&
  ! grep -q try-restart "$SYSTEMCTL_LOG" &&
  [[ "$(cat "$(active_file)")" == HY2 && "$(<"$(profile HY2)")" == "$profile_before" ]] &&
  jq -e '.dns.servers[1].server == "9.9.9.9"' "$base" >/dev/null; then
  ok
else
  fail "a re-install stopped the active profile, skipped its restart, or touched its state"
fi

# An instance that dies on the new base gets the old one back, and the run says so
world failed-restart-rolls-the-base-back
export SYSCTL_STATE="$SKVPN_ROOT/rp-filter"
printf '0\n' >"$SYSCTL_STATE"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "NFT=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
  "RESTART_SETTLE_TICKS=0"
)
sv add "$HY2" >/dev/null
sv up HY2 >/dev/null
export FAKE_ACTIVE=HY2
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --dns-server 9.9.9.9 >/dev/null
base="$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
base_before=$(<"$base")
printf '{"log":{"level":"debug"}}\n' >"$SKVPN_ROOT/extra.json"
export SYSTEMCTL_FAIL='is-active'
: >"$SYSTEMCTL_LOG"
if env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" \
  --extra-settings "$SKVPN_ROOT/extra.json" >/dev/null 2>&1; then
  fail "an instance that died on the new base was reported as installed"
elif [[ "$(<"$base")" == "$base_before" &&
! -e "$SKVPN_ROOT/etc/sing-box/base.d/50-extra.json" &&
"$(grep -c '^restart sing-box@HY2.service$' "$SYSTEMCTL_LOG")" == 2 &&
-s "$JOURNALCTL_LOG" &&
"$(cat "$(active_file)")" == HY2 ]]; then
  ok
else
  fail "the previous base was not restored, the instance not restarted onto it, or the journal not shown"
fi

echo "tor"

# The base, the torrc and tor.json the way the installer renders them, from one set of
# options; the transports are the ones this Tor can run, and the request must not ask
# for more. A preset is what names the bridges' country
tor_on() {
  local conf="$SKVPN_ROOT/etc/sing-box" render=(python3 "$REPO/non-nix/render-base.py" --skip-path-check
    --tor --tor-plugin "obfs4,snowflake=/usr/bin/lyrebird" "$@")
  mkdir -p "$conf/base.d"
  "${render[@]}" >"$conf/base.d/00-base.json"
  "${render[@]}" --render tor >"$conf/tor.json"
  "${render[@]}" --render torrc >"$conf/torrc"
}
bridges_file() { printf '%s/var/lib/skvpn/tor-bridges.conf' "$SKVPN_ROOT"; }

# Moat on loopback: answers every POST with $SKVPN_ROOT/moat.json and logs its body
moat_up() {
  "$HERE/moat-server.py" "$SKVPN_ROOT/moat.bodies" "$SKVPN_ROOT/moat.json" >"$SKVPN_ROOT/moat.port" &
  MOAT_PID=$!
  for _ in $(seq 50); do
    [[ -s "$SKVPN_ROOT/moat.port" ]] && break
    sleep 0.1
  done
  SKVPN_MOAT_URL="http://127.0.0.1:$(<"$SKVPN_ROOT/moat.port")/moat/circumvention/settings"
  export SKVPN_MOAT_URL
}
moat_down() {
  kill "$MOAT_PID" 2>/dev/null || true
  wait "$MOAT_PID" 2>/dev/null || true
  unset SKVPN_MOAT_URL
}
moat_answer() {
  cat >"$SKVPN_ROOT/moat.json" <<'EOF'
{"settings": [
  {"bridges": {"type": "snowflake", "source": "bridgedb", "bridge_strings": ["snowflake 192.0.2.3:80 AAAA url=https://broker.example/"]}},
  {"bridges": {"type": "webtunnel", "source": "bridgedb", "bridge_strings": ["webtunnel [2001:db8::1]:443 BBBB url=https://wt.example/x"]}},
  {"bridges": {"type": "obfs4", "source": "bridgedb", "bridge_strings": ["obfs4 198.51.100.7:443 CCCC cert=xyz iat-mode=0", "obfs4 192.168.0.21:2101 EEEE cert=lan iat-mode=2", "obfs4 198.51.100.8:443 DDDD cert=abc iat-mode=0"]}}
]}
EOF
}

world tor-base-sends-onion-names-to-tor
tor_on
base="$SKVPN_ROOT/etc/sing-box/base.d/00-base.json"
python3 "$REPO/non-nix/render-base.py" --skip-path-check >"$SKVPN_ROOT/plain.json"
if jq -e --arg o "$(tor_policy onion)" --arg f "$(tor_policy fakeip)" --argjson p "$(tor_policy routePort)" '
    (.dns.servers | any(.tag == "onion" and .type == "fakeip" and .inet4_range == $f)) and
    .dns.rules[0] == {"domain_suffix": [$o], "action": "route", "server": "onion"} and
    (.outbounds | any(. == {"type": "socks", "tag": "tor", "server": "127.0.0.1", "server_port": $p})) and
    (.route.rules | (map(.domain_suffix == [$o] and .outbound == "tor") | index(true)) as $tor |
      (map(.ip_is_private == true) | index(true)) as $private | $tor != null and $tor < $private)' \
  "$base" >/dev/null &&
  jq -e '(.outbounds | all(.tag != "tor")) and (.dns.servers | all(.tag != "onion"))' "$SKVPN_ROOT/plain.json" >/dev/null; then
  ok
else
  fail "the base did not send .onion names to Tor ahead of the private-address rule, or did so without --tor"
fi

world torrc-carries-ports-transports-and-bridges
tor_on
torrc="$SKVPN_ROOT/etc/sing-box/torrc"
if grep -qx "SocksPort 127.0.0.1:$(tor_policy socksPort)" "$torrc" &&
  grep -qx "SocksPort 127.0.0.1:$(tor_policy routePort) IsolateDestAddr" "$torrc" &&
  grep -qx "DNSPort 127.0.0.1:$(tor_policy dnsPort)" "$torrc" &&
  grep -qx 'ClientTransportPlugin obfs4,snowflake exec /usr/bin/lyrebird' "$torrc" &&
  grep -qx 'UseBridges 1' "$torrc" &&
  grep -qx '%include /var/lib/skvpn/tor-bridges.conf' "$torrc"; then
  ok
else
  fail "the torrc lost a port, the transport plugin or the bridges include"
fi

# Tor's own lookups go to the address sing-box serves DNS on inside the TUN, the one after
# the TUN's own, so they reach sing-box from Tor's user and not from systemd-resolved's.
# With no TUN at all they fall back, after a short wait, to the remote DNS server, which
# then has to be an address
world tor-resolver-is-the-tun-dns
render=(python3 "$REPO/non-nix/render-base.py" --skip-path-check --tor --tor-plugin obfs4=/x --render tor-resolv)
default=$("${render[@]}")
custom=$("${render[@]}" --tun-address fd00::1/126 --tun-address 10.7.0.1/30 --dns-server 9.9.9.9)
named=0
"${render[@]}" --dns-server dns.quad9.net >/dev/null 2>&1 || named=$?
if [[ "$(grep -m1 '^nameserver' <<<"$default")" == "nameserver 172.19.0.2" &&
"$(grep '^nameserver' <<<"$custom")" == "nameserver 10.7.0.2"$'\n'"nameserver 9.9.9.9" &&
"$(grep -c '^nameserver' <<<"$default")" == 2 && "$named" != 0 ]] &&
  grep -qE '^options .*timeout:[1-3]( |$)' <<<"$default"; then
  ok
else
  fail "Tor's resolver is not the TUN's DNS then the remote server, waits long on a missing TUN, or took a name"
fi

# What a program in Tor's unit meets when it resolves through glibc: the unit's own binds
# and hidden paths, laid out in a user, mount and network namespace, with a DNS server on
# the TUN's DNS address. The lookup must reach that server, not nscd or systemd-resolved
world tor-unit-resolves-through-the-tun-dns
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --tor --tun-address 127.0.0.1/30 \
  --dns-server 127.0.0.2 >/dev/null
unit="$(guard_stage systemd/system/skvpn-tor.service)"
binds=$(sed -n 's/^BindReadOnlyPaths=//p' "$unit")
hidden=$(sed -n 's/^InaccessiblePaths=//p' "$unit")
# shellcheck disable=SC2016 # the inner bash expands its arguments, this one must not
answer=$(unshare -rmn bash -c '
  set -e
  ip link set lo up
  "$1" 127.0.0.2 "$2/queries" >"$2/dns.out" &
  for _ in $(seq 50); do [[ -s "$2/dns.out" ]] && break; sleep 0.1; done
  [[ -s "$2/dns.out" ]] || { echo "the fake DNS server did not start" >&2; exit 1; }
  # A host whose own name service never asks DNS, so only the files of the unit can make it
  mount -t tmpfs none /etc
  printf "hosts: files\n" >/etc/nsswitch.conf
  : >/etc/resolv.conf
  for bind in $3; do mount --bind "$4${bind%%:*}" "${bind#*:}"; done
  for path in $5; do path=${path#-}; [[ ! -e "$path" ]] || mount -t tmpfs none "$path"; done
  "$6" -c "import socket; print(socket.getaddrinfo(\"probe.example.test\", 80, socket.AF_INET)[0][4][0])"
' _ "$HERE/fake-dns.py" "$SKVPN_ROOT" "$binds" "$SKVPN_ROOT/stage" "$hidden" \
  "$(readlink -f "$(command -v python3)")" 2>"$SKVPN_ROOT/ns.err") || true
if [[ "$answer" == 10.9.9.9 ]] && grep -qx 'probe.example.test' "$SKVPN_ROOT/queries" &&
  ! grep -q GODEBUG "$unit"; then
  ok
else
  fail "a glibc lookup in Tor's unit missed the TUN's DNS (answer: ${answer:-none}): $(tail -1 "$SKVPN_ROOT/ns.err")"
fi

world tor-bridges-update-asks-moat-for-the-base-country
tor_on --preset russia
moat_answer
moat_up
out=$(sv tor bridges update 2>&1) || true
moat_down
body=$(cat "$SKVPN_ROOT/moat.bodies" 2>/dev/null || true)
if [[ "$body" == "application/vnd.api+json "* ]] &&
  jq -e '. == {"country": "ru", "transports": ["obfs4", "snowflake"]}' <<<"${body#* }" >/dev/null &&
  grep -qx 'Bridge obfs4 198.51.100.7:443 CCCC cert=xyz iat-mode=0' "$(bridges_file)" &&
  grep -qx 'Bridge snowflake 192.0.2.3:80 AAAA url=https://broker.example/' "$(bridges_file)" &&
  [[ $(grep -c '^Bridge ' "$(bridges_file)") == 3 ]] &&
  grep -qx 'reload-or-restart skvpn-tor.service' "$SYSTEMCTL_LOG"; then
  ok
else
  fail "bridges update did not ask Moat for ru and the runnable transports, keep only those, or reload Tor: $out"
fi

# Moat has offered an obfs4 bridge on a LAN address; obfs4 dials the address in its line,
# so that bridge can never answer. The other transports' addresses are placeholders
world tor-bridges-update-drops-obfs4-on-a-lan-address
tor_on --preset russia
moat_answer
moat_up
out=$(sv tor bridges update 2>&1) || true
moat_down
if ! grep -q '192\.168\.0\.21' "$(bridges_file)" &&
  grep -qx 'Bridge obfs4 198.51.100.8:443 DDDD cert=abc iat-mode=0' "$(bridges_file)" &&
  grep -qx 'Bridge snowflake 192.0.2.3:80 AAAA url=https://broker.example/' "$(bridges_file)" &&
  grep -q '192\.168\.0\.21' <<<"$out"; then
  ok
else
  fail "bridges update kept an obfs4 bridge on a LAN address, or dropped it in silence: $out"
fi

world tor-bridges-update-takes-a-country
tor_on
moat_answer
moat_up
none=0
sv tor bridges update >/dev/null 2>&1 || none=$?
sv tor bridges update --country IR >/dev/null 2>&1 || true
moat_down
if ((none)) && [[ $(wc -l <"$SKVPN_ROOT/moat.bodies") == 1 ]] &&
  jq -e '.country == "ir"' <<<"$(cut -d' ' -f2- "$SKVPN_ROOT/moat.bodies")" >/dev/null; then
  ok
else
  fail "with no preset bridges update guessed a country, or --country was not what it asked for"
fi

world tor-bridges-update-refuses-two-countries
tor_on --preset russia --preset iran
if ! err=$(sv tor bridges update 2>&1) && [[ "$err" == *--country* && ! -e $(bridges_file) ]]; then
  ok
else
  fail "with two presets bridges update picked one by itself"
fi

world tor-bridges-update-keeps-the-old-bridges-on-a-moat-error
tor_on --preset russia
mkdir -p "$(dirname "$(bridges_file)")"
printf 'Bridge obfs4 203.0.113.1:443 OLD cert=old iat-mode=0\n' >"$(bridges_file)"
printf '{"errors": [{"code": 404, "detail": "no bridges for that country"}]}\n' >"$SKVPN_ROOT/moat.json"
moat_up
if ! err=$(sv tor bridges update 2>&1) && [[ "$err" == *"no bridges for that country"* ]] &&
  grep -q OLD "$(bridges_file)" && ! grep -q skvpn-tor "$SYSTEMCTL_LOG"; then
  ok
else
  fail "a Moat error replaced the bridges, reloaded Tor or went unreported"
fi
moat_down

world tor-commands-without-tor-configured-fail
sv add "$HY2" >/dev/null
if ! sv tor bridges update >/dev/null 2>&1 && ! sv up tor >/dev/null 2>&1 && [[ ! -e $(profile tor) ]]; then
  ok
else
  fail "a tor command ran on a host where Tor is not configured"
fi

world up-tor-runs-the-rendered-profile
tor_on
sv up tor >/dev/null
if jq -e --slurpfile want "$SKVPN_ROOT/etc/sing-box/tor.json" '. == $want[0]' "$(profile tor)" >/dev/null &&
  grep -q 'start sing-box@tor.service' "$SYSTEMCTL_LOG" && [[ "$(<"$(active_file)")" == tor ]] &&
  jq -e --arg u "$(tor_policy user)" --argjson p "$(tor_policy routePort)" '
    .outbounds[0] == {"type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": $p} and
    (.route.rules | any(.user == [$u] and .outbound == "direct")) and
    (.dns.rules | any(.user == [$u] and .server == "bootstrap")) and
    .dns.rules[-1] == {"action": "route", "server": "tor"}' "$(profile tor)" >/dev/null; then
  ok
else
  fail "up tor did not run the rendered profile, or the profile lets Tor route into itself"
fi

# Tor's SOCKS carries no UDP: a refusal at once sends QUIC back to TCP, where a SOCKS
# request Tor rejects would leave it waiting. Tor's own UDP, snowflake's WebRTC, leaves first
world tor-profile-refuses-udp-after-tors-own
tor_on
if jq -e --arg u "$(tor_policy user)" '.route.rules |
    (map(.user == [$u]) | index(true)) as $own |
    (map(.network == ["udp"] and .action == "reject") | index(true)) as $udp |
    $own != null and $udp != null and $own < $udp' "$SKVPN_ROOT/etc/sing-box/tor.json" >/dev/null; then
  ok
else
  fail "the tor profile hands UDP to Tor's SOCKS, or refuses it before Tor's own"
fi

world up-tor-via-takes-tor-through-a-node
sv add "$HY2" >/dev/null
tor_on
sv up tor --via HY2 >/dev/null
if jq -e --slurpfile node "$(profile HY2)" --arg u "$(tor_policy user)" '
    (.outbounds | any(. == ($node[0].outbounds[0] + {"tag": "tor-via"}))) and
    (.route.rules | any(.user == [$u] and .outbound == "tor-via")) and
    (.route.rules | all(.outbound != "direct" or .user != [$u]))' "$(profile tor)" >/dev/null &&
  ! sv up tor --via nowhere >/dev/null 2>&1 && ! sv up tor --via tor >/dev/null 2>&1 &&
  ! sv up HY2 --via HY2 >/dev/null 2>&1; then
  ok
else
  fail "up tor --via did not send Tor through the node, or took a node it should refuse"
fi

world up-tor-profile-passes-the-real-sing-box
sv add "$HY2" >/dev/null
tor_on
sv up tor --via HY2 >/dev/null
real=$(type -ap sing-box | grep -v -x -F "$HERE/stub/sing-box" | head -n 1 || true)
if [[ -z "$real" ]]; then
  fail "no real sing-box on PATH after the stub"
elif err=$("$real" check -C "$SKVPN_ROOT/etc/sing-box/base.d" -c "$(profile tor)" 2>&1); then
  ok
else
  fail "the real sing-box refused the base with the tor profile: $err"
fi

world tor-is-a-reserved-profile-name
url=$(sub_body "${HY2%#*}#tor")
sv add "${HY2%#*}#tor" >/dev/null 2>&1 || true
sv sub set "$url" >/dev/null 2>&1 || true
if [[ ! -e $(profile tor) ]]; then
  ok
else
  fail "a share link took the name the host's Tor profile is reserved under"
fi

world default-lists-leave-tor-out
sv add "$HY2" >/dev/null
tor_on
sv up tor >/dev/null
export FAKE_DELAYS='HY2=42'
sv ping >/dev/null
pinged=$(jq -c '[.outbounds[].tag]' "$SING_BOX_CONFIG")
listed=$(sv ls --names)
if [[ "$pinged" == '["HY2"]' && "$listed" == *tor* ]] &&
  jq -e '.outbounds[0].outbounds == ["HY2"]' <<<"$(sv export --sfa --no-tailscale 2>/dev/null)" >/dev/null; then
  ok
else
  fail "ping or export --sfa took the host's Tor profile by default, or ls hid it"
fi

world tor-status-reads-the-bootstrap-and-bridges
tor_on --preset russia
moat_answer
moat_up
sv tor bridges update >/dev/null 2>&1 || true
moat_down
export FAKE_JOURNAL=$'Oct 20 [notice] Bootstrapped 14% (handshake): Handshaking\nOct 20 [notice] Bootstrapped 73% (loading_descriptors): Loading relay descriptors'
export FAKE_TOR_STATE=active
out=$(sv tor 2>&1) || true
if [[ "$out" == *73%* && "$out" != *14%* && "$out" == *"obfs4 2"* && "$out" == *"snowflake 1"* &&
  "$out" == *ru* && "$out" == *"127.0.0.1:$(tor_policy socksPort)"* ]]; then
  ok
else
  fail "tor status lost the bootstrap, a bridge count, the country or the SOCKS address: $out"
fi

world export-sfa-tor-goes-through-orbot
sv add "$HY2" >/dev/null
sfa_base
with=$(sv export --sfa --no-tailscale --tor 2>/dev/null) || true
without=$(sv export --sfa --no-tailscale 2>/dev/null) || true
if jq -e --slurpfile p "$REPO/policy.json" '$p[0].tor as $t |
    (.outbounds | any(. == {"type": "socks", "tag": "tor", "server": "127.0.0.1", "server_port": $t.orbot.socksPort})) and
    .outbounds[0].outbounds == ["HY2", "tor"] and
    (.route.rules | any(.package_name == [$t.orbot.package] and .outbound == "direct")) and
    (.route.rules | any(.domain_suffix == [$t.onion] and .outbound == "tor")) and
    (.dns.servers | any(.type == "fakeip")) and
    (.dns.rules | any(.domain_suffix == [$t.onion] and .server == "onion"))' <<<"$with" >/dev/null &&
  jq -e '(.outbounds | all(.tag != "tor")) and (.dns.servers | all(.type != "fakeip"))' <<<"$without" >/dev/null; then
  ok
else
  fail "export --sfa --tor did not reach Orbot for .onion and as an exit, or --tor leaked into the plain export"
fi

world export-sfa-tor-passes-the-real-sing-box
sv add "$HY2" >/dev/null
sfa_base
sv export --sfa --no-tailscale --tor >"$SKVPN_ROOT/phone.json" 2>/dev/null || true
real=$(type -ap sing-box | grep -v -x -F "$HERE/stub/sing-box" | head -n 1 || true)
# The phone fetches its rule-sets at start; check sees only the shape
if [[ -n "$real" ]] && err=$(jq '.route.rule_set = [] | .route.rules |= map(select(.rule_set == null)) | .dns.rules |= map(select(.rule_set == null))' \
  "$SKVPN_ROOT/phone.json" >"$SKVPN_ROOT/phone-check.json" && "$real" check -c "$SKVPN_ROOT/phone-check.json" 2>&1); then
  ok
else
  fail "the real sing-box refused the phone config with Tor: ${err:-no real sing-box}"
fi

world skvpn-prints-its-version
want="skvpn $(cat "$REPO/VERSION")"
if [[ "$(sv --version)" == "$want" && "$(sv -v)" == "$want" ]]; then
  ok
else
  fail "skvpn --version does not answer with the VERSION file's number"
fi

world unknown-command-fails
if sv frobnicate >/dev/null 2>&1; then
  fail "an unknown command exited 0"
else
  ok
fi

# The completion files spell the command list by hand; COMMANDS is the declaration they
# must not drift from
world completions-know-every-command
mapfile -t commands < <(python3 -B -c "import sys; sys.path.insert(0, '$REPO'); import skvpn; print('\n'.join(skvpn.COMMANDS))")
if ((${#commands[@]} < 5)); then
  fail "COMMANDS import came back empty — the drift check is checking nothing"
else
  drifted=""
  for cmd in "${commands[@]}"; do
    grep -qw "$cmd" "$REPO/completions/skvpn.bash" || drifted+=" bash:$cmd"
    grep -q "'$cmd:" "$REPO/completions/_skvpn" || drifted+=" zsh:$cmd"
  done
  if [[ -z "$drifted" ]]; then
    ok
  else
    fail "commands missing from completions:$drifted"
  fi
fi

if ((fails)); then
  printf '\n%d failed\n' "$fails"
  exit 1
fi
printf '\nall passed (｡•̀ᴗ-)✧\n'
