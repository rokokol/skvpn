# CLAUDE.md

## What this repo is

A sing-box VPN client for systemd Linux. `skvpn.py` is the CLI: it turns share links or a subscription into profile files — one outbound tagged `proxy` each — under `/etc/sing-box/profiles`, and switches them as `sing-box@<name>` systemd template instances. `nix/module.nix` declares the whole mechanism on NixOS: the template unit, boot restore, subscription sync timer, the `sing-box` user, and a generic base config (TUN, DNS, routing skeleton) rendered from options into `/etc/sing-box/base.d`. `install.sh` and `non-nix/render-base.py` install the equivalent mechanism elsewhere, with installer flags matching the NixOS policy options

The seam in `rokokol/huix` is `nixos/services/system/skvpn.nix`: enable plus the routing policy (RU zones, geosite/geoip rule-sets from its own flake inputs)

## Build / check

```sh
nix build
nix flake check          # suite, packaged CLI, module wiring, real-nixpkgs eval, shell lint
./tests/run.sh           # a scratch SKVPN_ROOT in, profiles and systemctl calls out
./tests/run.sh --update  # rewrite tests/golden from the current parser output
PREFIX=$PWD/out ./install.sh
./tests/distro.sh debian # real root install in docker; also ubuntu, arch, fedora
nix fmt -- --ci
```

## Layout

```
skvpn.py             the CLI
VERSION              the one place the version lives — package.nix, --version and CI read it
completions/         skvpn.bash, _skvpn and the install.sh completions, spelled by hand
nix/                 package.nix, module.nix, module-test.nix, nixos-eval.nix
tests/               run.sh, distro.sh, check-completions.sh, stubs, golden parser outputs
install.sh           installer and option parser for systems without Nix
non-nix/             renderer for the non-Nix base config
```

## Things that will bite

- **`SKVPN_ROOT` relocates every path at once** — that is the whole test strategy: no root, no live `/etc/sing-box`, and the suite stubs `systemctl` so "what is running" is its decision. The stub guard refuses to start unless every stub is executable and first on `PATH`
- **the completion command lists are hand-written on purpose** and the suite checks them against `skvpn.COMMANDS` — a command added to the CLI fails the tests until it lands in both completion files. The same holds for install.sh: `tests/check-completions.sh` diffs its `case` patterns against both `completions/install.sh.*` files in `scripts-lint`
- **install.sh is declarative** — a run converges the system to exactly the flags given, and every file it writes lands in `share/skvpn/install-manifest`, which is what `--uninstall` consumes. The preflight's runnable guidance lines are printed as `  $ command` and `tests/distro.sh` executes exactly those lines — change the format and the distro suite goes blind
- **profile names are public, contents are not.** The profiles directory is `2755` so `ls --names` (and completion through it) works without root; the files stay `0640` because they carry node credentials. `cmd_ls` must keep treating a per-file `PermissionError` as "try sudo", not as a crash
- **the subscription tests run on `file://` URLs** — `urlopen` speaks the scheme, which is what lets sync's prune/spare logic run offline. The real fetch sends a custom `User-Agent`: the stock `Python-urllib` one gets 403 from Cloudflare bot rules
- **`extraSettings` merges by sing-box `-C` semantics** (objects merge, arrays append, scalars replace) because it is written as a second `base.d` file — it cannot change a scalar inside an existing array element, and that is documented in the option, not worked around

## CHANGELOG

Every user-visible change adds a bullet under `## [Unreleased]` in `CHANGELOG.md`. A release moves those bullets under a new version heading with the date **and bumps `VERSION` in the same commit** — CI refuses a `VERSION` whose heading is missing — then tags `v<x.y.z>` and cuts a `gh release` whose notes are that section. Dates belong in this file and nowhere else — the no-dates rule holds everywhere but here, because Keep a Changelog asks for them
