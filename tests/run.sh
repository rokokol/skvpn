#!/usr/bin/env bash
# Drives skvpn against a scratch SKVPN_ROOT and checks what lands on disk and what reaches
# systemd. SKVPN_ROOT relocates every path the tool touches, so nothing here needs root and
# nothing can name a path outside $WORK; systemctl is stubbed, so "what is running" is
# something the suite decides rather than inherits from the machine.
#
# --update rewrites tests/golden from the current parser output

set -euo pipefail

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
  unset SYSTEMCTL_FAIL
  unset FAKE_DELAYS
  unset SING_BOX_FAIL
  # An override exported in the developer's shell would reach past the stub unnoticed
  unset SKVPN_SING_BOX
}

sv() { python3 "$SKVPN" "$@"; }

profile() { printf '%s/etc/sing-box/profiles/%s.json' "$SKVPN_ROOT" "$1"; }
active_file() { printf '%s/var/lib/skvpn/active' "$SKVPN_ROOT"; }

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
want="  domain $(printf '%-40s' .ru) declared
  domain $(printf '%-40s' .su) declared
  domain example.com
  domain .cdn.example.net
  domain xn--e1afmkfd.xn--p1ai
  domain .by"
if jq -e '.route.rules == [{"domain_suffix": ["example.com", ".cdn.example.net", "xn--e1afmkfd.xn--p1ai", ".by"], "outbound": "direct"}]' "$file" >/dev/null &&
  jq -e '.dns.rules == [{"domain_suffix": ["example.com", ".cdn.example.net", "xn--e1afmkfd.xn--p1ai", ".by"], "server": "bootstrap"}]' "$file" >/dev/null &&
  [[ "$(sv split ls)" == "$want" ]] &&
  sv split rm domain example.com >/dev/null &&
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
  --dns-server 1.1.1.1 \
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
  jq -e '.dns.servers[1].server == "1.1.1.1"' "$base" >/dev/null &&
  jq -e '.route.rules | any(.domain_suffix? | index(".ru"))' "$base" >/dev/null &&
  jq -e '.route.rules | any(.domain_suffix? | index("example.com"))' "$base" >/dev/null &&
  jq -e '.dns.rules | any(.domain_suffix? | index("example.com"))' "$base" >/dev/null &&
  jq -e '.route.rules[-3] == {"process_name": ["firefox", "ip"], "outbound": "direct"}' "$base" >/dev/null &&
  jq -e '.route.rules[-2] == {"process_path": ["/usr/bin/steam"], "outbound": "direct"}' "$base" >/dev/null &&
  jq -e '.route.rules[-1] == {"ip_cidr": ["10.0.0.0/8"], "outbound": "direct"}' "$base" >/dev/null &&
  jq -e '.dns.rules[-2] == {"process_name": ["firefox", "ip"], "server": "bootstrap"}' "$base" >/dev/null &&
  jq -e '.dns.rules[-1] == {"process_path": ["/usr/bin/steam"], "server": "bootstrap"}' "$base" >/dev/null &&
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

# The TUN's v6 address is the one default a host without IPv6 has to be able to drop, and
# --tun-address is not that lever: it replaces the pair rather than trimming it
world installer-drops-the-tun-ipv6-address
"$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --no-ipv6 >/dev/null
base="$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json"
if jq -e '.inbounds[0].address == ["172.19.0.1/30"] and .inbounds[0].stack == "system"' \
  "$base" >/dev/null &&
  jq -e '.route.rules | length == 3' "$base" >/dev/null; then
  ok
else
  fail "--no-ipv6 left the TUN a v6 address, the default stack drifted, or a rule came from nowhere"
fi

world installer-rejects-bad-split-values
if "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split ip not-an-ip >/dev/null 2>&1 ||
  "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split path relative/bin >/dev/null 2>&1 ||
  "$REPO/install.sh" --destdir "$SKVPN_ROOT/stage" --split >/dev/null 2>&1; then
  fail "an invalid split value was accepted"
elif [[ ! -e "$SKVPN_ROOT/stage/usr/local/bin/skvpn" ]]; then
  ok
else
  fail "an invalid split value left a partial installation"
fi

world installer-help-lists-every-feature
help=$("$REPO/install.sh" --help)
missing=""
for option in help version prefix destdir uninstall no-systemd tailscale docker \
  direct-russia direct-china direct-iran direct-zone direct-geosite \
  direct-geoip split tun-interface tun-address dns-server extra-settings no-restore sync-interval \
  trusted-user fix-discord-voice stack no-ipv6; do
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
  "SERVICE_USER=missing-sing-box-user"
  "OS_RELEASE=$SKVPN_ROOT/os-release"
  "SYSTEMCTL_FAIL=cat sing-box@.service"
)
# The guidance lines are matched whole (grep -qxF): the harness that runs them in the
# distro tests extracts exactly these, so a substring match here could bless a line
# nobody can actually type
if out=$(env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" 2>&1); then
  fail "installation continued with missing runtime dependencies"
elif [[ "$out" == *"sing-box ($SKVPN_ROOT/missing-sing-box)"* &&
  "$out" == *"sing-box@.service"* &&
  "$out" == *"sing-box service user (missing-sing-box-user)"* &&
  "$out" == *"official APT repository"* ]] &&
  grep -qxF '  $ sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc' <<<"$out" &&
  grep -qxF '  $ sudo apt-get install sing-box' <<<"$out" &&
  [[ ! -e "$SKVPN_ROOT/usr/bin/skvpn" ]]; then
  ok
else
  fail "dependency preflight did not aggregate failures or show the Ubuntu guidance"
fi

world installer-gives-arch-package-command
printf 'ID=cachyos\nID_LIKE=arch\n' >"$SKVPN_ROOT/os-release"
if out=$(OS_RELEASE="$SKVPN_ROOT/os-release" SING_BOX="$SKVPN_ROOT/missing" \
  "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" 2>&1); then
  fail "installation continued without sing-box on CachyOS"
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

# Installs made before the manifest existed: --uninstall still takes them out by the
# fixed list. This arm leaves one release after 1.1
world uninstall-falls-back-without-a-manifest
export SYSCTL_STATE="$SKVPN_ROOT/rp-filter"
printf '0\n' >"$SYSCTL_STATE"
installer_env=(
  "SYSCONFDIR=$SKVPN_ROOT/etc"
  "LOCALSTATEDIR=$SKVPN_ROOT/var"
  "SYSTEMD_UNITDIR=$SKVPN_ROOT/systemd"
  "SING_BOX=$(command -v python3)"
  "SERVICE_USER=$(id -un)"
  "SERVICE_GROUP=$(id -gn)"
  "PROFILES_OWNER=$(id -un)"
  "PROFILES_MODE=755"
)
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" >/dev/null
rm -rf "$SKVPN_ROOT/usr/share/skvpn"
env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --uninstall >/dev/null
if [[ ! -e "$SKVPN_ROOT/usr/bin/skvpn" &&
  ! -e "$SKVPN_ROOT/etc/sing-box/base.d/00-base.json" &&
  ! -e "$SKVPN_ROOT/systemd/skvpn-sync.timer" ]]; then
  ok
else
  fail "an install without a manifest could not be uninstalled"
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
