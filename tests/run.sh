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
  unset FAKE_ACTIVE
  unset SYSTEMCTL_FAIL
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
if [[ -x "$SKVPN_ROOT/stage/usr/local/bin/skvpn" &&
  -e "$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json" &&
  -e "$SKVPN_ROOT/stage/etc/systemd/system/sing-box@.service.d/skvpn.conf" &&
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
  --extra-settings "$SKVPN_ROOT/extra.json" \
  --no-restore \
  --sync-interval weekly \
  --trusted-user alice >/dev/null
base="$SKVPN_ROOT/stage/etc/sing-box/base.d/00-base.json"
if jq -e '
	.inbounds[0].interface_name == "friend-tun" and
	.inbounds[0].address == ["10.42.0.1/30"] and
	(.inbounds[0].route_exclude_address | length == 2)
' "$base" >/dev/null &&
  jq -e '.dns.servers[1].server == "1.1.1.1"' "$base" >/dev/null &&
  jq -e '.route.rules | any(.domain_suffix? | index(".ru"))' "$base" >/dev/null &&
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

world installer-help-lists-every-feature
help=$("$REPO/install.sh" --help)
missing=""
for option in tailscale direct-russia direct-china direct-iran direct-zone direct-geosite \
  direct-geoip tun-interface tun-address dns-server extra-settings no-restore sync-interval \
  trusted-user fix-discord-voice no-fix-discord-voice uninstall; do
  [[ "$help" == *"--$option"* ]] || missing+=" $option"
done
if [[ -z "$missing" ]]; then
  ok
else
  fail "installer help omits:$missing"
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
if out=$(env "${installer_env[@]}" "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" 2>&1); then
  fail "installation continued with missing runtime dependencies"
elif [[ "$out" == *"sing-box ($SKVPN_ROOT/missing-sing-box)"* &&
  "$out" == *"sing-box@.service"* &&
  "$out" == *"sing-box service user (missing-sing-box-user)"* &&
  "$out" == *"official APT repository"* &&
  "$out" == *"sing-box.sagernet.org/installation/package-manager"* &&
  ! -e "$SKVPN_ROOT/usr/bin/skvpn" ]]; then
  ok
else
  fail "dependency preflight did not aggregate failures or show the Ubuntu guidance"
fi

world installer-gives-arch-package-command
printf 'ID=cachyos\nID_LIKE=arch\n' >"$SKVPN_ROOT/os-release"
if out=$(OS_RELEASE="$SKVPN_ROOT/os-release" SING_BOX="$SKVPN_ROOT/missing" \
  "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" 2>&1); then
  fail "installation continued without sing-box on CachyOS"
elif [[ "$out" == *"sudo pacman -S --needed sing-box"* ]]; then
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
  "$REPO/install.sh" --prefix "$SKVPN_ROOT/usr" --no-fix-discord-voice >/dev/null
if [[ "$(<"$SYSCTL_STATE")" == 1 && ! -e "$saved" &&
! -e "$SKVPN_ROOT/etc/sysctl.d/90-skvpn.conf" ]]; then
  ok
else
  fail "a repeated install lost the old rp_filter value, or disabling did not restore it"
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
env "${installer_env[@]}" "$REPO/install.sh" "${common_args[@]}" --uninstall >/dev/null
env "${installer_env[@]}" "$REPO/install.sh" "${common_args[@]}" --uninstall >/dev/null
if [[ "$(<"$SYSCTL_STATE")" == 0 && ! -e "$SKVPN_ROOT/usr/bin/skvpn" &&
! -e "$SKVPN_ROOT/etc/sing-box/base.d/00-base.json" &&
! -e "$SKVPN_ROOT/systemd/sing-box@.service.d/skvpn.conf" &&
! -e "$SKVPN_ROOT/systemd/skvpn-restore.service" &&
! -e "$SKVPN_ROOT/systemd/skvpn-sync.service" &&
! -e "$SKVPN_ROOT/systemd/skvpn-sync.timer" &&
! -e "$SKVPN_ROOT/etc/sysctl.d/90-skvpn.conf" ]]; then
  ok
else
  fail "uninstall did not restore policy and remove every file, or was not repeatable"
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
