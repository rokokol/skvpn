#!/usr/bin/env bash

set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"

usage() {
  cat <<EOF
install.sh — install skvpn

  PREFIX=$PREFIX (override with PREFIX=... or --prefix DIR)
  DESTDIR=${DESTDIR:-<empty>} (override with DESTDIR=... or --destdir DIR for staging)

The CLI goes to \$PREFIX/bin/skvpn, completions to \$PREFIX/share. Everything it needs —
python3, systemctl — comes from your PATH. The systemd units and the sing-box base config
are the NixOS module's half and are not installed here
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

if [[ -n "$DESTDIR" && "$PREFIX" != /* ]]; then
  echo "install.sh: PREFIX must be absolute when DESTDIR is set: $PREFIX" >&2
  exit 1
fi

here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
root="${DESTDIR%/}$PREFIX"

install -Dm755 "$here/skvpn.py" "$root/bin/skvpn"
install -Dm644 "$here/completions/skvpn.bash" "$root/share/bash-completion/completions/skvpn"
install -Dm644 "$here/completions/_skvpn" "$root/share/zsh/site-functions/_skvpn"

echo "installed to $root/bin/skvpn with completions under $root/share"
