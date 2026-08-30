# shellcheck shell=bash
# bash completion for skvpn. The command list is spelled here by hand; tests/run.sh checks
# it against skvpn.COMMANDS, so a command added there fails the suite until it lands here
_skvpn() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local cmd=${COMP_WORDS[1]-}

  if ((COMP_CWORD == 1)); then
    mapfile -t COMPREPLY < <(compgen -W "sub add rm ls up down restore status --version" -- "$cur")
    return
  fi

  case "$cmd" in
    up | rm)
      # Live names, not a cached list: the directory is world-listable on purpose
      mapfile -t COMPREPLY < <(compgen -W "$(skvpn ls --names 2>/dev/null)" -- "$cur")
      ;;
    sub)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "set sync" -- "$cur")
      fi
      ;;
    ls)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "--names" -- "$cur")
      fi
      ;;
  esac
}

complete -F _skvpn skvpn
