# Pitfalls

Traps in sing-box and the tools around it that produce a plausible but wrong result. Each entry names where it bites, how to reproduce it, the misleading observation, the mechanism and the safe route

---

## A process rule is a silent no-op without two capabilities

**Where it bites:** the unit that runs a profile — `serviceConfig` in `nix/module.nix`, the drop-in `install.sh` writes beside the distribution's unit, and the fixture in `tests/distro.sh` that runs sing-box the way the unit would

**Reproduction:** drop either capability from `caps=` in `tests/distro.sh`, and the distro suite goes red on the process rule

**Misleading result:** a `name` or `path` split entry is accepted, sing-box starts clean, and the listed process still goes through the tunnel. Nothing is logged

**Mechanism:** matching a connection to a process means reading `/proc/<pid>/fd` and `exe` of another user's processes, and the unit runs as `sing-box`. Without `CAP_SYS_PTRACE` and `CAP_DAC_READ_SEARCH` the lookup finds no owner, so the rule never matches. Upstream's unit carries both; `nix/module.nix` mirrors upstream's list, and the installer's drop-in adds the two, because a distribution's unit may be trimmed — the drop-in lines merge into whatever the unit already grants

**Safe route:** keep both capabilities in all three places. A fixture run as root would match processes the unit never could and pass for the wrong reason, which is why `tests/distro.sh` starts sing-box under `setpriv` with exactly the unit's set

---

## A later config file cannot change a scalar

**Where it bites:** every file sing-box merges into one config — `base.d/00-base.json`, `extraSettings` as `50-extra.json`, `70-split.json`, a profile, and the guard's `guard.json` laid over the base

**Reproduction:** two files that set one scalar differently, merged by sing-box 1.14.1

```sh
mkdir -p base.d
echo '{"route":{"final":"proxy"}}' >base.d/00.json
echo '{"route":{"final":"from-50"}}' >base.d/50.json
sing-box merge out.json -C base.d && jq -c .route out.json
```

**Misleading result:** `{"final":"proxy"}`. The later file is accepted without a word, `sing-box check` passes, and a value written to override the base, like `extraSettings.log.level = "debug"`, simply has no effect

**Mechanism:** sing-box reads the `-c` files and the `-C` directories into one list, sorts it by full path and merges in that order (`readConfig` in `cmd/sing-box/cmd_run.go`). The merge keeps a scalar from the first file that sets it, merges objects and appends arrays. Path order also means a profile in `profiles/` and the guard's `guard.json` always come after everything in `base.d/`, whatever the command line says

**Safe route:** treat every file after the base as additive. Add a key the base lacks, or append a rule after the base's rules. The guard follows this: it redefines `proxy` as direct and appends a DNS catch-all to the bootstrap instead of changing `route.final` and `dns.final`

---

## `sing-box check` passes a detour that `run` refuses

**Where it bites:** the guard in `nix/module.nix` and `non-nix/render-base.py`, which turns `proxy` into a direct outbound under a base whose DoT server dials through `proxy`; any config that points a `detour` at a direct outbound

**Reproduction:** the base without its TUN, under a file whose `proxy` is `{"type": "direct", "tag": "proxy"}`, on sing-box 1.14.1

```sh
sing-box check -C base.d -c guard.json && echo check passed
timeout 3 sing-box run -C base.d -c guard.json
```

**Misleading result:** `check passed`, and the unit dies at once with `start service: start dns/tls[remote]: detour to an empty direct outbound makes no sense`

**Mechanism:** the refusal is made when the detour is resolved at start (`common/dialer/detour.go`), not when the config is parsed. A direct outbound counts as empty when its dialer options equal the defaults (`isEmpty` in `protocol/direct/outbound.go`), so any one option set on it lifts the refusal

**Safe route:** prove a config by starting it, as the distro suite does with the guard; `check` proves only that it parses. The guard's `proxy` carries `domain_resolver: "bootstrap"`, the base's own default, so it is not empty and behaves the same

---

## An unanswered AAAA query spends the whole delay budget

**Where it bites:** the throwaway sing-box `skvpn ping` starts, whose config is built in `skvpn.py`, and the base DNS in `nix/module.nix` and `non-nix/render-base.py` that it matches

**Reproduction:** only a network that leaves AAAA queries unanswered shows it, such as the distro suite's containers; a network that answers or refuses AAAA promptly does not

**Misleading result:** every profile reports `timeout`, on every distribution, while the nodes are healthy

**Mechanism:** a lookup whose AAAA query never comes back is held for seconds — the distro suite watched one hold for four — and the delay test's entire budget is `PING_TIMEOUT_MS = 5000`, so it runs out before a single packet reaches the site. `strategy: ipv4_only` asks for A records only

**Safe route:** keep `ipv4_only` in the probe, as in the base. It is load-bearing, not taste

---

## The container engine hands a fixture the observer's resolver

**Where it bites:** both container runs in `tests/distro.sh` — the one per distribution and the one that probes the tunnel from inside a container

**Reproduction:** run the distro suite on a host with skvpn active and drop the flag

**Misleading result:** on a developer's host that runs skvpn, every direct lookup inside the fixture hangs, as if the split rules or the fixture were broken. A host without skvpn never shows it

**Mechanism:** without `--dns`, docker and podman copy the host's `resolv.conf` into the container. A host running skvpn lists its own TUN's DNS there, and inside the container that address is the fixture's blocking TUN, so every lookup sinks into it

**Safe route:** name the resolver on every run, `--dns 1.1.1.1`
