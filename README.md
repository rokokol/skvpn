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
| `skvpn restart` | start the active profile over on the base as it is now — how a changed split list gets onto the wire |
| `skvpn restore` | start the profile chosen for boot — the boot-time half of `up` |
| `skvpn boot [<name> \| last]` | pin a profile for boot regardless of what is up; `last` goes back to following `up`; no argument shows the choice |
| `skvpn split add [name\|path\|ip] <value>…` | route a process (by name, the default), an executable (absolute path) or an address/CIDR around the tunnel; asks for a `skvpn restart` |
| `skvpn split rm [name\|path\|ip] <value>…` | drop split entries; same reminder |
| `skvpn split [ls]` | both split lists — the declared one marked `declared`, then the one `add` edits; no root |
| `skvpn ping [<name>…]` | latency to the ping site through every profile, or the named ones, without switching: one throwaway sing-box carries them all |
| `skvpn ping set <host\|url>` | the site to reach for; a bare host becomes `https://host/`, https only — sing-box's test quietly swaps a plain-http site for its own; default `https://www.google.com/generate_204` |
| `skvpn status --ping` | the status lines, then the ping table |
| `skvpn status` | the active profile, the boot choice (only while boot restore is enabled), the age of the last sync |

Everything that writes or talks to systemd needs root, and so does `ping` (it reads the profiles); `ls --names`, `status`, `split ls` and a bare `boot` do not

`down` forgets the last `up` but leaves a pin alone — pinning is precisely "this one on boot, whatever I switch to meanwhile". A pinned profile that gets deleted or pruned drops its pin, and boot follows the last `up` again. The word `last` is reserved by `boot`, so a profile of that name cannot be pinned

## How it is put together

```
/etc/sing-box/base.d/00-base.json   TUN, DNS, routing — rendered by NixOS or the installer
/etc/sing-box/base.d/50-extra.json  extraSettings, when set
/etc/sing-box/base.d/70-split.json  the imperative split list — written by `skvpn split`
/etc/sing-box/ping.url              the site `skvpn ping` reaches for, when set
/etc/sing-box/profiles/<name>.json  one outbound tagged `proxy` — written by skvpn
/var/lib/skvpn/active               the last profile brought up — what boot follows by default
/var/lib/skvpn/boot                 a profile pinned for boot by `skvpn boot`, beating the above
```

The unit runs `sing-box -C /etc/sing-box/base.d -c /etc/sing-box/profiles/<name>.json`, so the base and the profile merge by sing-box's own rules. The profiles directory lists for everyone while the files stay `0640`: names are how completion works without root, contents carry node credentials

### Ping

`skvpn ping` measures every profile at once without switching: it starts one throwaway sing-box with no inbounds, every profile as an outbound tagged with its name and the Clash API on loopback, asks it for a URL test through each, and stops it. The probe binds to the physical interface and carries the mark the active TUN's `auto_redirect` lets out (`0x2024`, read back from the base if moved), so with a profile up the numbers are still measured outside the tunnel, not inside it. Only the nodes' own hostnames are resolved locally, by the system resolver like the base's bootstrap; the site's name travels to each node and is resolved there, as it does through the tunnel, so nothing DNS-shaped leaves the client to be blocked. Needs root — the profiles are root-only — and a `sing-box` binary: the one on `PATH`, else `/run/current-system/sw/bin`, else `/usr/bin`, overridden by `SKVPN_SING_BOX`. The target lives in `/etc/sing-box/ping.url`

### Split tunnelling

Bypass only: a listed process name, executable path or destination address leaves around the tunnel, everything else keeps going through the proxy. sing-box cannot match a PID, so `path` is the exact knob for a binary whose process name is shared. Names and paths take wildcards — `chrom*`, `/opt/*/bin/tor`, `/nix/store/**/bin/x?` — which sing-box's exact fields cannot, so they are rendered as a regex on the executable's path (`*` one segment, `**` any run, `?` one character) and shown back as the glob. Two lists coexist — the declarative one (`split.names`/`paths`/`ips` on NixOS, `--split` for the installer) is rendered into `00-base.json`, the imperative one (`skvpn split add|rm`) into `70-split.json`, and sing-box's `-C` appends the second after the first. Process kinds also steer their DNS to the local bootstrap resolver, the way direct zones do; on a host where `systemd-resolved`'s stub answers, the resolver is the process the DNS rule sees, while the connection itself still matches and goes direct

