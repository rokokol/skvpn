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
- **`base.d/70-split.json` is CLI-owned state inside a directory the renderers own.** `skvpn split` writes it, neither NixOS nor `install.sh` knows it exists, and `--uninstall` leaves it like a profile. Every split rule is its own rule object routed `direct` because `-C` can only append — that is why the feature is bypass-only. sing-box has no hot reload, and `split add`/`rm` deliberately do **not** restart anything: they print the `skvpn restart` reminder, because dropping the tunnel is the user's call
- **`skvpn boot` reserves the word `last`**, and `skvpn ping` reserves `set`; a profile with either name is reachable only through the forms that take no name
- **the ping probe borrows the TUN's `auto_redirect_output_mark`** (`route.default_mark = 0x2024`, or whatever the base moved it to) so its sockets leave through the physical interface like the active sing-box's own — without it every measurement would be taken inside the active tunnel. Its DNS is the system resolver, and only for the nodes' hostnames: a proxy outbound sends the site's name to the node, which resolves it there, so the probe needs no resolver of its own (DoT direct is blocked in Russia — do not add one). `strategy: ipv4_only` there is load-bearing, not taste: the distro suite watched an unanswered AAAA hold a lookup for four seconds, which is most of the delay test's five — the probe timed out on every distribution until it matched the base. The distro suite runs its outer container with `--dns 1.1.1.1` because docker copies the observer's `resolv.conf`, and a developer's host running skvpn lists its own TUN's DNS there — inside the container that address is the fixture's blocking TUN. And the delay endpoint replaces a plain-http test URL with its own default site without saying so, which is why `ping set` takes https only. The suite's `tests/stub/sing-box` fakes the Clash delay endpoint; `world` unsets `SKVPN_SING_BOX` so a developer's override cannot reach past the stub
- **process rules need `CAP_SYS_PTRACE` and `CAP_DAC_READ_SEARCH` on the unit** — the lookup reads other users' `/proc/<pid>/fd` and `exe`; without them sing-box finds no owner and the rule is a silent no-op, no log line. Upstream's unit has them, `module.nix` mirrors upstream's list, the installer drop-in adds the two, and the distro fixture runs as `sing-box` under `setpriv` with exactly that set so a trimmed unit shows up red
- **`dns.reverse_mapping` is what lets a domain rule reach a nameless connection.** The sniffer only ever reads HTTP and TLS; a game server or any binary protocol has just an address, and without the mapping of DNS answers back to names every `domain_suffix` rule misses it (met live with a Minecraft server). The distro suite's blind request — no Host, no TLS — to a split domain is the check that keeps it on
- **split wildcards are a translation, made three times** — `glob_regex` in `skvpn.py`, its twin in `non-nix/render-base.py`, and `globRegex` in `nix/module.nix` must render the same regex for the same glob, and `regex_glob` in the CLI must read it back; the suite compares the CLI with the installer, the flake pins the module's output

## CHANGELOG

Every user-visible change adds a bullet under `## [Unreleased]` in `CHANGELOG.md`. A release moves those bullets under a new version heading with the date **and bumps `VERSION` in the same commit** — CI refuses a `VERSION` whose heading is missing — then tags `v<x.y.z>` and cuts a `gh release` whose notes are that section. Dates belong in this file and nowhere else — the no-dates rule holds everywhere but here, because Keep a Changelog asks for them
