# Changelog

Kept in the shape of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioned by [semver](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Added

- `skvpn ping [<name>…]` measures latency to a site through every profile — or the named ones — without switching: one throwaway sing-box with no inbounds carries every profile as an outbound and answers a Clash-API URL test for each, binding to the physical interface with the mark the active TUN's `auto_redirect` lets out, so the numbers are never taken inside the active tunnel; `skvpn ping set <host|url>` picks the site (https only — sing-box's test swaps a plain-http site for its own without a word; default `https://www.google.com/generate_204`), `skvpn status --ping` appends the table, and `SKVPN_SING_BOX` names the binary when it is not on `PATH`
- split tunnelling, bypass only: the NixOS options `split.names`, `split.paths` and `split.ips` and the installer's repeatable `--split [name|path|ip] VALUE` render process-name, executable-path and CIDR rules routed `direct` into the base (with the process kinds resolving through the local bootstrap too); names and paths take `*`/`?` wildcards, rendered as a `process_path_regex` since sing-box's exact fields take none; `skvpn split add|rm` keeps an imperative list beside them in `base.d/70-split.json` and asks for a `skvpn restart` rather than dropping the tunnel on its own, and `skvpn split ls` shows both lists — `path` stands in for a PID, which sing-box cannot match
- the distro suite now proves split tunnelling and ping on the distribution's own sing-box: with the blocking TUN up, `curl` (declared by name) and `python3` (added by path wildcard) reach out directly while an unlisted process gets no answer, and `skvpn ping` reports milliseconds for a direct profile — which only happens when the probe's mark takes its sockets out of the tunnel
- `skvpn restart`: start the active profile over on the base as it is now, which is how a changed split list — or any other `base.d` edit — gets onto the wire
- `skvpn boot <name>` pins a profile for boot regardless of what is up, `skvpn boot last` goes back to following the last `up`, and a bare `skvpn boot` shows the choice; `restore` starts the pin first, and a pinned profile that is deleted or pruned drops its pin

### Changed

- `skvpn status` shows the `on boot` line only while the restore unit is enabled — with `restore.enable = false` or an install made with `--no-restore` the choice is kept but not what boot does — and spells out `(last up)` when the line is following `up` rather than a pin
- **a re-install keeps the tunnel up**: the installer restarts each active `sing-box@<profile>` by name instead of a glob `try-restart`, watches it stay active for `RESTART_SETTLE_TICKS` half-seconds, and on failure puts the previous `base.d` files and drop-in back, restarts the instance onto them, prints the unit's journal and exits nonzero — the boot choice and profiles are never touched

## [1.1.0] - 2026-08-31

### Added

- NixOS Docker routing now follows the configured default bridge and address pools, and bypasses dynamically named `br-*` interfaces in nftables instead of excluding only `docker0`
- a complete non-NixOS systemd installation with base config, an `ExecStart` drop-in for the package's template unit, boot restore and subscription timer; installer flags for the NixOS routing, Tailscale, TUN, DNS, extra settings and trusted-user options; idempotent `--fix-discord-voice` and `--uninstall`
- dependency preflight with installation guidance for Arch, CachyOS, Debian, Ubuntu and Fedora — every runnable step printed as a `$ command` line, and the distro suite runs exactly those lines, so the guidance cannot rot unnoticed
- `docker.enable` and the matching installer flag `--docker`: keep Docker bridge traffic out of the TUN, following `virtualisation.docker.enable` by default the way the Tailscale exclusion follows its service
- a `VERSION` file as the one place the version lives: `nix/package.nix` reads it, `skvpn --version`/`-v` and `./install.sh --version`/`-v` print it, and CI refuses a release whose `CHANGELOG.md` has no heading for it
- `--uninstall` by manifest: the install writes `share/skvpn/install-manifest` naming every file it created, and uninstall consumes it — installs made before the manifest are still removed by the old fixed list for one release
- `--no-systemd`: a real install that skips every live `systemctl` and `sysctl` call, for containers and image builds without PID 1 systemd
- tab completion for `install.sh` itself (`source completions/install.sh.bash` or `.zsh`), with a drift check that fails the lint when a flag exists in only one of the three places
- distro tests: `tests/distro.sh` installs for real, as root, in `debian`/`ubuntu`/`archlinux`/`fedora` `:latest` containers by running the preflight's own printed guidance, proves a nested Docker daemon can download from Ubuntu repositories through the active TUN, then exercises the CLI and uninstalls by the manifest; CI runs them on every push to master and weekly, never on pull requests, with one README badge per distribution
- `tun.stack` and `--stack`: choose the TUN's TCP/IP stack, retaining `system` as the default
- `tun.ipv6` and `--no-ipv6`: drop the TUN's v6 address on a host with no IPv6 upstream, where `auto_route` otherwise installs a v6 default route to nowhere and whatever reaches for v6 first waits on it

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
