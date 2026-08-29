#!/usr/bin/env bash

set -euo pipefail

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
DISCORD_VOICE_ACTION=""
CONFIG_ARGS=()
RESTORE=1
SYNC_INTERVAL=daily
EXTRA_SETTINGS=""
TRUSTED_USERS=()
UNINSTALL=0

usage() {
  cat <<EOF
install.sh — install skvpn

  PREFIX=$PREFIX (override with PREFIX=... or --prefix DIR)
  DESTDIR=${DESTDIR:-<empty>} (override with DESTDIR=... or --destdir DIR for staging)

  --fix-discord-voice  use loose IPv4 reverse-path filtering for tunnelled UDP
  --no-fix-discord-voice
                       remove the fix and restore the previous live value
  --tailscale           keep Tailscale address ranges out of the TUN
  --direct-russia       route Russian zones, geosite and geoip directly
  --direct-china        route Chinese zones, geosite and geoip directly
  --direct-iran         route Iranian zones, geosite and geoip directly
  --direct-zone SUFFIX  route an additional domain suffix directly; repeatable
  --direct-geosite TAG=PATH
                       add a local domain rule-set; repeatable
  --direct-geoip TAG=PATH
                       add a local address rule-set; repeatable
  --tun-interface NAME  TUN interface name (default: skvpn-tun)
  --tun-address CIDR    TUN address; repeatable, replaces both defaults
  --dns-server ADDRESS  DNS-over-TLS server through the proxy (default: 8.8.8.8)
  --extra-settings FILE append a sing-box base.d JSON file
  --no-restore          do not restore the active profile on boot
  --sync-interval SPEC  systemd OnCalendar value (default: daily)
  --trusted-user USER   grant passwordless sudo for skvpn; repeatable
  --uninstall          remove skvpn and settings installed by this script

The CLI goes to \$PREFIX/bin/skvpn, completions to \$PREFIX/share, the base config to
\$SYSCONFDIR/sing-box/base.d, and units to \$SYSTEMD_UNITDIR. python3, systemd, and
sing-box must already be installed; on Arch Linux: pacman -S sing-box
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="${2:?directory required}"
      shift 2
      ;;
    --destdir)
      DESTDIR="${2:?directory required}"
      shift 2
      ;;
    --fix-discord-voice)
      [[ -z "$DISCORD_VOICE_ACTION" ]] || {
        echo "install.sh: Discord voice options are mutually exclusive" >&2
        exit 1
      }
      DISCORD_VOICE_ACTION=enable
      shift
      ;;
    --no-fix-discord-voice)
      [[ -z "$DISCORD_VOICE_ACTION" ]] || {
        echo "install.sh: Discord voice options are mutually exclusive" >&2
        exit 1
      }
      DISCORD_VOICE_ACTION=disable
      shift
      ;;
    --tailscale)
      CONFIG_ARGS+=(--tailscale)
      shift
      ;;
    --direct-russia | --direct-china | --direct-iran)
      CONFIG_ARGS+=(--preset "${1#--direct-}")
      shift
      ;;
    --direct-zone | --direct-geosite | --direct-geoip | --tun-interface | --tun-address | --dns-server)
      CONFIG_ARGS+=("$1" "${2:?value required by $1}")
      shift 2
      ;;
    --extra-settings)
      EXTRA_SETTINGS="${2:?file required}"
      shift 2
      ;;
    --no-restore)
      RESTORE=0
      shift
      ;;
    --sync-interval)
      SYNC_INTERVAL="${2:?calendar specification required}"
      shift 2
      ;;
    --trusted-user)
      TRUSTED_USERS+=("${2:?user required}")
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$PREFIX" != /* ]]; then
  echo "install.sh: PREFIX must be absolute: $PREFIX" >&2
  exit 1
