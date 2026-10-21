# NixOS module: the whole client except the policy. It owns the CLI, the sing-box@<profile>
# template unit, the boot restore and subscription sync units, the sing-box user and the
# profiles directory, plus a generic base config — TUN, DNS, routing skeleton. What it ships
# none of is the routing policy: direct zones and rule-sets come from the consumer's options
{
  self,
  policy,
  ruleSetFiles,
}:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.skvpn;

  # Countries whose domestic destinations commonly have to leave around the tunnel, from
  # policy.json, which the installer's renderer and the CLI read too. A list there, so two
  # enabled presets render the same base on every eval. The rule-set data behind the tags
  # is pinned in this flake's own lock
  presets = map (
    preset:
    preset
    // {
      geosite = "geosite-${preset.tag}";
      geoip = "geoip-${preset.tag}";
    }
  ) policy.presets;
  enabledPresets = lib.filter (preset: cfg.direct.${preset.name}.enable) presets;

  # The consumer's knobs plus whatever presets are on
  directZones = lib.unique (cfg.direct.zones ++ lib.concatMap (preset: preset.zones) enabledPresets);
  presetFiles =
    key:
    lib.listToAttrs (
      map (preset: lib.nameValuePair preset.${key} ruleSetFiles.${preset.${key}}) enabledPresets
    );
  directGeosite = presetFiles "geosite" // cfg.direct.geosite;
  directGeoip = presetFiles "geoip" // cfg.direct.geoip;

  dockerSettings = config.virtualisation.docker.daemon.settings or { };
  dockerBridge = dockerSettings.bridge or "docker0";
  dockerAddressPools =
    if cfg.docker.enable then
      map (pool: pool.base) (dockerSettings.default-address-pools or [ ])
    else
      [ ];
  routeExcludeAddress = lib.optionals cfg.tailscale.enable policy.tailnet ++ dockerAddressPools;

  # Tags double as attribute names, so a rule-set is declared exactly once; geosite first,
  # geoip second — a stable order, not an alphabetical accident
  ruleSetTags = lib.attrNames directGeosite ++ lib.attrNames directGeoip;

  # Split entries with wildcards become process_path_regex, the exact fields taking none:
  # `*` one path segment, `**` any run, `?` one character; a name pattern matches the
  # executable's basename. The same translation skvpn.py makes for `split add`
  isGlob = pattern: lib.hasInfix "*" pattern || lib.hasInfix "?" pattern;
  globRegex =
    kind: pattern:
    (if kind == "name" then "(^|/)" else "^")
    + lib.replaceStrings [ "\\*\\*" "\\*" "\\?" ] [ ".*" "[^/]*" "[^/]" ] (lib.escapeRegex pattern)
    + "$";
  # The BitTorrent clients join the split names: each under its own name and the one a
  # Nix wrapper runs as, which is what sing-box reads off /proc/<pid>/exe
  bittorrentNames = lib.optionals cfg.direct.bittorrent.enable (
    lib.concatMap (name: [
      name
      ".${name}-wrapped"
    ]) policy.bittorrent.clients
  );
  splitNames = lib.unique (lib.filter (p: !isGlob p) cfg.split.names ++ bittorrentNames);
  splitPaths = lib.filter (p: !isGlob p) cfg.split.paths;
  splitRegex =
    map (globRegex "name") (lib.filter isGlob cfg.split.names)
    ++ map (globRegex "path") (lib.filter isGlob cfg.split.paths);

  # An entry that would match sing-box itself: its traffic never enters the tunnel, and
  # a pattern wide enough to catch it (`*`, `/**`) catches everything — the tunnel off.
  # The same refusal `skvpn split add` and the installer make
  singBoxExe = lib.getExe cfg.singBoxPackage;
  catchesSingBox =
    kind: pattern:
    let
      targets =
        if kind == "name" then
          [
            "sing-box"
            (baseNameOf singBoxExe)
          ]
        else
          [ singBoxExe ];
    in
    if isGlob pattern then
      lib.any (t: builtins.match (globRegex kind pattern) t != null) targets
    else
      lib.elem pattern targets;
  splitCatchesSingBox =
    lib.filter (catchesSingBox "name") cfg.split.names
    ++ lib.filter (catchesSingBox "path") cfg.split.paths;

  ruleSetFile = tag: path: {
    inherit tag;
    type = "local";
    format = "binary";
    path = "${path}";
  };

  # Return rules sing-box's own auto_redirect table lacks, inserted once it exists: the
  # flags are the policy, the rules live in the script the installer runs too. Every
  # subcommand takes the same flags, so the hold lets past what the TUN would
  bypass =
    subcommand:
    lib.concatStringsSep " " (
      [ "${cfg.package}/libexec/skvpn/nft-bypass ${subcommand}" ]
      ++ lib.optional cfg.tailscale.enable "--tailscale"
      ++ lib.optional cfg.docker.enable "--docker"
      ++ lib.optional cfg.syncthing.enable "--syncthing"
    );
  bypassCommand = bypass "apply";

  # The guard is what runs while no profile is up, and exists only with something to refuse
  guardGeosite =
    lib.optionalAttrs cfg.guard.ai.enable {
      "geosite-${policy.guard.tag}" = ruleSetFiles."geosite-${policy.guard.tag}";
    }
    // cfg.guard.geosite;
  guardMatches =
    lib.optional (cfg.guard.zones != [ ]) { domain_suffix = cfg.guard.zones; }
    ++ lib.optional (guardGeosite != { }) { rule_set = lib.attrNames guardGeosite; };
  guardEnabled = guardMatches != [ ];

  # Laid over the same base as a profile is. sing-box merges every file sorted by path, the
  # first scalar winning and arrays appending, so this file cannot move `final` and its
  # rules land after the base's and the split list's (PITFALLS.md). It needs neither:
  # `proxy` itself is direct here, and a listed site is refused before `final` is reached
  guardConfig = {
    outbounds = [
      {
        type = "direct";
        tag = "proxy";
        # The base's DoT server dials through `proxy`, and sing-box refuses to start a detour
        # to a direct outbound with every dialer option at its default (PITFALLS.md). This
        # one restates the base's own default resolver, which changes nothing but that
        domain_resolver = "bootstrap";
      }
    ];
    dns.rules =
      map (
        match:
        match
        // {
          action = "predefined";
          rcode = "REFUSED";
        }
      ) guardMatches
      # Everything else to the local resolver: `final` stays the base's DoT server, which
      # would now be dialled direct, and a DoT server dialled direct is blocked in Russia
      ++ [
        {
          action = "route";
          server = "bootstrap";
        }
      ];
    route = {
      rules = map (match: match // { action = "reject"; }) guardMatches;
      rule_set = lib.mapAttrsToList ruleSetFile guardGeosite;
    };
  };

  # skvpn's own Tor, from the constants policy.json holds for the CLI and the renderer too
  tor = policy.tor;
  torLocal = {
    server = "127.0.0.1";
    server_port = tor.routePort;
  };
  torBridges = "/var/lib/skvpn/tor-bridges.d";
  torUser = [ tor.user ];

  # The sing-box half of the `tor` profile, which `skvpn up tor` copies into the profiles:
  # `proxy` is Tor's SOCKS, and Tor's own traffic, matched by its user, leaves direct — or
  # through the node `--via` puts in place of `direct` — rather than back into itself.
  # Names go to Tor's DNSPort, except Tor's own, which it needs before it can resolve
  # anything: a transport looks up its broker's name before the first circuit exists
  torProfile = {
    outbounds = [
      (
        {
          type = "socks";
          tag = "proxy";
        }
        // torLocal
      )
    ];
    dns = {
      servers = [
        {
          tag = "tor";
          type = "udp";
          server = "127.0.0.1";
          server_port = tor.dnsPort;
        }
      ];
      rules = [
        {
          user = torUser;
          action = "route";
          server = "bootstrap";
        }
        {
          action = "route";
          server = "tor";
        }
      ];
    };
    route.rules = [
      {
        user = torUser;
        outbound = "direct";
      }
      # Tor's SOCKS carries no UDP; refused at once, QUIC falls back to TCP at once
      {
        network = [ "udp" ];
        action = "reject";
      }
    ];
  };

  # The second SOCKS port is the one sing-box dials, isolating by destination so two sites
  # never share a circuit; the first is the user's. The bridges directory is CLI state:
  # `skvpn tor bridges update` writes Moat's file in it, and `bridges add` the user's own
  torrc = ''
    DataDirectory /var/lib/skvpn-tor
    SocksPort 127.0.0.1:${toString cfg.tor.socksPort}
    SocksPort 127.0.0.1:${toString tor.routePort} IsolateDestAddr
    DNSPort 127.0.0.1:${toString tor.dnsPort}
    ClientTransportPlugin ${lib.concatStringsSep "," tor.transports} exec ${lib.getExe' cfg.tor.transportPackage "lyrebird"}
    UseBridges 1
    %include ${torBridges}
  '';

  # Bound over Tor's /etc/resolv.conf: render-base.py's tor_resolv says why, and why a
  # fallback follows. sing-box serves DNS on the address after the TUN's IPv4 one
  tun4 = lib.findFirst (address: !lib.hasInfix ":" address) null cfg.tun.address;
  torResolv =
    let
      octets = lib.splitString "." (lib.head (lib.splitString "/" tun4));
      next = lib.toInt (lib.last octets) + 1;
    in
    ''
      nameserver ${lib.concatStringsSep "." (lib.init octets ++ [ (toString next) ])}
      nameserver ${cfg.dns.remoteServer}
      options timeout:2
    '';
  # Bound over Tor's /etc/nsswitch.conf, with nscd hidden: render-base.py's tor_nsswitch
  torNsswitch = "hosts: files dns\n";

  # The Clash API file for `skvpn top`, written at every start by root. It cannot be an
  # etc entry: the secret would sit in the world-readable store. The secret lives in a
  # root-only file and is made once; base.d gets a copy only the sing-box group reads, and
  # a rename puts it in place whole. With the option off the script removes both, or a
  # file from the time it was on would open the API again
  clashFile = "/etc/sing-box/base.d/60-clash.json";
  clashSecret = "/var/lib/skvpn/clash-secret";
  clashScript = pkgs.writeShellScript "skvpn-clash-api" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.jq
      ]
    }
    ${
      if cfg.monitor.enable then
        ''
          umask 077
          install -d -m 0755 /var/lib/skvpn
          [ -s ${clashSecret} ] || head -c 24 /dev/urandom | base64 | tr -d '=+/\n' >${clashSecret}
          # A hidden name without the .json suffix, which sing-box does not read
          temp=$(mktemp /etc/sing-box/base.d/.60-clash.XXXXXX)
          jq -n --arg controller 127.0.0.1:${toString cfg.monitor.port} --rawfile secret ${clashSecret} \
            '{experimental: {clash_api: {external_controller: $controller, secret: $secret}}}' >"$temp"
          chgrp sing-box "$temp"
          chmod 0640 "$temp"
          mv -f "$temp" ${clashFile}
        ''
      else
        ''
          rm -f ${clashFile} ${clashSecret}
        ''
    }
  '';

  # What a profile instance and the guard share; only the config and state paths differ
  singBoxService = {
    after = [
      "network-online.target"
      "nss-lookup.target"
    ];
    wants = [ "network-online.target" ];

    path = [ pkgs.nftables ];
    # The bypass step also lets the hold go, once the TUN carries the traffic
    postStart = bypassCommand;

    serviceConfig = {
      # A crash holds the network until the restart is up; a stop on purpose does not
      ExecStopPost = bypass "hold --if-failed";
      User = "sing-box";
      # Upstream's own set. The last two are what a process rule runs on; without them
      # every split entry is silently a no-op (PITFALLS.md)
      CapabilityBoundingSet = [
        "CAP_NET_ADMIN"
        "CAP_NET_RAW"
        "CAP_NET_BIND_SERVICE"
        "CAP_SYS_PTRACE"
        "CAP_DAC_READ_SEARCH"
      ];
      AmbientCapabilities = [
        "CAP_NET_ADMIN"
        "CAP_NET_RAW"
        "CAP_NET_BIND_SERVICE"
        "CAP_SYS_PTRACE"
        "CAP_DAC_READ_SEARCH"
      ];
      # The + runs it as root whatever User says: it writes under /etc and /var/lib
      ExecStartPre = "+${clashScript}";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      Restart = "on-failure";
      RestartSec = "10s";
      LimitNOFILE = "infinity";
    };
  };

  baseConfig = {
    log = {
      level = "warn";
      timestamp = true;
    };

    # Without a bootstrap the first query waits on the tunnel that waits on the query
    dns = {
      servers = [
        {
          tag = "bootstrap";
          type = "local";
        }
        {
          tag = "remote";
          type = "tls";
          server = cfg.dns.remoteServer;
          detour = "proxy";
          domain_resolver = "bootstrap";
        }
      ]
      ++ lib.optional cfg.tor.enable {
        tag = "onion";
        type = "fakeip";
        inet4_range = tor.fakeip;
      };
      # A .onion name gets an address from the fake range, and the connection to it carries
      # the name back, which a route rule sends to Tor; no resolver knows these names.
      # Direct names resolve outside the tunnel too, or the answer is geo-wrong and the
      # query travels to a node that may refuse to carry it
      rules =
        lib.optional cfg.tor.enable {
          domain_suffix = [ tor.onion ];
          action = "route";
          server = "onion";
        }
        ++ lib.optional (directZones != [ ]) {
          domain_suffix = directZones;
          action = "route";
          server = "bootstrap";
        }
        ++ lib.optional (directGeosite != { }) {
          rule_set = lib.attrNames directGeosite;
          action = "route";
          server = "bootstrap";
        }
        # A bypassed process resolves outside the tunnel too; addresses have no DNS side
        ++ lib.optional (splitNames != [ ]) {
          process_name = splitNames;
          action = "route";
          server = "bootstrap";
        }
        ++ lib.optional (splitPaths != [ ]) {
          process_path = splitPaths;
          action = "route";
          server = "bootstrap";
        }
        ++ lib.optional (splitRegex != [ ]) {
          process_path_regex = splitRegex;
          action = "route";
          server = "bootstrap";
        };
      final = "remote";
      strategy = "ipv4_only";
      # Remember which name each answered address stood for, so a connection that
      # carries no name of its own — a game server, anything the sniffer cannot read —
      # still meets the domain rules. Without it only HTTP and TLS ever had a name
      reverse_mapping = true;
    };

    inbounds = [
      (
        {
          type = "tun";
          tag = "tun-in";
          interface_name = cfg.tun.interfaceName;
          inherit (cfg.tun) address;
          auto_route = true;

          # auto_route alone puts its table behind main, so locally-originated TCP never
          # reaches it
          auto_redirect = true;
          strict_route = false;
          stack = cfg.tun.stack;
        }
        # Keep fixed overlay ranges out of the TUN. Tailscale owns protocol-wide ranges;
        # Docker's configured pool covers its default and dynamically named bridges
        // lib.optionalAttrs (routeExcludeAddress != [ ]) {
          route_exclude_address = routeExcludeAddress;
        }
        # Docker's default bridge has a configured stable name; dynamically named br-*
        # bridges are excluded in the unit's postStart nftables rules below
        // lib.optionalAttrs cfg.docker.enable {
          exclude_interface = [ dockerBridge ];
        }
      )
    ];

    outbounds = [
      {
        type = "direct";
        tag = "direct";
      }
    ]
    # The port that isolates by destination, so two sites never share one circuit
    ++ lib.optional cfg.tor.enable (
      {
        type = "socks";
        tag = "tor";
      }
      // torLocal
    );

    route = {
      auto_detect_interface = true;
      default_domain_resolver = "bootstrap";

      # hijack-dns before ip_is_private: the TUN's own DNS address is private and would be
      # lost. .onion ahead of every direct rule: a connection that fell through to one of
      # them would leave in the clear and fail
      rules = [
        { action = "sniff"; }
        {
          protocol = "dns";
          action = "hijack-dns";
        }
      ]
      ++ lib.optional cfg.tor.enable {
        domain_suffix = [ tor.onion ];
        outbound = "tor";
      }
      ++ [
        {
          ip_is_private = true;
          outbound = "direct";
        }
      ]
      ++ lib.optional (directZones != [ ]) {
        domain_suffix = directZones;
        outbound = "direct";
      }
      ++ lib.optional (ruleSetTags != [ ]) {
        rule_set = ruleSetTags;
        outbound = "direct";
      }
      # Split tunnelling, bypass only: one rule per field, each routed direct
      ++ lib.optional (splitNames != [ ]) {
        process_name = splitNames;
        outbound = "direct";
      }
      ++ lib.optional (splitPaths != [ ]) {
        process_path = splitPaths;
        outbound = "direct";
      }
      ++ lib.optional (splitRegex != [ ]) {
        process_path_regex = splitRegex;
        outbound = "direct";
      }
      ++ lib.optional (cfg.split.ips != [ ]) {
        ip_cidr = cfg.split.ips;
        outbound = "direct";
      }
      # Any client the list misses, where the sniffer can read it: plain TCP handshakes,
      # uTP and UDP tracker requests
      ++ lib.optional cfg.direct.bittorrent.enable {
        protocol = [ "bittorrent" ];
        outbound = "direct";
      };

      rule_set =
        lib.mapAttrsToList ruleSetFile directGeosite ++ lib.mapAttrsToList ruleSetFile directGeoip;

      final = "proxy";
    };
  };
