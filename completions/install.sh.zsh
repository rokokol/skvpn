# Zsh completion for ./install.sh. Sourced from the checkout, not installed:
#   source completions/install.sh.zsh
# Defines the function and registers it directly — no fpath, no rehash; needs compinit
# to have run, which every interactive zsh with completion already has.
#
# The flag list is written by hand on purpose and checked against install.sh by
# tests/check-completions.sh — same discipline as the bash file
_install_sh_skvpn() {
  _arguments \
    '(-h --help)'{-h,--help}'[show help and exit]' \
    '(-v --version)'{-v,--version}'[print the version and exit]' \
    '--prefix[install prefix]:directory:_files -/' \
    '--destdir[staging root]:directory:_files -/' \
    '--uninstall[remove skvpn and settings installed by this script]' \
    '--no-systemd[skip every live systemctl and sysctl call]' \
    '--fix-discord-voice[loose IPv4 reverse-path filtering for tunnelled UDP]' \
    '--tailscale[keep Tailscale address ranges out of the TUN]' \
    '--docker[keep the docker0 bridge out of the TUN]' \
    '--direct-russia[route Russian zones, geosite and geoip directly]' \
    '--direct-china[route Chinese zones, geosite and geoip directly]' \
    '--direct-iran[route Iranian zones, geosite and geoip directly]' \
    '*--direct-zone[route an additional domain suffix directly]:suffix:' \
    '*--direct-geosite[add a local domain rule-set]:tag=path:' \
    '*--direct-geoip[add a local address rule-set]:tag=path:' \
    '*--split[route a process, executable or CIDR around the tunnel]:kind or value:(name path ip)' \
    '--tun-interface[TUN interface name]:name:' \
    '*--tun-address[TUN address]:cidr:' \
    '--stack[TUN stack]:stack:(system gvisor mixed)' \
    '--no-ipv6[give the TUN no IPv6 address]' \
    '--dns-server[DNS-over-TLS server through the proxy]:address:' \
    '--extra-settings[append a sing-box base.d JSON file]:file:_files' \
    '--no-restore[do not restore the active profile on boot]' \
    '--sync-interval[systemd OnCalendar value]:spec:' \
    '*--trusted-user[grant passwordless sudo for skvpn]:user:_users'
}
compdef _install_sh_skvpn install.sh
