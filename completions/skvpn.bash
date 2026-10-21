# shellcheck shell=bash
# bash completion for skvpn. The command list is spelled here by hand; tests/run.sh checks
# it against skvpn.COMMANDS, so a command added there fails the suite until it lands here
_skvpn() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local cmd=${COMP_WORDS[1]-}

  if ((COMP_CWORD == 1)); then
    mapfile -t COMPREPLY < <(compgen -W "sub add rm ls up down restart restore boot split ping measure top status export tor --version" -- "$cur")
    return
  fi

  case "$cmd" in
    down)
      mapfile -t COMPREPLY < <(compgen -W "--no-guard" -- "$cur")
      ;;
    up)
      # The tor profile exists once Tor is configured, before its first up writes it
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "$([[ -e /etc/sing-box/tor.json ]] && echo tor) $(skvpn ls --names 2>/dev/null)" -- "$cur")
      elif ((COMP_CWORD == 3)) && [[ ${COMP_WORDS[2]} == tor ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--via" -- "$cur")
      elif ((COMP_CWORD == 4)) && [[ ${COMP_WORDS[3]} == --via ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$(skvpn ls --names 2>/dev/null | grep -vx tor)" -- "$cur")
      fi
      ;;
    tor)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "status bridges" -- "$cur")
      elif ((COMP_CWORD == 3)) && [[ ${COMP_WORDS[2]} == bridges ]]; then
        mapfile -t COMPREPLY < <(compgen -W "ls update add rm" -- "$cur")
      elif ((COMP_CWORD == 4)) && [[ ${COMP_WORDS[3]} == update ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--country" -- "$cur")
      elif ((COMP_CWORD >= 4)) && [[ ${COMP_WORDS[3]} == rm ]]; then
        # The own bridges are the indented two-word lines of `ls`, address second
        mapfile -t COMPREPLY < <(compgen -W "$(skvpn tor bridges ls 2>/dev/null | awk 'NF == 2 && $2 ~ /:/ { print $2 }')" -- "$cur")
      fi
      ;;
    rm)
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
        mapfile -t COMPREPLY < <(compgen -W "set --servers $(skvpn ls --names 2>/dev/null)" -- "$cur")
      else
        mapfile -t COMPREPLY < <(compgen -W "--servers $(skvpn ls --names 2>/dev/null)" -- "$cur")
      fi
      ;;
    measure)
      if [[ ${COMP_WORDS[COMP_CWORD - 1]} == --textfile ]]; then
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      elif ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "set --textfile $(skvpn ls --names 2>/dev/null)" -- "$cur")
      else
        mapfile -t COMPREPLY < <(compgen -W "--textfile $(skvpn ls --names 2>/dev/null)" -- "$cur")
      fi
      ;;
    top)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "--count" -- "$cur")
      fi
      ;;
    export)
      mapfile -t COMPREPLY < <(compgen -W "--sfa --no-tailscale --tor $(skvpn ls --names 2>/dev/null)" -- "$cur")
      ;;
    status)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "--ping" -- "$cur")
      elif ((COMP_CWORD == 3)) && [[ ${COMP_WORDS[2]} == --ping ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--servers" -- "$cur")
      fi
      ;;
    split)
      if ((COMP_CWORD == 2)); then
        mapfile -t COMPREPLY < <(compgen -W "ls add rm" -- "$cur")
      elif ((COMP_CWORD == 3)) && [[ ${COMP_WORDS[2]} == add ]]; then
        mapfile -t COMPREPLY < <(compgen -W "name path ip domain" -- "$cur")
      elif ((COMP_CWORD >= 3)) && [[ ${COMP_WORDS[2]} == rm ]]; then
        # What rm can take: the kinds, then the entries of the kind named (name when
        # none is) — from the list itself, minus the declared ones rm cannot touch
        local kind=name
        case "${COMP_WORDS[3]-}" in
          name | path | ip | domain) kind=${COMP_WORDS[3]} ;;
        esac
        mapfile -t COMPREPLY < <(compgen -W "$( ((COMP_CWORD == 3)) && printf 'name path ip domain\n')
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
        mapfile -t COMPREPLY < <(compgen -W "--names --servers" -- "$cur")
      fi
      ;;
  esac
}

complete -F _skvpn skvpn
