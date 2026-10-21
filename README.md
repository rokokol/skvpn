<div align="center">

# skvpn

**sing-box profiles as systemd template instances, with the whole client declared in NixOS** ◦°˚\\(\*❛‿❛)/˚°◦

![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)
![sing-box](https://img.shields.io/badge/sing--box-VPN-2B5797?style=flat)
![Nix](https://img.shields.io/badge/Nix-flake-7EBAE4?style=flat&logo=nixos&logoColor=white)
[![FlakeHub](https://img.shields.io/endpoint?url=https://flakehub.com/f/rokokol/skvpn/badge)](https://flakehub.com/flake/rokokol/skvpn)
[![deviations](https://img.shields.io/badge/docs-deviations-555?style=flat)](DEVIATIONS.md)
[![pitfalls](https://img.shields.io/badge/docs-pitfalls-555?style=flat)](PITFALLS.md)
[![workarounds](https://img.shields.io/badge/docs-workarounds-555?style=flat)](WORKAROUNDS.md)
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
  - [Tor](#tor) — `.onion` sites from any program, a SOCKS port, and all traffic through Tor
  - [A phone](#a-phone) — the same profiles and policy on Android, in a few steps
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
| `skvpn ls [--names \| --servers]` | list profiles; `--names` prints bare names and needs no root; `--servers` adds each node's address, kept out of the table otherwise |
| `skvpn up <name>` | sync if stale, [hold](#hold) the network, stop the active profile, start this one, remember it for boot |
| `skvpn up tor [--via <name>]` | send everything that would go to a node through [Tor](#tor) instead; Tor itself leaves direct through its bridges, or through the named node with `--via` |
| `skvpn down [--no-guard]` | stop the active profile and forget the boot choice; with a [guard](#guard) configured, hold the network and start it, or with `--no-guard` leave everything off and let a hold go |
| `skvpn restart` | hold the network and start the active profile over on the base as it is now — how a changed split list gets onto the wire; with only the guard up, the guard |
| `skvpn restore` | start the profile chosen for boot — the boot-time half of `up`; the guard when there is nothing to bring back |
| `skvpn boot [<name> \| last]` | pin a profile for boot regardless of what is up; `last` goes back to following `up`; no argument shows the choice |
| `skvpn split add [name\|path\|ip\|domain] <value>…` | route a process (by name, the default), an executable (absolute path), an address/CIDR or a site (a bare name, a URL or `*.example.com`) around the tunnel; asks for a `skvpn restart` |
| `skvpn split rm [name\|path\|ip\|domain] <value>…` | drop split entries; same reminder |
| `skvpn split [ls]` | both split lists — the declared one marked `declared`, then the one `add` edits; an IDN shows as a person reads it with the wire form beside it, `пример.рф (xn--e1afmkfd.xn--p1ai)`; no root |
| `skvpn ping [--servers] [<name>…]` | latency to the ping site through every profile, or the named ones, without switching: one throwaway sing-box carries them all; `--servers` adds the addresses |
| `skvpn ping set <host\|url>` | the site to reach for; a bare host becomes `https://host/`, https only — sing-box's test quietly swaps a plain-http site for its own; default `https://www.google.com/generate_204` |
| `skvpn status --ping [--servers]` | the status lines, then the ping table |
| `skvpn measure [--textfile PATH] [<name>…]` | latency, time to the first byte and download speed over TCP, round trip and loss over UDP, through every profile or the named ones, without switching; each exit downloads one bounded file in turn; `--textfile` writes [Prometheus metrics](#measure) for node_exporter instead of the table |
| `skvpn measure set <url>` | the file to download, https only; default is a Cloudflare speed-test file |
| `skvpn top [--count N]` | live speed through the tunnel, from the running sing-box; needs the [monitor](#top) option; `d` measures a download through the tunnel; piped, it prints a line a second |
| `skvpn status` | the active profile or the running guard, the boot choice (only while boot restore is enabled), the age of the last sync |
| `skvpn export [<name>]` | the config a profile runs with here — the base, the split list and the profile merged by sing-box itself; the running profile when none is named |
| `skvpn export --sfa [--no-tailscale] [--tor] [<name>…]` | a whole config for [a phone](#a-phone); `--tor` adds Orbot as one more exit and as the way to `.onion` sites |
| `skvpn tor [status]` | the state of skvpn's [Tor](#tor): the unit, how far it has bootstrapped, its bridges and its SOCKS address |
| `skvpn tor bridges [ls]` | the bridges Tor has, by kind, with their country and age, and the address of each of your own; no root |
| `skvpn tor bridges update [--country CC]` | fetch fresh bridges from the Tor Project's Moat service and reload Tor; the country follows the preset the base routes direct |
| `skvpn tor bridges add [<line>…]` | add bridges of your own, such as the lines a bridge bot hands out, as arguments or pasted on stdin; an update keeps them |
| `skvpn tor bridges rm <address>…` | remove bridges of your own by the address `ls` shows |

Everything that writes or talks to systemd needs root, and so do `ping`, `measure` and `top` (the profiles and the API secret are root-only); `ls --names`, `status`, `split ls` and a bare `boot` do not

`down` forgets the last `up` but leaves a pin alone — pinning is precisely "this one on boot, whatever I switch to meanwhile". A pinned profile that gets deleted or pruned drops its pin, and boot follows the last `up` again. The word `last` is reserved by `boot`, so a profile of that name cannot be pinned

## How it is put together

```
/etc/sing-box/base.d/00-base.json   TUN, DNS, routing — rendered by NixOS or the installer
/etc/sing-box/base.d/50-extra.json  extraSettings, when set
/etc/sing-box/base.d/70-split.json  the imperative split list — written by `skvpn split`
/etc/sing-box/guard.json            the guard laid over the base, when one is configured
/etc/sing-box/ping.url              the site `skvpn ping` reaches for, when set
/etc/sing-box/measure.url           the file `skvpn measure` downloads, when set
/etc/sing-box/base.d/60-clash.json  the Clash API for `skvpn top` — written at start by the NixOS `monitor` option, never by hand
/var/lib/skvpn/clash-secret         that API's secret, root-only
share/skvpn/policy.json             presets, the tailnet and the rule-sets' sources — installed beside the CLI
/etc/sing-box/tor.json              the sing-box half of the `tor` profile, when Tor is on
/etc/sing-box/torrc                 Tor's own config — rendered with tor.json
/etc/sing-box/tor-resolv.conf       the resolver Tor's unit sees — rendered with tor.json
/etc/sing-box/tor-nsswitch.conf     the name service Tor's unit sees — rendered with tor.json
/var/lib/skvpn/tor-bridges.d/       Tor's bridges — moat.conf by `skvpn tor bridges update`, own.conf by `bridges add`
/etc/sing-box/profiles/<name>.json  one outbound tagged `proxy` — written by skvpn
/var/lib/skvpn/active               the last profile brought up — what boot follows by default
/var/lib/skvpn/boot                 a profile pinned for boot by `skvpn boot`, beating the above
```

The unit runs `sing-box -C /etc/sing-box/base.d -c /etc/sing-box/profiles/<name>.json`, so the base and the profile merge by sing-box's own rules. The profiles directory lists for everyone while the files stay `0640`: names are how completion works without root, contents carry node credentials

### Ping

`skvpn ping` measures every profile at once without switching: it starts one throwaway sing-box with no inbounds, every profile as an outbound tagged with its name and the Clash API on loopback, asks it for a URL test through each, and stops it. The probe binds to the physical interface and carries the mark the active TUN's `auto_redirect` lets out (`0x2024`, read back from the base if moved), so with a profile up the numbers are still measured outside the tunnel, not inside it. Only the nodes' own hostnames are resolved locally, by the system resolver like the base's bootstrap; the site's name travels to each node and is resolved there, as it does through the tunnel, so nothing DNS-shaped leaves the client to be blocked. Needs root — the profiles are root-only — and a `sing-box` binary: the one on `PATH`, else `/run/current-system/sw/bin`, else `/usr/bin`, overridden by `SKVPN_SING_BOX`. The target lives in `/etc/sing-box/ping.url`

### Measure

`skvpn measure` is `ping` taken further, on the same kind of throwaway sing-box: each exit also gets a local proxy port and a local UDP port that lead through that exit only. Per exit it reports the TCP latency `ping` reports, the time to the first byte and the download speed of one bounded https file fetched through the exit, and the round trip and loss of a few DNS queries sent through the exit over UDP, so a node whose UDP is broken shows up. Latency and the UDP queries run for all exits at once; the downloads run one exit at a time, because a download fills the link and two at once would measure each other. A download cut off at its time limit still counts, and a reply that is not the answer to the query asked does not. The file defaults to a Cloudflare speed-test file and `skvpn measure set <url>` changes it, https only for the reason `ping` gives. Needs root, a `sing-box` binary as `ping` does, and `curl`

`--textfile PATH` writes the result as Prometheus text for node_exporter's textfile collector instead of printing a table: the file is replaced whole, so the collector never reads half of one, and a profile that is gone drops out of it. Every sample is labelled with the profile name and nothing else, so no node address reaches a dashboard. An exit that could not do a thing has no sample for it rather than a zero, and `skvpn_exit_up` and `skvpn_udp_up` say whether it could. On NixOS the `measure` options run this on a timer

| Metric | What it says |
| --- | --- |
| `skvpn_exit_up` | 1 when the exit carried a TCP request |
| `skvpn_tcp_latency_seconds` | time to the first header of a HEAD through the exit |
| `skvpn_tcp_ttfb_seconds` | time to the first byte of the download |
| `skvpn_tcp_download_bytes_per_second` | download speed after the first byte |
| `skvpn_udp_up` | 1 when at least one DNS query came back |
| `skvpn_udp_rtt_seconds` | median round trip of the answered queries |
| `skvpn_udp_loss_ratio` | share of the queries that got no answer |
| `skvpn_measure_timestamp_seconds`, `skvpn_measure_duration_seconds` | when the run ended and how long it took, with no label |

### Top

`skvpn top` shows the speed through the running tunnel live, read from sing-box's Clash API. The live base has no such API by default: on NixOS turn on `monitor.enable`, which opens the API on loopback only and guards it with a secret, because a loopback API without one would let any local user reset the network. **Turning it on restarts the running tunnel once**, the way any change to the base does, and turning it off restarts it again. The secret is made on the first start and kept in a file only root reads, and `top` reads the address and the secret from the live base, refusing an address that is not loopback. A non-Nix install has no option for it: add an `experimental.clash_api` with a secret to a file in `base.d` by hand

On a terminal `top` redraws a screen with the current and peak speed in both directions, a short history of the received speed and the totals. `d` starts a download through the tunnel and shows its speed, to see what the tunnel can do right now; the monitor counts that download too, so rx rises while it runs, and the screen says so. `q` quits. Piped, it prints one line a second, and `--count N` stops after N of them

### Split tunnelling

Bypass only: a listed process name, executable path, destination address or site leaves around the tunnel, everything else keeps going through the proxy. A `domain` entry is the same rule as `direct.zones` / `--direct-zone`, taking a bare name, a URL, `*.example.com` or a whole zone as `.ru` (`example.com` covers its subdomains too, `mail.example.com` only what sits under it): it matches the name the client asked for — sniffed or answered — never an address, so a CDN sharing its addresses with the world changes nothing; a site pulling resources from other domains needs those listed too. A connection that carries no name — a game server, any binary protocol the sniffer cannot read — still meets the rule, because the base keeps a reverse mapping of every DNS answer it gave and hands the name back to the connection; only an app that arrives with a ready address, never having asked, is not caught. One trap: a name that is only an SRV record (a Minecraft server address, say) sends the client to *another* name, and that is the name the connection carries — list the SRV target, `dig SRV _minecraft._tcp.<name>` shows it; a CNAME needs nothing, the address is remembered under the name asked for. sing-box cannot match a PID, so `path` is the exact knob for a binary whose process name is shared. Names and paths take wildcards — `chrom*`, `/opt/*/bin/tor`, `/nix/store/**/bin/x?` — which sing-box's exact fields cannot, so they are rendered as a regex on the executable's path (`*` one segment, `**` any run, `?` one character) and shown back as the glob. Two lists coexist — the declarative one (`split.names`/`paths`/`ips` on NixOS, `--split` for the installer) is rendered into `00-base.json`, the imperative one (`skvpn split add|rm`) into `70-split.json`, and sing-box's `-C` appends the second after the first. Process kinds also steer their DNS to the local bootstrap resolver, the way direct zones do; on a host where `systemd-resolved`'s stub answers, the resolver is the process the DNS rule sees, while the connection itself still matches and goes direct

**A change needs a restart, and asks for it.** sing-box reads its routing rules only at start, and dropping the tunnel is your call: `skvpn split add`/`rm` write the file and print `<active> is still on the old rules — apply with sudo skvpn restart`; with nothing running they say the rule takes effect on the next `up`. `skvpn split ls` shows both lists, the declared one marked `declared`. Neither `--uninstall` nor a NixOS rebuild touches `70-split.json`: it is state, like the profiles

### Guard

With nothing up, every site is reached from your own address, and some services hold that against the account. The guard is what "off" means once you give it something to refuse: `skvpn down` starts a sing-box on the same base that sends everything direct but refuses the listed sites, both the name lookup and the connection, matched by the name asked for or the TLS name sent. Boot starts it when there is no profile to bring back, and `skvpn up` stops it. The AI preset refuses the AI services that turn sanctioned regions away, from a rule-set pinned like the country presets; your own zones and rule-sets add to it. A process or site on the split list still leaves direct, the same as with a profile up

### Hold

A switch stops one sing-box and starts another, and in between traffic would leave from your own address. So `up`, `restart` and a `down` to the guard first hold the network: the `inet skvpn-hold` nftables table refuses this host's outgoing traffic until the new sing-box is ready and removes it. A sing-box that fails holds it too, until its restart is up. The hold fails closed: **if nothing comes up, `skvpn down --no-guard` lets the network go**, and so does a reboot

Still let out: loopback, replies to inbound connections, DHCP, private addresses, and what `tailscale.enable` and `syncthing.enable` keep past the TUN, so `ssh` over the tailnet reaches a held host. Not held: boot, a NixOS rebuild that restarts the tunnel, `systemctl` typed by hand, and traffic the host forwards for containers

### Tor

With `tor.enable` on NixOS, or `--tor` for the installer, skvpn runs a Tor of its own beside the tunnel. A profile switch never touches it, so it does not bootstrap again on every `up`. It gives three things:

- `.onion` sites open from any program, with no proxy set up: the base hands their names a fake address and routes the connection to Tor, whatever profile or guard runs
- a SOCKS port on loopback, for Tor Browser or any program set up for a proxy
- `skvpn up tor`, the `tor` profile: everything that would go to a node goes through Tor instead, a way out for when every node is down. `--via <name>` takes Tor's own traffic through that node instead of direct

Tor reaches the network through bridges only, and starts once `skvpn tor bridges update` has fetched them from the Tor Project. The country of the bridges is the one whose preset the base routes direct, so a host with the Russian preset gets bridges meant for Russia; with no preset or with several, `--country` names it. Bridges are never replaced behind your back: an update is a command you run when the ones you have stop working

Moat hands out bridges from a public pool, and those are the first a censor finds and blocks. The Tor Project's Telegram and email bots hand out bridges from other pools: paste their lines into `sudo skvpn tor bridges add`, and Tor uses them beside Moat's. An update replaces only Moat's

The `tor` profile is a fallback, not anonymity. Only TCP goes through Tor, so calls, games and other UDP stop working, and QUIC falls back to TCP. Direct zones and the split list still leave direct, as with any profile. Each site gets a circuit of its own, but an account you are logged in to names you whatever the circuit: the profile hides your address, not who you are. For anonymity use Tor Browser on the SOCKS port

`tor` is the profile's reserved name, so a share link or a subscription entry called `tor` is skipped. `ping`, `measure` and `export --sfa` leave it out unless it is named

### A phone

1. Install sing-box for Android (SFA) from the [Play Store](https://play.google.com/store/apps/details?id=io.nekohasekai.sfa), [F-Droid](https://f-droid.org/packages/io.nekohasekai.sfa/) or the [releases](https://github.com/SagerNet/sing-box/releases)
2. On the host, `sudo skvpn export --sfa > phone.json`
3. Move `phone.json` to the phone over a channel you trust with passwords, and delete it from the host and the channel afterwards
4. In SFA, Profiles → + → Local → Import, and pick the file
5. Turn off any other VPN app on the phone, Tailscale included: Android runs one at a time, and this config carries the tailnet itself
6. Start the profile from the Dashboard
7. With Tailscale on the host, open Tools → Endpoints → tailnet once and follow the login link; a later re-import keeps the phone the same tailnet node
8. To be "off" while keeping the guarded sites refused, switch the mode card on the Dashboard from Rule to Direct; stopping SFA turns everything off

To update the phone after the subscription or the policy changes, run step 2 again and import the new file over the old profile

For Tor on the phone, install [Orbot](https://orbot.app/), turn on Settings → Power User Mode so that it runs as a proxy without a VPN of its own, start it, and export with `--tor`. The selector then has a `tor` exit beside the nodes, and `.onion` sites go to Orbot from every app. Orbot's own traffic leaves direct, and Orbot fetches its own bridges

`sudo skvpn export --sfa` writes one config for [sing-box for Android](https://sing-box.sagernet.org/clients/android/) that carries the host's policy to the phone. Every profile, or the named ones, sits in one group the app switches between on the fly. Sites the host sends direct go direct here too, with the rule-sets fetched through the node by URL; process entries of the split list stay behind, since they name the host's programs. The LAN stays outside the tunnel, so devices there still reach the phone. When the host runs Tailscale, the phone joins the tailnet from inside the same app, since Android lets only one VPN run at a time; the app shows the login link under Tools → Endpoints. When the host has a guard, the app gets a Direct mode beside the usual Rule one: switching to it sends everything direct but keeps refusing the guarded sites, which is the phone's way of being off. The file carries the nodes' credentials, so move it the way you would move a password

### Living beside other tunnels

Tailscale, Syncthing and Docker keep their own paths while a profile or the guard is up: tailscaled's peer traffic stays off the tunnel, so two hosts on one network reach each other directly rather than through the exit; Syncthing's QUIC keeps the port its peers know; containers on any Docker bridge reach the network as before. Each follows the matching service on NixOS and is a flag for the installer. A UDP service answering the internet keeps working either way — why it needed help is in [WORKAROUNDS.md](WORKAROUNDS.md)

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
| `direct.bittorrent.enable` | `false` | BitTorrent leaves around the tunnel, for an exit that refuses it or a host that forwards its abuse reports: the common clients go direct whole, as split names that `skvpn split ls` shows as declared, and any other client's traffic goes direct wherever the sniffer recognises the protocol. An unlisted client still sends encrypted TCP peers, DHT and HTTPS trackers through the tunnel, and a client run by an interpreter (Deluge, BiglyBT) can only be caught this second way |
| `direct.zones` | `[ ]` | domain suffixes resolved by the local bootstrap and routed past the tunnel |
| `direct.geosite` / `direct.geoip` | `{ }` | local binary rule-sets routed direct, keyed by tag; local on purpose — a remote set would arrive through the tunnel it is meant to steer |
| `split.names` / `split.paths` / `split.ips` | `[ ]` | split tunnelling in the bypass sense: process names, absolute executable paths and destination CIDRs that leave around the tunnel; names and paths take `*`/`?` wildcards, and the process kinds resolve locally too. `skvpn split add` keeps an imperative list beside these |
| `guard.ai.enable` | `false` | while no profile is up, refuse AI services: the AI rule-set [policy.json](policy.json) names, pinned in this flake's lock. It is wide on purpose and catches developer tools too |
| `guard.zones` / `guard.geosite` | `[ ]` / `{ }` | more domain suffixes and local rule-sets for the guard to refuse; any of the three turns the guard on |
| `tailscale.enable` | follows `services.tailscale.enable` | keep the tailnet ranges and tailscaled's own peer traffic out of the TUN |
| `docker.enable` | follows `virtualisation.docker.enable` | keep Docker bridges out of the TUN: follow the configured default bridge name, bypass dynamic `br-*` interfaces in nftables, and exclude `virtualisation.docker.daemon.settings.default-address-pools` from TUN routes |
| `syncthing.enable` | follows `services.syncthing.enable` | keep Syncthing's QUIC on the port its peers know |
| `extraSettings` | `{ }` | a second `base.d` file, merged by sing-box's own rules: objects merge, arrays append, and a scalar the base already sets stays the base's ([PITFALLS.md](PITFALLS.md)) |
| `tor.enable` | `false` | run skvpn's own [Tor](#tor): `.onion` sites from any program, a SOCKS port and the `tor` profile |
| `tor.socksPort` | see the module | the loopback port of the SOCKS proxy Tor offers programs |
| `tor.package`, `tor.transportPackage` | `pkgs.tor`, `pkgs.obfs4` | the Tor that runs, and the package whose `lyrebird` runs its transports |
| `trustedUsers` | `[ ]` | run `skvpn` without typing sudo: a NOPASSWD rule for exactly this command plus a system-wide `skvpn = "sudo skvpn"` alias |
| `restore.enable` | `true` | bring the last active profile back on boot |
| `sync.interval` | `"daily"` | `OnCalendar` for the subscription refresh |
| `measure.enable` | `false` | run [`skvpn measure`](#measure) on a timer as a root oneshot with a memory cap and a time limit; each run downloads a bounded file through every exit, so it costs that traffic |
| `measure.interval` | `"1h"` | the wait from the end of one run to the start of the next, so a slow run never overlaps the next |
| `measure.textfile` | `null` | where the metrics go for node_exporter's textfile collector; `null` prints the table to the journal |
| `monitor.enable` | `false` | open the Clash API on loopback behind a root-made secret for [`skvpn top`](#top); turning it on or off restarts the tunnel once |
| `monitor.port` | see the module | the API's loopback port |
| `fixDiscordVoice` | `true` | loosen the firewall's reverse-path filter (as a default an explicit host value beats): replies to tunnelled UDP arrive on the TUN while the route points at the LAN, and a strict filter drops them — Discord voice is how that shows up |
| `tun.interfaceName`, `tun.address`, `dns.remoteServer` | `skvpn-tun`, `172.19.0.1/30` + ULA, `1.1.1.1` | the base config's fixed points |
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
sudo pacman -S sing-box nftables
sudo ./install.sh                     # PREFIX=/usr/local; --prefix/--destdir supported
sudo ./install.sh --fix-discord-voice # loosen IPv4 reverse-path filtering for tunnelled UDP
sudo ./install.sh --uninstall         # remove everything by the install manifest
./install.sh --version                # skvpn x.y.z, from the VERSION file
```

The Arch package supplies the binary, service user and template unit. The installer adds the base config, an `ExecStart` drop-in for skvpn's split base/profile layout, boot restore and the daily subscription timer, and writes an install manifest under `share/skvpn` naming every file it created — `--uninstall` consumes that manifest, so it removes exactly what was written and leaves profiles, the subscription and active-profile state intact. With `--destdir` files are only staged; `--no-systemd` is a real install that skips every live `systemctl` and `sysctl` call, for containers and image builds

Debian and Ubuntu use the [official sing-box APT repository](https://sing-box.sagernet.org/installation/package-manager/#repository-installation). Its package supplies the same binary, template unit and service user expected by the installer. A preflight checks all runtime dependencies before writing files and prints distro-specific guidance when anything is missing — every runnable line as `$ command`, exactly what to type; nothing is ever installed on your behalf

The NixOS policy options have matching installer flags: `--tailscale`, `--docker`, `--syncthing`, `--tor`, `--tor-socks-port`, `--guard-ai`, repeatable `--guard-zone` and `--guard-geosite TAG=PATH`, `--direct-russia`, `--direct-china`, `--direct-iran`, `--direct-bittorrent`, repeatable `--direct-zone`, `--direct-geosite TAG=PATH` and `--direct-geoip TAG=PATH`, repeatable `--split [name|path|ip|domain] VALUE` (the kind defaults to `name`; a process literally called `ip` is `--split name ip`), `--tun-interface`, repeatable `--tun-address`, `--no-ipv6`, `--stack`, `--dns-server`, `--extra-settings`, `--no-restore`, `--sync-interval` and repeatable `--trusted-user`. `--tor` needs Tor and a transport for it — `lyrebird`, or the older `obfs4proxy` and `snowflake-client` that Debian, Ubuntu and Fedora ship — and the preflight names the packages; on Arch, `tor` is in the repositories and `lyrebird-proxy` comes from the AUR. Country presets use the official Arch rule-set packages:

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
