#!/usr/bin/env bash

set -euo pipefail

here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
VERSION=$(cat "$here/VERSION")

PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
SYSCONFDIR="${SYSCONFDIR:-/etc}"
LOCALSTATEDIR="${LOCALSTATEDIR:-/var}"
SYSTEMD_UNITDIR="${SYSTEMD_UNITDIR:-/etc/systemd/system}"
SING_BOX="${SING_BOX:-/usr/bin/sing-box}"
SERVICE_USER="${SERVICE_USER:-sing-box}"
SERVICE_GROUP="${SERVICE_GROUP:-sing-box}"
PROFILES_OWNER="${PROFILES_OWNER:-root}"
PROFILES_MODE="${PROFILES_MODE:-2755}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
# How long a restarted instance has to stay active before the new base counts as good, in
# half-second ticks: a simple unit is active the instant restart returns, and a config
# sing-box rejects kills it a moment later
RESTART_SETTLE_TICKS="${RESTART_SETTLE_TICKS:-4}"
DISCORD_VOICE=0
SYSTEMD=1
CONFIG_ARGS=()
RESTORE=1
SYNC_INTERVAL=daily
EXTRA_SETTINGS=""
TRUSTED_USERS=()
UNINSTALL=0

usage() {
  cat <<EOF
install.sh — install skvpn $VERSION

Each run converges the system to exactly the flags given: re-running without a flag
undoes what that flag installed, the way unsetting a NixOS option does on rebuild.

  PREFIX=$PREFIX (override with PREFIX=... or --prefix DIR)
  DESTDIR=${DESTDIR:-<empty>} (override with DESTDIR=... or --destdir DIR for staging)

  -h, --help           show this help and exit
  -v, --version        print the version and exit
      --prefix DIR     install prefix (default: /usr/local)
      --destdir DIR    staging root: files land under DESTDIR/PREFIX and no live
                       system state is touched
      --uninstall      remove skvpn and settings installed by this script
      --no-systemd     a real install that skips every live systemctl and sysctl
                       call — for containers and image builds without PID 1 systemd
  --fix-discord-voice  use loose IPv4 reverse-path filtering for tunnelled UDP;
                       absent, the fix is removed and the previous value restored
  --tailscale          keep Tailscale address ranges out of the TUN
  --docker             keep the docker0 bridge out of the TUN
  --direct-russia      route Russian zones, geosite and geoip directly
  --direct-china       route Chinese zones, geosite and geoip directly
  --direct-iran        route Iranian zones, geosite and geoip directly
  --direct-zone SUFFIX route an additional domain suffix directly; repeatable
  --direct-geosite TAG=PATH
                       add a local domain rule-set; repeatable
  --direct-geoip TAG=PATH
                       add a local address rule-set; repeatable
  --split [KIND] VALUE route a process or site around the tunnel: KIND is name (the
                       default), path (an absolute executable path), ip (an address
                       or CIDR) or domain (a site — a bare name, a URL or
                       *.example.com; the same rule as --direct-zone); repeatable.
                       name and path take wildcards: * one path segment, ** any run,
                       ? one character. A process literally called ip, path, name
                       or domain is spelled --split name ip
  --tun-interface NAME TUN interface name (default: skvpn-tun)
  --tun-address CIDR   TUN address; repeatable, replaces both defaults
  --stack NAME         TUN stack: system, gvisor or mixed (default: system)
  --no-ipv6            give the TUN no IPv6 address, for a host without IPv6
  --dns-server ADDRESS DNS-over-TLS server through the proxy (default: 8.8.8.8)
  --extra-settings FILE
                       append a sing-box base.d JSON file
  --no-restore         do not restore the active profile on boot
  --sync-interval SPEC systemd OnCalendar value (default: daily)
  --trusted-user USER  grant passwordless sudo for skvpn; repeatable

The CLI goes to \$PREFIX/bin/skvpn, completions and the install manifest to
\$PREFIX/share, the base config to \$SYSCONFDIR/sing-box/base.d, and units to
\$SYSTEMD_UNITDIR. python3, systemd, and sing-box must already be installed; a failed
preflight prints distro-specific guidance and installs nothing on its own.

A re-run restarts each active sing-box@<profile> by name and watches it for
RESTART_SETTLE_TICKS half-seconds (default: 4); an instance that does not stay up gets
the previous base config back, and the run fails with the unit's journal.

Runtime environment (read by the installed skvpn, not this script):
  SKVPN_ROOT           relocate every path skvpn touches (default: /)
  SKVPN_SING_BOX       the sing-box binary \`skvpn ping\` starts its probe with
                       (default: the first of PATH, /run/current-system/sw/bin, /usr/bin)

Exit 0 done, 1 when the install could not be made — a dependency missing, a manifest
that cannot be written — and 2 on a usage error.
EOF
}

die() { # the request itself is wrong
  printf 'install.sh: %s\n' "$1" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      # Not ${2:?}: that exits 1 with bash's own message, and a usage error is 2
      (($# >= 2)) || die "$1 needs a directory"
      PREFIX="$2"
      shift 2
      ;;
    --destdir)
      (($# >= 2)) || die "$1 needs a directory"
      DESTDIR="$2"
      shift 2
      ;;
    --fix-discord-voice)
      DISCORD_VOICE=1
      shift
      ;;
    --no-systemd)
      SYSTEMD=0
      shift
      ;;
    --tailscale | --docker)
      CONFIG_ARGS+=("$1")
      shift
      ;;
    --no-ipv6)
      CONFIG_ARGS+=(--no-ipv6)
      shift
      ;;
    --direct-russia | --direct-china | --direct-iran)
      CONFIG_ARGS+=(--preset "${1#--direct-}")
      shift
      ;;
    --direct-zone | --direct-geosite | --direct-geoip | --tun-interface | --tun-address | --dns-server | --stack)
      (($# >= 2)) || die "$1 needs a value"
      CONFIG_ARGS+=("$1" "$2")
      shift 2
      ;;
    --split)
      # A kind word is consumed only when a value follows it; the bare word is the value
      case "${2:-}" in
        name | path | ip | domain)
          (($# >= 3)) || die "--split $2 needs a value"
          CONFIG_ARGS+=("--split-$2" "$3")
          shift 3
          ;;
        *)
          (($# >= 2)) || die "--split needs a value"
          CONFIG_ARGS+=(--split-name "$2")
          shift 2
          ;;
      esac
      ;;
    --extra-settings)
      (($# >= 2)) || die "$1 needs a file"
      EXTRA_SETTINGS="$2"
      shift 2
      ;;
    --no-restore)
      RESTORE=0
      shift
      ;;
    --sync-interval)
      (($# >= 2)) || die "$1 needs a calendar specification"
      SYNC_INTERVAL="$2"
      shift 2
      ;;
    --trusted-user)
      (($# >= 2)) || die "$1 needs a user"
      TRUSTED_USERS+=("$2")
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -v | --version)
      echo "skvpn $VERSION"
      exit 0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$PREFIX" == /* ]] || die "PREFIX must be absolute: $PREFIX"
[[ "$SYSCONFDIR" == /* ]] || die "SYSCONFDIR must be absolute: $SYSCONFDIR"
[[ "$LOCALSTATEDIR" == /* ]] || die "LOCALSTATEDIR must be absolute: $LOCALSTATEDIR"
[[ "$SYSTEMD_UNITDIR" == /* ]] || die "SYSTEMD_UNITDIR must be absolute: $SYSTEMD_UNITDIR"
if ((UNINSTALL)) && [[ "$DISCORD_VOICE" == 1 ]]; then
  die "--uninstall already removes the Discord voice fix"
fi
if ((UNINSTALL)) && {
  ((${#CONFIG_ARGS[@]} || ! RESTORE || ${#TRUSTED_USERS[@]})) ||
    [[ -n "$EXTRA_SETTINGS" || "$SYNC_INTERVAL" != daily ]]
}; then
  die "--uninstall cannot be combined with configuration options"
fi

root="${DESTDIR%/}$PREFIX"
sysconf_root="${DESTDIR%/}$SYSCONFDIR"
state_root="${DESTDIR%/}$LOCALSTATEDIR/lib/skvpn/install-state"
unit_root="${DESTDIR%/}$SYSTEMD_UNITDIR"
sysctl_file="$sysconf_root/sysctl.d/90-skvpn.conf"
rp_filter_state="$state_root/rp-filter-before-discord-voice"
managed_state="$state_root/managed"
base_config="$sysconf_root/sing-box/base.d/00-base.json"
extra_config="$sysconf_root/sing-box/base.d/50-extra.json"
profiles_dir="$sysconf_root/sing-box/profiles"
skvpn_bin="$PREFIX/bin/skvpn"
sing_box_dropin="$unit_root/sing-box@.service.d/skvpn.conf"
sudoers_file="$sysconf_root/sudoers.d/skvpn"
profile_file="$sysconf_root/profile.d/skvpn.sh"
manifest_file="$root/share/skvpn/install-manifest"

# live: writing the real filesystem, not a staging tree. live_sys: live and allowed to
# talk to systemd — --no-systemd installs the very same files but skips every systemctl,
# systemd-analyze and sysctl call, which is what containers and image builds need
live=0
[[ -z "$DESTDIR" ]] && live=1
live_sys=0
((live && SYSTEMD)) && live_sys=1

missing=()
sing_box_missing=0
python3_missing=0
for command in install mktemp python3; do
  command -v "$command" >/dev/null || {
    missing+=("$command")
    [[ "$command" == python3 ]] && python3_missing=1
  }
done
if ((live)); then
  command -v id >/dev/null || missing+=("id")
fi
if ((live_sys)); then
  for command in systemctl systemd-analyze; do
    command -v "$command" >/dev/null || missing+=("$command")
  done
  if ! command -v systemctl >/dev/null && [[ ! -d /run/systemd/system ]]; then
    echo "install.sh: no running systemd found — pass --no-systemd for a container or image build" >&2
  fi
fi
if ((live)); then
  if ((UNINSTALL)); then
    if ((live_sys)) && [[ -f "$rp_filter_state" ]]; then
      command -v sysctl >/dev/null || missing+=("sysctl")
    fi
  else
    if [[ ! -x "$SING_BOX" ]]; then
      missing+=("sing-box ($SING_BOX)")
      sing_box_missing=1
    fi
    if ((live_sys)) && command -v systemctl >/dev/null && ! systemctl cat sing-box@.service >/dev/null 2>&1; then
      missing+=("sing-box@.service")
      sing_box_missing=1
    fi
    if command -v id >/dev/null && ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
      missing+=("sing-box service user ($SERVICE_USER)")
      sing_box_missing=1
    fi
    if ((live_sys)) && [[ "$DISCORD_VOICE" == 1 ]]; then
      command -v sysctl >/dev/null || missing+=("sysctl")
    fi
    if ((${#TRUSTED_USERS[@]})); then
      command -v visudo >/dev/null || missing+=("sudo/visudo")
    fi
  fi
fi

if ((${#missing[@]})); then
  # Runnable guidance lines are printed as `  $ command` — exactly what a person types,
  # no -y and no --noconfirm — and the distro tests run those very lines, so a typo here
  # is a red CI run rather than a lie that keeps
  distro=""
  if [[ -r "$OS_RELEASE" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        ID | ID_LIKE)
          value="${value%\"}"
          value="${value#\"}"
          distro+=" $value"
          ;;
      esac
    done <"$OS_RELEASE"
  fi
  {
    printf 'install.sh: missing dependencies:\n'
    printf '  - %s\n' "${missing[@]}"
    if ((python3_missing)); then
      case " $distro " in
        *" arch "*)
          printf '\nInstall python3 on Arch/CachyOS:\n'
          printf '  $ sudo pacman -S --needed python\n'
          ;;
        *" debian "* | *" ubuntu "*)
          printf '\nInstall python3 on Debian/Ubuntu:\n'
          printf '  $ sudo apt-get update\n'
          printf '  $ sudo apt-get install python3\n'
          ;;
        *" fedora "*)
          printf '\nInstall python3 on Fedora:\n'
          printf '  $ sudo dnf install python3\n'
          ;;
        *)
          printf '\nInstall python3 with your package manager\n'
          ;;
      esac
    fi
    if ((sing_box_missing)); then
      case " $distro " in
        *" arch "*)
          printf '\nInstall sing-box on Arch/CachyOS:\n'
          printf '  $ sudo pacman -S --needed sing-box\n'
          ;;
        *" debian "* | *" ubuntu "*)
          printf '\nInstall sing-box on Debian/Ubuntu, from its official APT repository:\n'
          printf '  $ sudo apt-get update\n'
          printf '  $ sudo apt-get install ca-certificates curl\n'
          printf '  $ sudo mkdir -p /etc/apt/keyrings\n'
          printf '  $ sudo curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc\n'
          printf '  $ sudo chmod a+r /etc/apt/keyrings/sagernet.asc\n'
          printf "  \$ printf 'Types: deb\\\\nURIs: https://deb.sagernet.org/\\\\nSuites: *\\\\nComponents: *\\\\nEnabled: yes\\\\nSigned-By: /etc/apt/keyrings/sagernet.asc\\\\n' | sudo tee /etc/apt/sources.list.d/sagernet.sources\n"
          printf '  $ sudo apt-get update\n'
          printf '  $ sudo apt-get install sing-box\n'
          ;;
        *" fedora "*)
          printf '\nInstall sing-box on Fedora, from its official DNF repository:\n'
          printf '  $ sudo dnf config-manager addrepo --from-repofile=https://sing-box.app/sing-box.repo\n'
          printf '  $ sudo dnf install sing-box\n'
          ;;
        *)
          printf '\nOfficial sing-box packages and installation instructions:\n'
          printf '  https://sing-box.sagernet.org/installation/package-manager/\n'
          ;;
      esac
    fi
  } >&2
  exit 1
fi

disable_discord_voice_fix() {
  local previous

  rm -f "$sysctl_file"
  if ((live_sys)) && [[ -f "$rp_filter_state" ]]; then
    command -v sysctl >/dev/null || {
      echo "install.sh: sysctl is required to restore the Discord voice fix" >&2
      exit 1
    }
    previous=$(<"$rp_filter_state")
    [[ "$previous" =~ ^[012]$ ]] || {
      echo "install.sh: invalid saved rp_filter value: $previous" >&2
      exit 1
    }
    sysctl -q -w "net.ipv4.conf.all.rp_filter=$previous"
    rm -f "$rp_filter_state"
    rmdir "$state_root" 2>/dev/null || true
  fi
}

# The sing-box@<profile> instances systemd reports active, into active_units
collect_active_units() {
  active_units=()
  while read -r unit _; do
    [[ -n "$unit" ]] && active_units+=("$unit")
  done < <(systemctl list-units --plain --no-legend --state=active 'sing-box@*.service')
}

if ((UNINSTALL)); then
  # The manifest is the only record of what was written. An install older than 1.1 has
  # none, and guessing its file list is what the old fallback did; that arm is gone, so
  # such an install is named and left alone rather than half-removed. Nothing installed
  # at all is not an error — a second --uninstall must stay quiet
  if [[ ! -f "$manifest_file" && -e "$root/bin/skvpn" ]]; then
    echo "install.sh: $root/bin/skvpn is installed but $manifest_file is missing — an install older than 1.1 kept no manifest; remove it with that version's install.sh --uninstall" >&2
    exit 1
  fi
  managed=0
  if ((! live)) || [[ -f "$managed_state" ]]; then
    managed=1
  fi
  if ((managed && live_sys)); then
    systemctl disable --now skvpn-sync.timer >/dev/null
    systemctl disable skvpn-restore.service >/dev/null 2>&1 || true
    collect_active_units
    if ((${#active_units[@]})); then
      systemctl stop "${active_units[@]}"
    fi
  fi
  if ((managed)); then
    disable_discord_voice_fix
  fi
  if [[ -f "$manifest_file" ]]; then
    while IFS= read -r path; do
      [[ -z "$path" || "$path" == \#* ]] && continue
      rm -f "${DESTDIR%/}$path"
    done <"$manifest_file"
    rm -f "$manifest_file"
  fi
  rm -f "$managed_state"
  rmdir "$unit_root/sing-box@.service.d" "$state_root" "$root/share/skvpn" \
    "$sysconf_root/sing-box/base.d" 2>/dev/null || true
  if ((live_sys)); then
    systemctl daemon-reload
  fi
  echo "removed skvpn from $root and settings installed by this script"
  exit 0
fi

render_args=("${CONFIG_ARGS[@]}" --sing-box "$SING_BOX")
((live)) || render_args+=(--skip-path-check)
rendered_base=$(mktemp)
temporary_files=("$rendered_base")
temporary_dirs=()
cleanup() {
  rm -f "${temporary_files[@]}"
  if ((${#temporary_dirs[@]})); then
    rm -rf "${temporary_dirs[@]}"
  fi
}
trap cleanup EXIT
python3 "$here/non-nix/render-base.py" "${render_args[@]}" >"$rendered_base"
if [[ -n "$EXTRA_SETTINGS" ]]; then
  python3 -c 'import json, sys; value = json.load(open(sys.argv[1])); sys.exit(0 if isinstance(value, dict) else "extra settings must be a JSON object")' "$EXTRA_SETTINGS"
fi
if ((live_sys)); then
  systemd-analyze calendar "$SYNC_INTERVAL" >/dev/null
fi
previous_rp_filter=""
if [[ "$DISCORD_VOICE" == 1 ]] && ((live_sys)); then
  if [[ ! -f "$rp_filter_state" ]]; then
    previous_rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter)
    [[ "$previous_rp_filter" =~ ^[012]$ ]] || {
      echo "install.sh: unexpected rp_filter value: $previous_rp_filter" >&2
      exit 1
    }
  fi
fi
rendered_sudoers=""
if ((${#TRUSTED_USERS[@]})); then
  rendered_sudoers=$(mktemp)
  temporary_files+=("$rendered_sudoers")
  for user in "${TRUSTED_USERS[@]}"; do
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
      echo "install.sh: invalid trusted user: $user" >&2
      exit 1
    }
    if ((live)); then
      id -u "$user" >/dev/null 2>&1 || {
        echo "install.sh: no such trusted user: $user" >&2
        exit 1
      }
    fi
    printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$skvpn_bin" >>"$rendered_sudoers"
  done
  if ((live)); then
    chmod 600 "$rendered_sudoers"
    visudo -cf "$rendered_sudoers" >/dev/null
  fi
fi

if ((live)) && [[ ! -f "$managed_state" && ! -f "$manifest_file" ]]; then
  managed_paths=(
    "$base_config" "$extra_config" "$sing_box_dropin"
    "$unit_root/skvpn-restore.service" "$unit_root/skvpn-sync.service"
    "$unit_root/skvpn-sync.timer" "$sudoers_file" "$profile_file" "$sysctl_file"
  )
  for path in "${managed_paths[@]}"; do
    [[ ! -e "$path" ]] || {
      echo "install.sh: refusing to overwrite unmanaged file: $path" >&2
      exit 1
    }
  done
  install -Dm600 /dev/null "$managed_state"
fi

# Every file the install writes lands in the manifest as its final runtime path (no
# DESTDIR), so --uninstall — including one against the same staging tree — removes
# exactly what was written and nothing it does not own
installed=()
rec() { installed+=("${1#"${DESTDIR%/}"}"); }

install -Dm755 "$here/skvpn.py" "$root/bin/skvpn"
rec "$root/bin/skvpn"
install -Dm644 "$here/completions/skvpn.bash" "$root/share/bash-completion/completions/skvpn"
rec "$root/share/bash-completion/completions/skvpn"
install -Dm644 "$here/completions/_skvpn" "$root/share/zsh/site-functions/_skvpn"
rec "$root/share/zsh/site-functions/_skvpn"
install -Dm644 "$here/VERSION" "$root/share/skvpn/VERSION"
rec "$root/share/skvpn/VERSION"

# What the running instance is on right now, kept until it has proven the new base:
# a base sing-box rejects would otherwise take the tunnel down with nothing to go back to
base_files=("$base_config" "$extra_config" "$sing_box_dropin")
backup_dir=""
if ((live_sys)); then
  backup_dir=$(mktemp -d)
  temporary_dirs+=("$backup_dir")
  for path in "${base_files[@]}"; do
    if [[ -f "$path" ]]; then
      cp -p "$path" "$backup_dir/${path##*/}"
    fi
  done
fi
restore_base_backup() {
  local path
  for path in "${base_files[@]}"; do
    if [[ -f "$backup_dir/${path##*/}" ]]; then
      cp -p "$backup_dir/${path##*/}" "$path"
    else
      rm -f "$path"
    fi
  done
}
# Active at tick 0 and still active after every settle tick — the explicit return keeps
# the last tick's skipped sleep from being read as a failure
unit_settles() {
  local unit="$1" tick
  for ((tick = 0; tick <= RESTART_SETTLE_TICKS; tick++)); do
    systemctl is-active --quiet "$unit" || return 1
    if ((tick < RESTART_SETTLE_TICKS)); then
      sleep 0.5
    fi
  done
  return 0
}

install -Dm644 "$rendered_base" "$base_config"
rec "$base_config"
rm -f "$rendered_base"

if [[ -n "$EXTRA_SETTINGS" ]]; then
  install -Dm644 "$EXTRA_SETTINGS" "$extra_config"
  rec "$extra_config"
else
  rm -f "$extra_config"
fi

if ((live)); then
  install -d -m"$PROFILES_MODE" -o "$PROFILES_OWNER" -g "$SERVICE_GROUP" "$profiles_dir"
  shopt -s nullglob
  profiles=("$profiles_dir"/*.json)
  if ((${#profiles[@]})); then
    chgrp "$SERVICE_GROUP" "${profiles[@]}"
    chmod 640 "${profiles[@]}"
  fi
  shopt -u nullglob
else
  # A staging tree has no target sing-box group; the package post-install owns final metadata
  install -d -m755 "$profiles_dir"
fi

# The two capabilities a process rule runs on, which a distribution's trimmed unit may
# lack (PITFALLS.md); these lines merge into whatever the unit already grants
install -Dm644 /dev/stdin "$sing_box_dropin" <<EOF
[Service]
ExecStart=
ExecStart=$SING_BOX -D $LOCALSTATEDIR/lib/sing-box-%i -C $SYSCONFDIR/sing-box/base.d -c $SYSCONFDIR/sing-box/profiles/%i.json run
CapabilityBoundingSet=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
EOF
rec "$sing_box_dropin"

if ((RESTORE)); then
  install -Dm644 /dev/stdin "$unit_root/skvpn-restore.service" <<EOF
[Unit]
Description=Bring the last active sing-box profile back up
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=$skvpn_bin restore

[Install]
WantedBy=multi-user.target
EOF
  rec "$unit_root/skvpn-restore.service"

else
  if ((live_sys)); then
    systemctl disable --now skvpn-restore.service >/dev/null 2>&1 || true
  fi
  rm -f "$unit_root/skvpn-restore.service"
fi

install -Dm644 /dev/stdin "$unit_root/skvpn-sync.service" <<EOF
[Unit]
Description=Refresh sing-box profiles from the stored subscription
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$skvpn_bin sub sync --if-stale
EOF
rec "$unit_root/skvpn-sync.service"

install -Dm644 /dev/stdin "$unit_root/skvpn-sync.timer" <<EOF
[Unit]
Description=Refresh sing-box profiles daily

[Timer]
OnCalendar=$SYNC_INTERVAL
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
rec "$unit_root/skvpn-sync.timer"

if ((${#TRUSTED_USERS[@]})); then
  install -Dm440 "$rendered_sudoers" "$sudoers_file"
  rec "$sudoers_file"
  install -Dm644 /dev/stdin "$profile_file" <<'EOF'
alias skvpn='sudo skvpn'
EOF
  rec "$profile_file"
else
  rm -f "$sudoers_file" "$profile_file"
fi

if [[ "$DISCORD_VOICE" == 1 ]]; then
  if ((live_sys)); then
    if [[ ! -f "$rp_filter_state" ]]; then
      install -Dm600 /dev/stdin "$rp_filter_state" <<<"$previous_rp_filter"
    fi
  fi

  install -Dm644 /dev/stdin "$sysctl_file" <<'EOF'
# TUN replies use an asymmetric return path; strict filtering drops tunnelled UDP
net.ipv4.conf.all.rp_filter = 2
EOF
  rec "$sysctl_file"

  if ((live_sys)); then
    sysctl -q -p "$sysctl_file"
  fi
else
  disable_discord_voice_fix
fi

{
  echo "# skvpn $VERSION install manifest"
  printf '%s\n' "${installed[@]}"
} >"$manifest_file"

if ((live_sys)); then
  systemctl daemon-reload
  if ((RESTORE)); then
    systemctl enable skvpn-restore.service >/dev/null
  else
    systemctl disable --now skvpn-restore.service >/dev/null 2>&1 || true
  fi
  systemctl enable --now skvpn-sync.timer >/dev/null

  # By name, and watched: a glob try-restart cannot tell a restart that took from one
  # whose instance died on the new base a second later. The CLI, units and manifest above
  # stay as installed either way — the manifest names the same paths, so --uninstall keeps
  # working; only the base goes back
  collect_active_units
  for unit in "${active_units[@]:-}"; do
    [[ -n "$unit" ]] || continue
    if ! systemctl restart "$unit" || ! unit_settles "$unit"; then
      echo "install.sh: $unit did not stay up on the new base config — restoring the previous one" >&2
      restore_base_backup
      systemctl daemon-reload || true
      systemctl restart "$unit" || true
      if command -v journalctl >/dev/null; then
        journalctl -u "$unit" -n 20 --no-pager >&2 || true
      fi
      echo "install.sh: $unit is back on the previous base config; fix the flags and re-run" >&2
      exit 1
    fi
  done
fi

cleanup
trap - EXIT

echo "installed skvpn $VERSION to $root/bin/skvpn with completions under $root/share"