in
{
  options.services.skvpn = {
    enable = lib.mkEnableOption "the skvpn sing-box client";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "skvpn";
      description = "The skvpn CLI to install and run the units with";
    };

    singBoxPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sing-box;
      defaultText = lib.literalExpression "pkgs.sing-box";
      description = "The sing-box the template unit runs";
    };

    tun = {
      interfaceName = lib.mkOption {
        type = lib.types.str;
        default = "skvpn-tun";
        description = "Name of the TUN interface the client creates";
      };

      ipv6 = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Give the TUN an IPv6 address. Turn this off on a host with no IPv6 upstream:
          auto_route otherwise installs a v6 default route to nowhere, and everything that
          reaches for v6 first — Happy Eyeballs in the browsers, the addresses baked into
          Telegram — waits on it. The DNS strategy does not cover this: it only decides what
          sing-box itself resolves, and an application carrying its own addresses never asks.
          Ignored once `address` is set by hand
        '';
      };

      address = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "172.19.0.1/30" ] ++ lib.optional cfg.tun.ipv6 "fdfe:dcba:9876::1/126";
        defaultText = lib.literalExpression ''[ "172.19.0.1/30" "fdfe:dcba:9876::1/126" ]'';
        description = "Addresses of the TUN interface; change on a collision with a real network";
      };

      stack = lib.mkOption {
        type = lib.types.enum [
          "system"
          "gvisor"
          "mixed"
        ];
        default = "system";
        description = ''
          The TCP/IP stack behind the TUN. `system` handles TCP and UDP with the host stack;
          `mixed` uses the host stack for TCP and gVisor for UDP; `gvisor` handles both in
          userspace
        '';
      };
    };

    dns.remoteServer = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
      description = "DNS-over-TLS server queried through the tunnel for everything not routed direct";
    };

    tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.services.tailscale.enable or false;
      defaultText = lib.literalExpression "config.services.tailscale.enable";
      description = ''
        Keep the tailnet ranges out of the TUN. A tailnet address pulled into the tunnel
        answers over `lo`, and Tailscale's antispoof rule drops any tailnet source that did
        not arrive on `tailscale0` — so with both running, the tailnet is unreachable unless
        it is excluded here
      '';
    };

    docker.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.virtualisation.docker.enable or false;
      defaultText = lib.literalExpression "config.virtualisation.docker.enable";
      description = ''
        Keep Docker bridge networks out of the TUN. The default bridge follows
        `daemon.settings.bridge`, or `docker0` when unset; dynamically named `br-*` bridges
        are bypassed by nftables. Configured `daemon.settings.default-address-pools` are
        also excluded from the TUN routes
      '';
    };

    syncthing.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.services.syncthing.enable or false;
      defaultText = lib.literalExpression "config.services.syncthing.enable";
      description = ''
        Let UDP from Syncthing's default listening port, 22000, leave by the host's routes.
        Through the TUN its QUIC leaves the direct outbound from a fresh port, and a peer
        that knows this host as `address:22000` never hears back. Its TCP and its relay and
        discovery traffic keep going through the tunnel
      '';
    };

    direct =
      lib.listToAttrs (
        map (
          preset:
          lib.nameValuePair preset.name {
            enable = lib.mkEnableOption "" // {
              description = ''
                Route ${preset.label} destinations around the tunnel: the
                ${lib.concatStringsSep ", " (map (z: "`${z}`") preset.zones)} zone suffixes plus
                the `${preset.geosite}` and `${preset.geoip}` rule-sets pinned in this flake's
                own lock — for exits that refuse or geo-mangle that traffic. The suffixes carry
                most of it: a geosite set always misses plenty
              '';
            };
          }
        ) presets
      )
      // {
        bittorrent.enable = lib.mkEnableOption "" // {
          description = ''
            Route BitTorrent around the tunnel, for exits that refuse it or whose host
            answers its abuse reports. Two rules: the clients `policy.json` names join the
            split names, each also as the `.NAME-wrapped` a Nix wrapper runs as, so all their
            traffic and DNS leave direct; and the `bittorrent` protocol the sniffer detects
            leaves direct whatever the process. The sniffer reads plain handshakes, uTP and
            UDP tracker requests only, so an unlisted client still sends encrypted TCP peers,
            DHT and HTTPS trackers through the tunnel. A client run by an interpreter, such
            as Deluge on Python or BiglyBT on Java, has the interpreter's name and is never
            on the list
          '';
        };

        zones = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            ".ru"
            ".su"
          ];
          description = ''
            Domain suffixes that bypass the tunnel: resolved by the bootstrap resolver and
            routed to the direct outbound. This is the policy knob for destinations the exit
            node refuses or answers geo-wrong
          '';
        };

        geosite = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = { };
          example = lib.literalExpression "{ geosite-ru = ./geosite-category-ru.srs; }";
          description = ''
            Local binary rule-sets of domains routed direct, keyed by tag. Domain-based, so
            they also steer DNS to the bootstrap resolver. Local on purpose: a remote rule-set
            would have to come through the tunnel, so the client would refuse to start exactly
            when the node is down
          '';
        };

        geoip = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = { };
          example = lib.literalExpression "{ geoip-ru = ./geoip-ru.srs; }";
          description = "Local binary rule-sets of addresses routed direct, keyed by tag; no DNS side";
        };
      };

    guard = {
      ai.enable = lib.mkEnableOption "" // {
        description = ''
          Refuse AI services while no profile is up: the
          `${lib.removeSuffix ".srs" policy.guard.geosite}` rule-set pinned in this flake's own lock — the services outside China, which are the ones
          that refuse sanctioned regions. It is wide on purpose and catches developer tools
          too, `comfy.org` and `coderabbit.ai` among them
        '';
      };

      zones = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "openai.com" ];
        description = ''
          Domain suffixes refused while no profile is up: `openai.com` is the site and its
          subdomains, `.openai.com` only the subdomains. Any entry here or in `ai` or
          `geosite` turns the guard on: `skvpn down` then starts a sing-box on the same base
          that sends everything direct and refuses these, by the name the client asked for
          or the TLS name it sent. A process or site on the split list still leaves direct
        '';
      };

      geosite = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        example = lib.literalExpression "{ geosite-custom = ./my-set.srs; }";
        description = "Local binary rule-sets of domains refused while no profile is up, keyed by tag";
      };
    };

    split = {
      names = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "firefox"
          "steam"
        ];
        description = ''
          Process names whose traffic leaves around the tunnel — split tunnelling in the
          bypass sense; everything unlisted still goes through the proxy. The name is the
          executable's, as sing-box reads it off the connection's process; `*` and `?`
          are wildcards (`chrom*`), rendered as a regex on the executable's path. Their
          DNS goes to the bootstrap resolver too, except on hosts where
          `systemd-resolved`'s stub owns the query: there the resolver is the process the
          DNS rule sees, while the connection itself still matches and goes direct.
          `skvpn split add` keeps an imperative list beside this one, in
          `base.d/70-split.json`
        '';
      };

      paths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/run/current-system/sw/bin/qbittorrent" ];
        description = ''
          Absolute executable paths routed around the tunnel, same as `names` but whole.
          sing-box cannot match a PID, so this is the knob for a binary whose process
          name is shared or generic. Wildcards: `*` one path segment, `**` any run, `?`
          one character — `/opt/*/bin/tor`
        '';
      };

      ips = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "10.0.0.0/8" ];
        description = "Destination addresses or CIDRs routed around the tunnel; no DNS side";
      };
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        experimental.cache_file.enabled = true;
      };
      description = ''
        Written as a second file in `base.d`, merged by sing-box's own rules: objects merge
        recursively, arrays are appended, and a scalar keeps the value of the first file
        that sets it. The base comes first, so this option adds — a key the base lacks, a
        rule after the base's — and cannot change a scalar the base already sets, such as
        `log.level` (PITFALLS.md)
      '';
    };

    restore.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Bring the last active profile back up on boot. Off, boot starts nothing and
        `skvpn up` is a manual step after every reboot; the remembered choice keeps being
        written either way
      '';
    };

    sync.interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd OnCalendar for refreshing profiles from the stored subscription";
    };

    measure = {
      enable = lib.mkEnableOption "" // {
        description = ''
          Measure every profile on a timer, as `skvpn measure` does: latency, time to the
          first byte and download speed over TCP, round trip and loss over UDP. Each run
          downloads a bounded file through every exit, one exit at a time, so it costs that
          traffic on every run
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = ''
          How long after one measurement ends the next one starts, as a systemd time span.
          Counted from the end, so a slow run never overlaps the next
        '';
      };

      textfile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/var/lib/prometheus-node-exporter-text-files/skvpn.prom";
        description = ''
          A file for node_exporter's textfile collector, replaced whole on every run. The
          directory must exist and the collector must read it. Null prints the table to the
          journal instead
        '';
      };
    };

    monitor = {
      enable = lib.mkEnableOption "" // {
        description = ''
          Open sing-box's Clash API on loopback, which `skvpn top` reads for the live speed
          through the tunnel. The API needs the secret it is opened with: without one, any
          local user could delete connections and so reset the network. The secret is made
          once, kept in a file only root reads, and written into `base.d` for sing-box. Turning
          this on or off restarts the running tunnel once, as any change to the base does
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9097;
        description = "Loopback port of the Clash API";
      };
    };

    tor = {
      enable = lib.mkEnableOption "" // {
        description = ''
          Run a Tor of skvpn's own, apart from the tunnel, so a profile switch never makes
          it bootstrap again. `.onion` names reach it from any program through the TUN, its
          SOCKS port serves programs set up for one, and `skvpn up tor` sends all traffic
          that would go to a node through it. It reaches the network through bridges only,
          and starts once `skvpn tor bridges update` has fetched them
        '';
      };

      socksPort = lib.mkOption {
        type = lib.types.port;
        default = tor.socksPort;
        description = "Loopback port of the SOCKS proxy Tor offers programs set up for one";
      };

      package = lib.mkPackageOption pkgs "tor" { };

      transportPackage = lib.mkPackageOption pkgs "obfs4" { } // {
        description = "The package whose `lyrebird` runs the obfs4, webtunnel and snowflake transports";
      };
    };

    trustedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Users who run `skvpn` without typing sudo: a NOPASSWD sudo rule for exactly this
        command, plus a system-wide `skvpn = "sudo skvpn"` alias so the word itself is all
        they type. polkit alone cannot do this — the tool also writes `/etc/sing-box`. The
        rule names `/run/current-system/sw/bin/skvpn`: sudoers matches the literal path and
        follows no symlinks, and the store path changes on every rebuild
      '';
    };

    fixDiscordVoice = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set the firewall's reverse-path filter to `loose` (as a default, so an explicit
        host value wins). Replies to tunnelled UDP arrive on the TUN interface while the
        route to the peer points at the LAN, and a strict filter drops them — Discord voice
        is the symptom this was found by, but it covers all UDP through the tunnel
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = splitCatchesSingBox == [ ];
        message = ''
          services.skvpn.split: ${lib.concatStringsSep ", " splitCatchesSingBox} would
          match sing-box itself — its traffic never enters the tunnel, and a pattern that
          wide catches everything
        '';
      }
      {
        assertion = cfg.tor.enable -> tun4 != null;
        message = "services.skvpn.tor needs an IPv4 tun.address: Tor's resolver is the TUN's";
      }
      {
        # IPv4 or IPv6, nothing a resolver would have to look up first
        assertion = cfg.tor.enable -> builtins.match "[0-9.]+|[0-9a-fA-F:]+" cfg.dns.remoteServer != null;
        message = "services.skvpn.tor needs dns.remoteServer as an address: Tor falls back to it plainly";
      }
    ];

    environment.systemPackages = [
      cfg.singBoxPackage
      cfg.package
    ];

    environment.etc = {
      "sing-box/base.d/00-base.json".text = builtins.toJSON baseConfig;
    }
    // lib.optionalAttrs (cfg.extraSettings != { }) {
      "sing-box/base.d/50-extra.json".text = builtins.toJSON cfg.extraSettings;
    }
    # Outside base.d, which every profile reads; its presence is how the CLI knows to
    # start the guard on `down`
    // lib.optionalAttrs guardEnabled {
      "sing-box/guard.json".text = builtins.toJSON guardConfig;
    }
    # Outside base.d too; tor.json's presence is how the CLI knows there is a Tor
    // lib.optionalAttrs cfg.tor.enable {
      "sing-box/tor.json".text = builtins.toJSON torProfile;
      "sing-box/torrc".text = torrc;
      "sing-box/tor-resolv.conf".text = torResolv;
      "sing-box/tor-nsswitch.conf".text = torNsswitch;
    };

    # Written by root, contents read by the service user; the directory itself lists for
    # everyone, so shell completion can offer profile names without root
    systemd.tmpfiles.rules = [ "d /etc/sing-box/profiles 2755 root sing-box -" ];

    systemd.services."sing-box@" = lib.recursiveUpdate singBoxService {
      description = "sing-box, profile %i";

      # A rebuild that changes the base config has to restart the active instance, or the
      # policy on the wire silently stays the old one
      restartTriggers = [
        (builtins.toJSON baseConfig)
        (builtins.toJSON cfg.extraSettings)
      ];

      serviceConfig = {
        StateDirectory = "sing-box-%i";
        ExecStart = "${lib.getExe cfg.singBoxPackage} -D /var/lib/sing-box-%i -C /etc/sing-box/base.d -c /etc/sing-box/profiles/%i.json run";
      };
    };

    # Started by `skvpn down` and by boot restore when there is no profile to bring back;
    # wanted by boot itself only when restore is off, since restore would race it
    systemd.services.skvpn-guard = lib.mkIf guardEnabled (
      lib.recursiveUpdate singBoxService {
        description = "sing-box guard: no profile up, listed sites refused";
        wantedBy = lib.optional (!cfg.restore.enable) "multi-user.target";

        # A profile and the guard create the same TUN, so its presence means something is
        # already up — a rebuild starting this beside a running profile skips it
        unitConfig.ConditionPathExists = "!/sys/class/net/${cfg.tun.interfaceName}";

        restartTriggers = [
          (builtins.toJSON baseConfig)
          (builtins.toJSON cfg.extraSettings)
          (builtins.toJSON guardConfig)
        ];

        serviceConfig = {
          StateDirectory = "skvpn-guard";
          ExecStart = "${lib.getExe cfg.singBoxPackage} -D /var/lib/skvpn-guard -C /etc/sing-box/base.d -c /etc/sing-box/guard.json run";
        };
      }
    );

    # Tor under a user of its own, which is what the `tor` profile tells its traffic apart
    # by. Without a bridge it does not start; `skvpn tor bridges update` or `bridges add`
    # writes one and starts it, and a later change reloads it
    systemd.services.skvpn-tor = lib.mkIf cfg.tor.enable {
      description = "Tor for skvpn: .onion names and `skvpn up tor`";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Tor refuses UseBridges with no bridge, so an empty directory keeps it down
      unitConfig.ConditionDirectoryNotEmpty = torBridges;
      restartTriggers = [
        torrc
        torResolv
        torNsswitch
      ];

      serviceConfig = {
        User = tor.user;
        Group = tor.user;
        ExecStart = "${lib.getExe cfg.tor.package} -f /etc/sing-box/torrc";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        # The transports resolve their brokers straight into the TUN, as Tor's user
        BindReadOnlyPaths = [
          "/etc/sing-box/tor-resolv.conf:/etc/resolv.conf"
          "/etc/sing-box/tor-nsswitch.conf:/etc/nsswitch.conf"
        ];
        InaccessiblePaths = [ "-/run/nscd" ];
        # Tor refuses a DataDirectory anyone but its user can read
        StateDirectory = "skvpn-tor";
        StateDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = "10s";
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    # The CLI's way to the hold: skvpn-nft@hold before a switch, skvpn-nft@release for off.
    # A unit because the flags are the policy, and the policy lives here
    systemd.services."skvpn-nft@" = {
      description = "skvpn: nft-bypass %i";
      path = [ pkgs.nftables ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = bypass "%i";
      };
    };

    # /etc/systemd/system is a store symlink on NixOS, so `systemctl enable
    # sing-box@<name>` cannot persist a choice — the last one goes to /var/lib/skvpn/active
    # and comes back through this
    systemd.services.skvpn-restore = lib.mkIf cfg.restore.enable {
      description = "Bring the last active sing-box profile back up";

      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe cfg.package} restore";
      };
    };

    # Also runs on every `skvpn up`, so a rotated node is picked up without being asked for
    systemd.services.skvpn-sync = {
      description = "Refresh sing-box profiles from the stored subscription";

      # The Persistent timer fires this right at boot after a missed window, and a fetch
      # before the network is up would sit red until the next day's trigger
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} sub sync --if-stale";
      };
    };

    systemd.timers.skvpn-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.sync.interval;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    # Root, because the profiles carry the nodes' credentials. A oneshot counted from its
    # own end, so one slow run cannot overlap the next; the limits keep the probe sing-box
    # and a stuck download from outliving a sane measurement
    systemd.services.skvpn-measure = lib.mkIf cfg.measure.enable {
      description = "Measure speed and UDP loss through every sing-box profile";

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      path = [ pkgs.curl ];
      environment.SKVPN_SING_BOX = lib.getExe cfg.singBoxPackage;

      serviceConfig = {
        Type = "oneshot";
        ExecStart =
          "${lib.getExe cfg.package} measure"
          + lib.optionalString (
            cfg.measure.textfile != null
          ) " --textfile ${lib.escapeShellArg cfg.measure.textfile}";
        MemoryMax = "256M";
        TimeoutStartSec = "15min";
        Nice = 10;
        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.skvpn-measure = lib.mkIf cfg.measure.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitInactiveSec = cfg.measure.interval;
      };
    };

    security.sudo.extraRules = lib.mkIf (cfg.trustedUsers != [ ]) [
      {
        users = cfg.trustedUsers;
        commands = [
          {
            command = "/run/current-system/sw/bin/skvpn";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # The alias reaches every user; for one outside trustedUsers it just asks the password
    # sudo would have asked anyway
    environment.shellAliases = lib.mkIf (cfg.trustedUsers != [ ]) {
      skvpn = "sudo skvpn";
    };

    users.users.sing-box = {
      isSystemUser = true;
      group = "sing-box";
      home = "/var/lib/sing-box";
    };
    users.groups.sing-box = { };

    users.users.${tor.user} = lib.mkIf cfg.tor.enable {
      isSystemUser = true;
      group = tor.user;
    };
    users.groups.${tor.user} = lib.mkIf cfg.tor.enable { };

    # TUN replies arrive on the TUN interface but route via the LAN link, so a strict
    # rpfilter drops every UDP answer
    networking.firewall.checkReversePath = lib.mkIf cfg.fixDiscordVoice (lib.mkDefault "loose");
  };
}
