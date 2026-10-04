# Workarounds

Arrangements that exist only because sing-box leaves no cleaner route. Each entry says what it prevents, why the defect happens and how to tell that it is gone. Traps that stay are in [PITFALLS.md](PITFALLS.md), choices made on purpose in [DEVIATIONS.md](DEVIATIONS.md)

---

## `auto_redirect` marks tailscaled's packets into the TUN

**Where:** the `--tailscale` rules in `nft-bypass.sh`, run as `postStart` of both units in `nix/module.nix` when `tailscale.enable` is on, and as `ExecStartPost` of the drop-in and the guard unit that `install.sh --tailscale` writes

**Symptom it prevents:** two tailnet hosts that both run skvpn reach each other through the exit node instead of directly. `tailscale ping` answers `via <exit node address>` with the exit's round trip, measured at 225 ms against 11 ms direct between two hosts in one city, and ssh over the tailnet stalls with `Timeout before authentication`

**Why it happens:** tailscaled marks its own sockets with `0x80000`, and its `ip rule` sends that mark to the main table, past every other route. sing-tun's `output_udp_icmp` chain ends in `meta mark set 0x00002023`, which overwrites the whole mark; the packet no longer carries `0x80000`, misses tailscaled's rule and is routed into the TUN. The tailnet ranges themselves are already kept out with `route_exclude_address`, but the WireGuard UDP that carries the tailnet goes to the peers' public addresses, which the TUN takes. TCP to DERP takes the same road through the `output` nat chain

**Why this works:** a return for `meta mark & 0x00ff0000 == 0x00080000` at the top of `output_prematch`, `output` and `output_udp_icmp` leaves the mark as tailscaled set it, so its own rule routes the packet

**The exception for an exit node:** a peer that runs on the exit node itself can need the TUN. When the exit's firewall keeps the WireGuard port closed to the world, as a node hidden from DPI does, no direct path past the tunnel exists, and the peer falls back to a DERP relay, which a censor can block too. `tailscale.viaTunnel` on NixOS and `--tailscale-via-tunnel` for the installer name the exit's public addresses. The return rules then hold only for other destinations, one rule per address family, because an `ip daddr` match in an inet table holds only for IPv4. tailscaled's packets to the exit reach the TUN, the exit's proxy sends them to its own public address, and the kernel hands them to the local tailscaled. `tailscale ping` then answers `via <exit address>:<port>` instead of `via DERP(...)`. The address has to be where the traffic leaves the chain: a first hop that forwards to another node sends the packets on, and they arrive at the wrong peer

**Rejected alternative:** a split entry for `tailscaled`. sing-box would route the packets `direct`, but the direct outbound sends them from a new socket and a new port, and WireGuard's NAT traversal depends on the port the peers already know

**Removal check:** with a profile up and the rules not inserted, read the chain sing-box created

```sh
nft list chain inet sing-box output_udp_icmp
```

A `meta mark set 0x00002023` reached by a packet carrying a foreign mark -> keep it. A return for an existing foreign mark, or a mark set that keeps the upper bits -> remove the `--tailscale` rules

**Upstream:** [SagerNet/sing-tun#96](https://github.com/SagerNet/sing-tun/issues/96), open

---

## Replies to inbound UDP leave through the TUN

**Where:** the unconditional first rule of `nft-bypass.sh`, which both units run in `nix/module.nix` and `install.sh`; the `--syncthing` rules cover the half that is not a reply

**Symptom it prevents:** a UDP service on the host stops answering peers on the internet while a profile is up. Syncthing logs `reading length: timeout: no recent network activity` for every QUIC connection with a peer outside the LAN, and falls back to a relay

**Why it happens:** `output_prematch` returns early for `ct direction reply`, but `output_udp_icmp` has no such check, so the answer to a packet that came in on the physical interface is marked `0x00002023` and routed into the TUN. sing-box treats it as a new flow and sends it from the direct outbound's own socket, with a new source port, and the peer drops an answer from a port it never wrote to. TCP is not affected: the redirect lives in a nat chain, which sees only the first packet of a connection

**Why this works:** `ct direction reply return` at the top of `output_udp_icmp` leaves an answer on the host's own routes, out of the interface the question came in on. Syncthing's QUIC also opens connections from its listening port, and a packet that opens a flow is not a reply, so `--syncthing` returns UDP from port 22000 as well

**Removal check:** with a profile up and the rules not inserted

```sh
nft list chain inet sing-box output_udp_icmp
```

No `ct direction reply` before the `meta mark set` -> keep it. One there -> remove the unconditional rule; the `--syncthing` rules stay, since they cover flows that are not replies

**Upstream:** [SagerNet/sing-tun#95](https://github.com/SagerNet/sing-tun/issues/95), open
