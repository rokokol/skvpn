# shellcheck shell=bash
# Bash completion for ./install.sh. Sourced from the checkout, not installed:
#   source completions/install.sh.bash
# No dependency on the bash-completion package — everything used here is bash builtin.
#
# The flag list is written by hand on purpose and checked against install.sh by
# check-sh.sh -c in scripts-lint: a flag added to the installer fails the gate until it
# lands here and in the zsh file too
_install_sh_skvpn() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  local flags=(
    -h --help -v --version --prefix --destdir --uninstall --no-systemd
    --fix-discord-voice --tailscale --docker
    --direct-russia --direct-china --direct-iran
    --direct-zone --direct-geosite --direct-geoip --split
    --tun-interface --tun-address --stack --no-ipv6 --dns-server
    --extra-settings --no-restore --sync-interval --trusted-user
  )

  case "$prev" in
    --prefix | --destdir)
      compopt -o dirnames 2>/dev/null || true
      COMPREPLY=()
      return
      ;;
    --extra-settings)
      compopt -o default 2>/dev/null || true
      COMPREPLY=()
      return
      ;;
    --trusted-user)
      mapfile -t COMPREPLY < <(compgen -u -- "$cur")
      return
      ;;
    --split)
      mapfile -t COMPREPLY < <(compgen -W "name path ip domain" -- "$cur")
      return
      ;;
    --direct-zone | --direct-geosite | --direct-geoip | --tun-interface | --tun-address | --stack | --dns-server | --sync-interval)
      COMPREPLY=()
      return
      ;;
  esac
  mapfile -t COMPREPLY < <(compgen -W "${flags[*]}" -- "$cur")
}
complete -F _install_sh_skvpn install.sh ./install.sh
