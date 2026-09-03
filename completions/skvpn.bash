# shellcheck shell=bash
# bash completion for skvpn. The command list is spelled here by hand; tests/run.sh checks
# it against skvpn.COMMANDS, so a command added there fails the suite until it lands here
_skvpn() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local cmd=${COMP_WORDS[1]-}

  if ((COMP_CWORD == 1)); then
    mapfile -t COMPREPLY < <(compgen -W "sub add rm ls up down restart restore boot split ping status --version" -- "$cur")
    return
  fi

  case "$cmd" in
    up | rm)
      # Live names, not a cached list: the directory is world-listable on purpose
      mapfile -t COMPREPLY < <(compgen -W "$(skvpn ls --names 2>/dev/null)" -- "$cur")
      ;;
    boot)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "last $(skvpn ls --names 2>/dev/null)" -- "$cur")
      fi
      ;;
    ping)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "set $(skvpn ls --names 2>/dev/null)" -- "$cur")
      else
        mapfile -t COMPREPLY < <(compgen -W "$(skvpn ls --names 2>/dev/null)" -- "$cur")
      fi
      ;;
    status)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "--ping" -- "$cur")
      fi
      ;;
    split)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "ls add rm" -- "$cur")
      elif ((COMP_CWORD == 3)) && [[ ${COMP_WORDS[2]} == add || ${COMP_WORDS[2]} == rm ]]; then
        mapfile -t COMPREPLY < <(compgen -W "name path ip" -- "$cur")
      fi
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