**A change needs a restart, and asks for it.** sing-box reads its routing rules only at start, and dropping the tunnel is your call: `skvpn split add`/`rm` write the file and print `<active> is still on the old rules — apply with sudo skvpn restart`; with nothing running they say the rule takes effect on the next `up`. `skvpn split ls` shows both lists, the declared one marked `declared`. Neither `--uninstall` nor a NixOS rebuild touches `70-split.json`: it is state, like the profiles

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
| `split.names` / `split.paths` / `split.ips` | `[ ]` | split tunnelling in the bypass sense: process names, absolute executable paths and destination CIDRs that leave around the tunnel; names and paths take `*`/`?` wildcards, and the process kinds resolve locally too. `skvpn split add` keeps an imperative list beside these |
| `tailscale.enable` | follows `services.tailscale.enable` | keep the tailnet ranges out of the TUN |
| `docker.enable` | follows `virtualisation.docker.enable` | keep Docker bridges out of the TUN: follow the configured default bridge name, bypass dynamic `br-*` interfaces in nftables, and exclude `virtualisation.docker.daemon.settings.default-address-pools` from TUN routes |
| `extraSettings` | `{ }` | a second `base.d` file, merged by sing-box `-C` semantics: objects merge, arrays append, scalars replace |
| `trustedUsers` | `[ ]` | run `skvpn` without typing sudo: a NOPASSWD rule for exactly this command plus a system-wide `skvpn = "sudo skvpn"` alias |
| `restore.enable` | `true` | bring the last active profile back on boot |
| `sync.interval` | `"daily"` | `OnCalendar` for the subscription refresh |
| `fixDiscordVoice` | `true` | loosen the firewall's reverse-path filter (as a default an explicit host value beats): replies to tunnelled UDP arrive on the TUN while the route points at the LAN, and a strict filter drops them — Discord voice is how that shows up |
| `tun.interfaceName`, `tun.address`, `dns.remoteServer` | `skvpn-tun`, `172.19.0.1/30` + ULA, `8.8.8.8` | the base config's fixed points |
| `tun.ipv6` | `true` | give the TUN a v6 address. Turn it off on a host with no IPv6 upstream: `auto_route` otherwise installs a v6 default route to nowhere, and whatever reaches for v6 first waits on it — the DNS strategy does not cover this, because an application carrying its own addresses never asks |
| `tun.stack` | `system` | the TCP/IP stack behind the TUN: `system` handles TCP and UDP with the host stack, `mixed` uses the host for TCP and gVisor for UDP, and `gvisor` handles both in userspace |
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

The NixOS policy options have matching installer flags: `--tailscale`, `--docker`, `--direct-russia`, `--direct-china`, `--direct-iran`, repeatable `--direct-zone`, `--direct-geosite TAG=PATH` and `--direct-geoip TAG=PATH`, repeatable `--split [name|path|ip] VALUE` (the kind defaults to `name`; a process literally called `ip` is `--split name ip`), `--tun-interface`, repeatable `--tun-address`, `--no-ipv6`, `--stack`, `--dns-server`, `--extra-settings`, `--no-restore`, `--sync-interval` and repeatable `--trusted-user`. Country presets use the official Arch rule-set packages:

```sh
sudo pacman -S sing-geoip-rule-set sing-geosite-rule-set
sudo ./install.sh --direct-russia
```

`./install.sh --help` is the complete command reference. The installer is declarative: each run converges the system to exactly the flags given, so repeating a command reproduces its state and omitting a flag — the Discord fix included — undoes what that flag installed, the way unsetting a NixOS option does on rebuild. A re-run while a profile is up restarts that instance by name onto the new base and watches it stay active; if it dies, the previous base files come back, the instance is restarted onto them, and the run fails with the unit's journal — the tunnel never goes down over a bad flag

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
