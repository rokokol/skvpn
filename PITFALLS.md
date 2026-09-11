# Pitfalls

Traps in sing-box and the tools around it that produce a plausible but wrong result. Each entry names where it bites, the misleading observation, the mechanism and the safe route

## A process rule is a silent no-op without two capabilities

**Where it bites:** the unit that runs a profile — `serviceConfig` in `nix/module.nix`, the drop-in `install.sh` writes beside the distribution's unit, and the fixture in `tests/distro.sh` that runs sing-box the way the unit would

**Misleading result:** a `name` or `path` split entry is accepted, sing-box starts clean, and the listed process still goes through the tunnel. Nothing is logged

**Mechanism:** matching a connection to a process means reading `/proc/<pid>/fd` and `exe` of another user's processes, and the unit runs as `sing-box`. Without `CAP_SYS_PTRACE` and `CAP_DAC_READ_SEARCH` the lookup finds no owner, so the rule never matches. Upstream's unit carries both; `nix/module.nix` mirrors upstream's list, and the installer's drop-in adds the two, because a distribution's unit may be trimmed — the drop-in lines merge into whatever the unit already grants

**Safe route:** keep both capabilities in all three places. A fixture run as root would match processes the unit never could and pass for the wrong reason, which is why `tests/distro.sh` starts sing-box under `setpriv` with exactly the unit's set

**Reproduction boundary:** drop either capability from `caps=` in `tests/distro.sh`, and the distro suite goes red on the process rule

## An unanswered AAAA query spends the whole delay budget

**Where it bites:** the throwaway sing-box `skvpn ping` starts, whose config is built in `skvpn.py`, and the base DNS in `nix/module.nix` and `non-nix/render-base.py` that it matches

**Misleading result:** every profile reports `timeout`, on every distribution, while the nodes are healthy

**Mechanism:** a lookup whose AAAA query never comes back is held for seconds — the distro suite watched one hold for four — and the delay test's entire budget is `PING_TIMEOUT_MS = 5000`, so it runs out before a single packet reaches the site. `strategy: ipv4_only` asks for A records only

**Safe route:** keep `ipv4_only` in the probe, as in the base. It is load-bearing, not taste

**Reproduction boundary:** a network that answers or refuses AAAA promptly does not show it; the distro suite's containers did

## The container engine hands a fixture the observer's resolver

**Where it bites:** both container runs in `tests/distro.sh` — the one per distribution and the one that probes the tunnel from inside a container

**Misleading result:** on a developer's host that runs skvpn, every direct lookup inside the fixture hangs, as if the split rules or the fixture were broken. A host without skvpn never shows it

**Mechanism:** without `--dns`, docker and podman copy the host's `resolv.conf` into the container. A host running skvpn lists its own TUN's DNS there, and inside the container that address is the fixture's blocking TUN, so every lookup sinks into it

**Safe route:** name the resolver on every run, `--dns 1.1.1.1`

**Reproduction boundary:** run the distro suite on a host with skvpn active and drop the flag
