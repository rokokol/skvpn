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
      elif ((COMP_CWORD == 3)) && [[ ${COMP_WORDS[2]} == add ]]; then
        mapfile -t COMPREPLY < <(compgen -W "name path ip" -- "$cur")
      elif ((COMP_CWORD >= 3)) && [[ ${COMP_WORDS[2]} == rm ]]; then
        # What rm can take: the kinds, then the entries of the kind named (name when
        # none is) — from the list itself, minus the declared ones rm cannot touch
        local kind=name
        case "${COMP_WORDS[3]-}" in
          name | path | ip) kind=${COMP_WORDS[3]} ;;
        esac
        mapfile -t COMPREPLY < <(compgen -W "$( ((COMP_CWORD == 3)) && printf 'name path ip\n')
          $(skvpn split ls 2>/dev/null | awk -v kind="$kind" '$1 == kind && $NF != "declared" { print $2 }')" -- "$cur")
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
