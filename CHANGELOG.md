# Changelog

Kept in the shape of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioned by [semver](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Added

- a complete non-NixOS systemd installation with base config, an `ExecStart` drop-in for the package's template unit, boot restore and subscription timer; installer flags for the NixOS routing, Tailscale, TUN, DNS, extra settings and trusted-user options; idempotent `--fix-discord-voice`, rollback with `--no-fix-discord-voice`, and `--uninstall`
- dependency preflight with installation guidance for Arch, CachyOS, Debian and Ubuntu
- `tun.stack` and `--stack`: the TUN's TCP/IP stack, now `mixed` — sing-box's own default — instead of a hardcoded `system`
- `tun.ipv6` and `--no-ipv6`: drop the TUN's v6 address on a host with no IPv6 upstream, where `auto_route` otherwise installs a v6 default route to nowhere and whatever reaches for v6 first waits on it
- `up` and `status` name a system proxy when they find one: a TUN never sees what an application hands to a local proxy instead, so a leftover proxy from another client silently keeps the browser and every Electron app off the tunnel

## [1.0.0] - 2026-08-29

Split out of [rokokol/huix](https://github.com/rokokol/huix), where it was a script and a service module in the NixOS configuration

### Added

- `skvpn sub|add|rm|ls|up|down|restore|status`: sing-box profiles from share links or a subscription, switched as `sing-box@<name>` systemd template instances
- bash and zsh completions; profile names complete live via `skvpn ls --names`, which needs no root because the profiles directory lists for everyone while the files stay `0640`
- `trustedUsers`: a NOPASSWD sudo rule plus a `skvpn = "sudo skvpn"` alias, so listed users type neither sudo nor a password
- `nixosModules.default` carrying the whole mechanism — the template unit, boot restore (optional via `restore.enable`), daily subscription sync, the service user — and a generic base config: TUN, DNS with a local bootstrap, a Tailscale exclusion toggle, direct zones and local rule-sets as policy knobs, `extraSettings` merged by sing-box's own `-C` semantics
- country presets `direct.russia.enable` / `direct.china.enable` / `direct.iran.enable`: the domestic zone suffixes (IDN ccTLDs included) plus the matching geosite/geoip rule-sets, pinned in this flake's own lock and refreshed by the weekly lock bump
- credential hygiene: profile files and the subscription URL are created with their final mode already tight, the sync stamp carries no URL, and a subscription entry can never overwrite a profile added by hand
- `overlays.default`, `install.sh` for systems without Nix
- checks: the suite against a scratch `SKVPN_ROOT` with a stubbed `systemctl` and a `file://` subscription, golden files for the three link parsers, module wiring against stubs and against the real nixpkgs module set, shell lint