fi
if [[ "$SYSCONFDIR" != /* || "$LOCALSTATEDIR" != /* || "$SYSTEMD_UNITDIR" != /* ]]; then
  echo "install.sh: SYSCONFDIR, LOCALSTATEDIR, and SYSTEMD_UNITDIR must be absolute" >&2
  exit 1
fi
if ((UNINSTALL)) && [[ -n "$DISCORD_VOICE_ACTION" ]]; then
  echo "install.sh: --uninstall already removes the Discord voice fix" >&2
  exit 1
fi
if ((UNINSTALL)) && {
  ((${#CONFIG_ARGS[@]} || !RESTORE || ${#TRUSTED_USERS[@]})) ||
    [[ -n "$EXTRA_SETTINGS" || "$SYNC_INTERVAL" != daily ]]
}; then
  echo "install.sh: --uninstall cannot be combined with configuration options" >&2
  exit 1
fi

here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
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

if [[ -z "$DESTDIR" && ! -x "$SING_BOX" && $UNINSTALL == 0 ]]; then
  if [[ -e /etc/arch-release ]]; then
    echo "install.sh: sing-box is required; install it with: sudo pacman -S sing-box" >&2
  else
    echo "install.sh: sing-box is required; set SING_BOX if it is outside /usr/bin" >&2
  fi
  exit 1
fi
if [[ -z "$DESTDIR" && $UNINSTALL == 0 ]] && ! systemctl cat sing-box@.service >/dev/null 2>&1; then
  echo "install.sh: the sing-box package did not provide sing-box@.service" >&2
  exit 1
fi

disable_discord_voice_fix() {
  local previous

  rm -f "$sysctl_file"
  if [[ -z "$DESTDIR" && -f "$rp_filter_state" ]]; then
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

if ((UNINSTALL)); then
  managed=0
  [[ -n "$DESTDIR" || -f "$managed_state" ]] && managed=1
  if ((managed)) && [[ -z "$DESTDIR" ]]; then
    systemctl disable --now skvpn-sync.timer >/dev/null
    systemctl disable skvpn-restore.service >/dev/null 2>&1 || true
    active_units=()
    while read -r unit _; do
      [[ -n "$unit" ]] && active_units+=("$unit")
    done < <(systemctl list-units --plain --no-legend --state=active 'sing-box@*.service')
    if ((${#active_units[@]})); then
      systemctl stop "${active_units[@]}"
    fi
  fi
  if ((managed)); then
    disable_discord_voice_fix
    rm -f \
      "$base_config" \
      "$extra_config" \
      "$sing_box_dropin" \
      "$unit_root/skvpn-restore.service" \
      "$unit_root/skvpn-sync.service" \
      "$unit_root/skvpn-sync.timer" \
      "$sudoers_file" \
      "$profile_file"
    rmdir "$unit_root/sing-box@.service.d" 2>/dev/null || true
  fi
  rm -f \
    "$root/bin/skvpn" \
    "$root/share/bash-completion/completions/skvpn" \
    "$root/share/zsh/site-functions/_skvpn"
  rm -f "$managed_state"
  rmdir "$state_root" 2>/dev/null || true
  if [[ -z "$DESTDIR" ]]; then
    systemctl daemon-reload
  fi
  echo "removed skvpn from $root and settings installed by this script"
  exit 0
fi

render_args=("${CONFIG_ARGS[@]}")
[[ -n "$DESTDIR" ]] && render_args+=(--skip-path-check)
rendered_base=$(mktemp)
temporary_files=("$rendered_base")
cleanup() { rm -f "${temporary_files[@]}"; }
trap cleanup EXIT
python3 "$here/non-nix/render-base.py" "${render_args[@]}" >"$rendered_base"
if [[ -n "$EXTRA_SETTINGS" ]]; then
  python3 -c 'import json, sys; value = json.load(open(sys.argv[1])); sys.exit(0 if isinstance(value, dict) else "extra settings must be a JSON object")' "$EXTRA_SETTINGS"
fi
if [[ -z "$DESTDIR" ]]; then
  systemd-analyze calendar "$SYNC_INTERVAL" >/dev/null
  id -u "$SERVICE_USER" >/dev/null 2>&1 || {
    echo "install.sh: the sing-box package did not create its service user" >&2
    exit 1
  }
fi
previous_rp_filter=""
if [[ "$DISCORD_VOICE_ACTION" == enable && -z "$DESTDIR" ]]; then
  command -v sysctl >/dev/null || {
    echo "install.sh: sysctl is required by --fix-discord-voice" >&2
    exit 1
  }
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
    if [[ -z "$DESTDIR" ]]; then
      id -u "$user" >/dev/null 2>&1 || {
        echo "install.sh: no such trusted user: $user" >&2
        exit 1
      }
    fi
    printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$skvpn_bin" >>"$rendered_sudoers"
  done
  if [[ -z "$DESTDIR" ]]; then
    command -v visudo >/dev/null || {
      echo "install.sh: sudo is required by --trusted-user" >&2
      exit 1
    }
    chmod 600 "$rendered_sudoers"
    visudo -cf "$rendered_sudoers" >/dev/null
  fi
fi

if [[ -z "$DESTDIR" && ! -f "$managed_state" ]]; then
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

install -Dm755 "$here/skvpn.py" "$root/bin/skvpn"
install -Dm644 "$here/completions/skvpn.bash" "$root/share/bash-completion/completions/skvpn"
install -Dm644 "$here/completions/_skvpn" "$root/share/zsh/site-functions/_skvpn"
install -Dm644 "$rendered_base" "$base_config"
rm -f "$rendered_base"

if [[ -n "$EXTRA_SETTINGS" ]]; then
  install -Dm644 "$EXTRA_SETTINGS" "$extra_config"
else
  rm -f "$extra_config"
fi

if [[ -z "$DESTDIR" ]]; then
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

install -Dm644 /dev/stdin "$sing_box_dropin" <<EOF
[Service]
ExecStart=
ExecStart=$SING_BOX -D $LOCALSTATEDIR/lib/sing-box-%i -C $SYSCONFDIR/sing-box/base.d -c $SYSCONFDIR/sing-box/profiles/%i.json run
EOF

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

else
  if [[ -z "$DESTDIR" ]]; then
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

if ((${#TRUSTED_USERS[@]})); then
  install -Dm440 "$rendered_sudoers" "$sudoers_file"
  install -Dm644 /dev/stdin "$profile_file" <<'EOF'
alias skvpn='sudo skvpn'
EOF
else
  rm -f "$sudoers_file" "$profile_file"
fi

cleanup
trap - EXIT

if [[ "$DISCORD_VOICE_ACTION" == enable ]]; then
  if [[ -z "$DESTDIR" ]]; then
    if [[ ! -f "$rp_filter_state" ]]; then
      install -Dm600 /dev/stdin "$rp_filter_state" <<<"$previous_rp_filter"
    fi
  fi

  install -Dm644 /dev/stdin "$sysctl_file" <<'EOF'
# TUN replies use an asymmetric return path; strict filtering drops tunnelled UDP
net.ipv4.conf.all.rp_filter = 2
EOF

  if [[ -z "$DESTDIR" ]]; then
    sysctl -q -p "$sysctl_file"
  fi
elif [[ "$DISCORD_VOICE_ACTION" == disable ]]; then
  disable_discord_voice_fix
fi

if [[ -z "$DESTDIR" ]]; then
  systemctl daemon-reload
  if ((RESTORE)); then
    systemctl enable skvpn-restore.service >/dev/null
  else
    systemctl disable --now skvpn-restore.service >/dev/null 2>&1 || true
  fi
  systemctl enable --now skvpn-sync.timer >/dev/null
  systemctl try-restart 'sing-box@*.service'
fi

echo "installed to $root/bin/skvpn with completions under $root/share"
