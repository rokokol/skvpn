# Deviations

Places where this repository departs on purpose from the route the rest of its family takes. Each entry says where, what the usual route is, why it is not taken here and what would make it worth reconsidering

## The CLI's completions stay outside check-sh.sh

**Where:** `completions/skvpn.bash`, `completions/_skvpn`, and their drift check `completions-know-every-command` in `tests/run.sh`

**The usual route:** every repository in the family holds its tool's completion pair to the tool with `check-sh.sh -c` from the [bash-best-practices](https://github.com/rokokol/bash-best-practices-skill) skill, and collects bash candidates with a `while IFS= read -r` loop rather than `mapfile`, which bash gained in 4.0 — a stock macOS sources completions with bash 3.2

**Why not here:** the CLI is `skvpn.py`. `check-sh.sh` reads a dispatcher and its flag parsers out of shell source, finds nothing to read in Python, and refuses the file as having nothing to check. What the completions must follow is `skvpn.COMMANDS`, and `tests/run.sh` imports it and requires every command in both files. skvpn is a client for systemd Linux, where bash is 4 or newer, so `mapfile` in `skvpn.bash` costs nothing. `install.sh` and its completion pair are shell, and they do take the usual route

**What it leaves open:** the check in `tests/run.sh` goes one way and knows commands only — a flag missing from a completion, or one a completion offers that the CLI no longer has, passes

**Reconsidered by:** skvpn running on a system whose bash predates 4.0, its CLI moving to shell, or the family gaining a checker that reads an argparse declaration
