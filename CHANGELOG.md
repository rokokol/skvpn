# Changelog

Kept in the shape of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioned by [semver](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Added

- NixOS Docker routing now follows `virtualisation.docker.daemon.settings.default-address-pools`, covering dynamically named bridge networks instead of only `docker0`; without a pool it follows the configured default bridge name
- a complete non-NixOS systemd installation with base config, an `ExecStart` drop-in for the package's template unit, boot restore and subscription timer; installer flags for the NixOS routing, Tailscale, TUN, DNS, extra settings and trusted-user options; idempotent `--fix-discord-voice` and `--uninstall`
- dependency preflight with installation guidance for Arch, CachyOS, Debian, Ubuntu and Fedora — every runnable step printed as a `$ command` line, and the distro suite runs exactly those lines, so the guidance cannot rot unnoticed
- `docker.enable` and the matching installer flag `--docker`: keep the `docker0` bridge out of the TUN, following `virtualisation.docker.enable` by default the way the Tailscale exclusion follows its service
- a `VERSION` file as the one place the version lives: `nix/package.nix` reads it, `skvpn --version`/`-v` and `./install.sh --version`/`-v` print it, and CI refuses a release whose `CHANGELOG.md` has no heading for it
- `--uninstall` by manifest: the install writes `share/skvpn/install-manifest` naming every file it created, and uninstall consumes it — installs made before the manifest are still removed by the old fixed list for one release
- `--no-systemd`: a real install that skips every live `systemctl` and `sysctl` call, for containers and image builds without PID 1 systemd
- tab completion for `install.sh` itself (`source completions/install.sh.bash` or `.zsh`), with a drift check that fails the lint when a flag exists in only one of the three places
- distro tests: `tests/distro.sh` installs for real, as root, in `debian`/`ubuntu`/`archlinux`/`fedora` `:latest` containers by running the preflight's own printed guidance, then exercises the CLI and uninstalls by the manifest; CI runs them on every push to master and weekly, never on pull requests, with one README badge per distribution

### Changed

- **the installer is declarative**: each run converges the system to exactly the flags given, so a run without `--fix-discord-voice` now removes the fix and restores the saved reverse-path filter value — `--no-fix-discord-voice` is gone, its behavior is the default
- the shell lint's file list lives only in the flake's `scripts-lint` check; the CI shell job builds that check instead of repeating the commands

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
