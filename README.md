<div align="center">

# skvpn

**sing-box profiles as systemd template instances, with the whole client declared in NixOS** ◦°˚\\(\*❛‿❛)/˚°◦

![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)
![sing-box](https://img.shields.io/badge/sing--box-VPN-2B5797?style=flat)
![Nix](https://img.shields.io/badge/Nix-flake-7EBAE4?style=flat&logo=nixos&logoColor=white)
[![license](https://img.shields.io/badge/MIT-3DA639?style=flat)](LICENSE)
[![build](https://github.com/rokokol/skvpn/actions/workflows/build.yml/badge.svg)](https://github.com/rokokol/skvpn/actions/workflows/build.yml)
[![debian](https://github.com/rokokol/skvpn/actions/workflows/distro-debian.yml/badge.svg)](https://github.com/rokokol/skvpn/actions/workflows/distro-debian.yml)
[![ubuntu](https://github.com/rokokol/skvpn/actions/workflows/distro-ubuntu.yml/badge.svg)](https://github.com/rokokol/skvpn/actions/workflows/distro-ubuntu.yml)
[![arch](https://github.com/rokokol/skvpn/actions/workflows/distro-arch.yml/badge.svg)](https://github.com/rokokol/skvpn/actions/workflows/distro-arch.yml)
[![fedora](https://github.com/rokokol/skvpn/actions/workflows/distro-fedora.yml/badge.svg)](https://github.com/rokokol/skvpn/actions/workflows/distro-fedora.yml)

</div>

A profile is one file holding a single outbound tagged `proxy`; everything shared — the TUN, DNS, routing — is one base config the NixOS module renders from options. Switching profiles is starting a different instance of one systemd template unit:

```sh
sudo skvpn sub set https://my-panel.example/sub/…   # store the subscription, pull the profiles
sudo skvpn up SE-1                                  # and the tunnel is up
skvpn ls --names                                    # no root needed — and <TAB> knows it too
```

The last active profile comes back on boot, the subscription refreshes daily and on every `up`, and a node the subscription dropped is pruned — unless it is the one running

Came over from my rice, **[rokokol/huix](https://github.com/rokokol/huix)**

## Contents

- [Commands](#commands)
- [How it is put together](#how-it-is-put-together)
- [NixOS module](#nixos-module)
- [Completions](#completions)
- [Install](#install)
- [Tests](#tests)

## Commands

| Command | What it does |
| --- | --- |
| `skvpn sub set <url>` | store a subscription and sync it right away |
| `skvpn sub sync [--if-stale]` | refresh profiles from the stored subscription; `--if-stale` only after a day |
| `skvpn add <uri>…` | add profiles from `vless://`, `hysteria2://`/`hy2://` or `trojan://` share links |
| `skvpn rm <name>…` | delete profiles; the running one is refused |
| `skvpn ls [--names]` | list profiles; `--names` prints bare names and needs no root |
| `skvpn up <name>` | sync if stale, stop the active profile, start this one, remember it for boot |
| `skvpn down` | stop the active profile and forget the boot choice |
| `skvpn restore` | start the remembered profile — the boot-time half of `up` |
| `skvpn status` | the active profile, the boot choice, the age of the last sync |

Everything that writes or talks to systemd needs root; `ls --names` and `status` do not

## How it is put together

```
/etc/sing-box/base.d/00-base.json   TUN, DNS, routing — rendered by NixOS or the installer
/etc/sing-box/base.d/50-extra.json  extraSettings, when set
/etc/sing-box/profiles/<name>.json  one outbound tagged `proxy` — written by skvpn
/var/lib/skvpn/active               the profile to bring back on boot
```

The unit runs `sing-box -C /etc/sing-box/base.d -c /etc/sing-box/profiles/<name>.json`, so the base and the profile merge by sing-box's own rules. The profiles directory lists for everyone while the files stay `0640`: names are how completion works without root, contents carry node credentials

Subscription bodies are fetched with a custom `User-Agent` — Cloudflare's bot rules answer 403 to the stock Python one. Profiles you `add` by hand are never overwritten or pruned by a sync: the manifest remembers which names came from the subscription. The converse holds too — an `add` over a subscription-owned name keeps that name in the manifest, so the next sync writes the subscription's version back

## NixOS module

The module owns the mechanism — the `sing-box@` template unit, boot restore, the sync timer, the service user, the base config. The routing policy is yours:

```nix
{
  imports = [ inputs.skvpn.nixosModules.default ];

  services.skvpn = {
    enable = true;

    # Russian destinations leave directly instead of dying on an exit that refuses them:
    # zone suffixes plus the geosite/geoip rule-sets pinned in this flake's own lock
    direct.russia.enable = true;

    # Your own additions, same shape as what the preset provides
    direct.zones = [ ".by" ];
    direct.geosite.geosite-custom = ./my-set.srs;

    # Follows services.tailscale.enable by default: with both running, the tailnet is
    # unreachable through the TUN unless its ranges are excluded
    tailscale.enable = true;
  };
}
```

| Option | Default | What it does |
| --- | --- | --- |
| `direct.russia.enable`, `direct.china.enable`, `direct.iran.enable` | `false` | country presets: the domestic zone suffixes (IDN ccTLDs included) plus the matching geosite/geoip rule-sets, pinned in this flake's lock and refreshed by its weekly lock bump |
| `direct.zones` | `[ ]` | domain suffixes resolved by the local bootstrap and routed past the tunnel |
| `direct.geosite` / `direct.geoip` | `{ }` | local binary rule-sets routed direct, keyed by tag; local on purpose — a remote set would arrive through the tunnel it is meant to steer |
| `tailscale.enable` | follows `services.tailscale.enable` | keep the tailnet ranges out of the TUN |
| `docker.enable` | follows `virtualisation.docker.enable` | keep Docker bridges out of the TUN: use `virtualisation.docker.daemon.settings.default-address-pools` for all dynamic bridges, falling back to the configured default bridge name or `docker0` |
| `extraSettings` | `{ }` | a second `base.d` file, merged by sing-box `-C` semantics: objects merge, arrays append, scalars replace |
| `trustedUsers` | `[ ]` | run `skvpn` without typing sudo: a NOPASSWD rule for exactly this command plus a system-wide `skvpn = "sudo skvpn"` alias |
| `restore.enable` | `true` | bring the last active profile back on boot |
| `sync.interval` | `"daily"` | `OnCalendar` for the subscription refresh |
| `fixDiscordVoice` | `true` | loosen the firewall's reverse-path filter (as a default an explicit host value beats): replies to tunnelled UDP arrive on the TUN while the route points at the LAN, and a strict filter drops them — Discord voice is how that shows up |
| `tun.interfaceName`, `tun.address`, `dns.remoteServer` | `skvpn-tun`, `172.19.0.1/30` + ULA, `8.8.8.8` | the base config's fixed points |
| `package`, `singBoxPackage` | this flake's CLI, `pkgs.sing-box` | what to install and what the unit runs |

## Completions

bash and zsh, installed by the package. Subcommands are spelled in the completion files and checked against the CLI's own command table by the test suite; profile names are completed live through `skvpn ls --names`, so `sudo skvpn up <TAB>` offers what is actually on disk

## Install

As a flake input:

```nix
inputs.skvpn = {
  url = "github:rokokol/skvpn";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

then import `inputs.skvpn.nixosModules.default` and enable as above. Without the module, `packages.default` and `overlays.default` carry the bare CLI. On Arch Linux without Nix:

```sh
sudo pacman -S sing-box
sudo ./install.sh                     # PREFIX=/usr/local; --prefix/--destdir supported
sudo ./install.sh --fix-discord-voice # loosen IPv4 reverse-path filtering for tunnelled UDP
sudo ./install.sh --uninstall         # remove everything by the install manifest
./install.sh --version                # skvpn x.y.z, from the VERSION file
```

The Arch package supplies the binary, service user and template unit. The installer adds the base config, an `ExecStart` drop-in for skvpn's split base/profile layout, boot restore and the daily subscription timer, and writes an install manifest under `share/skvpn` naming every file it created — `--uninstall` consumes that manifest, so it removes exactly what was written and leaves profiles, the subscription and active-profile state intact. With `--destdir` files are only staged; `--no-systemd` is a real install that skips every live `systemctl` and `sysctl` call, for containers and image builds

Debian and Ubuntu use the [official sing-box APT repository](https://sing-box.sagernet.org/installation/package-manager/#repository-installation). Its package supplies the same binary, template unit and service user expected by the installer. A preflight checks all runtime dependencies before writing files and prints distro-specific guidance when anything is missing — every runnable line as `$ command`, exactly what to type; nothing is ever installed on your behalf

The NixOS policy options have matching installer flags: `--tailscale`, `--docker`, `--direct-russia`, `--direct-china`, `--direct-iran`, repeatable `--direct-zone`, `--direct-geosite TAG=PATH` and `--direct-geoip TAG=PATH`, `--tun-interface`, repeatable `--tun-address`, `--dns-server`, `--extra-settings`, `--no-restore`, `--sync-interval` and repeatable `--trusted-user`. Country presets use the official Arch rule-set packages:

```sh
sudo pacman -S sing-geoip-rule-set sing-geosite-rule-set
sudo ./install.sh --direct-russia
```

`./install.sh --help` is the complete command reference. The installer is declarative: each run converges the system to exactly the flags given, so repeating a command reproduces its state and omitting a flag — the Discord fix included — undoes what that flag installed, the way unsetting a NixOS option does on rebuild

Tab completion for the installer itself is in the checkout: `source completions/install.sh.bash` (or `completions/install.sh.zsh`), and `./install.sh --<TAB>` knows every flag above

## Tests

```sh
./tests/run.sh           # scratch SKVPN_ROOT, stubbed systemctl, file:// subscriptions
./tests/run.sh --update  # rewrite the golden parser outputs
nix flake check          # the suite, the packaged CLI, module wiring, a real-nixpkgs eval, shell lint
./tests/distro.sh debian # real root install in a docker container: preflight → its own printed
                         # guidance → install → smoke → uninstall; also ubuntu, arch, fedora
```

The distro suite runs in CI on every push to master and weekly against each distribution's `:latest` image — the badges above are its verdicts — but never on pull requests, so a flaky mirror cannot redden a change
