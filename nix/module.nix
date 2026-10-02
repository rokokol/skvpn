# NixOS module: the whole client except the policy. It owns the CLI, the sing-box@<profile>
# template unit, the boot restore and subscription sync units, the sing-box user and the
# profiles directory, plus a generic base config — TUN, DNS, routing skeleton. What it ships
# none of is the routing policy: direct zones and rule-sets come from the consumer's options
{ self, ruleSetFiles }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.skvpn;

  # Countries whose domestic destinations commonly have to leave around the tunnel; the
  # rule-set data behind the tags is pinned in this flake's own lock. The punycode zones
  # are the countries' IDN ccTLDs: .рф, .中国, .中國, .ایران
  presets = {
    russia = {
      label = "Russian";
      zones = [
        ".ru"
        ".su"
        ".xn--p1ai"
      ];
      geosite = "geosite-ru";
      geoip = "geoip-ru";
    };
    china = {
      label = "Chinese";
      zones = [
        ".cn"
        ".xn--fiqs8s"
        ".xn--fiqz9s"
      ];
      geosite = "geosite-cn";
      geoip = "geoip-cn";
    };
    iran = {
      label = "Iranian";
      zones = [
        ".ir"
        ".xn--mgba3a4f16a"
      ];
      geosite = "geosite-ir";
      geoip = "geoip-ir";
    };
  };

  # A fixed order, so two enabled presets render the same base on every eval
  enabledPresets = lib.filter (name: cfg.direct.${name}.enable) [
    "russia"
    "china"
    "iran"
  ];

  # The consumer's knobs plus whatever presets are on
  directZones = lib.unique (
    cfg.direct.zones ++ lib.concatMap (name: presets.${name}.zones) enabledPresets
  );
  presetFiles =
    key:
    lib.listToAttrs (
      map (
        name: lib.nameValuePair presets.${name}.${key} ruleSetFiles.${presets.${name}.${key}}
      ) enabledPresets
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
  routeExcludeAddress =
    lib.optionals cfg.tailscale.enable [
      "100.64.0.0/10"
      "fd7a:115c:a1e0::/48"
    ]
    ++ dockerAddressPools;

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
  splitNames = lib.filter (p: !isGlob p) cfg.split.names;
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
  # flags are the policy, the rules live in the script the installer runs too
  bypassCommand = lib.concatStringsSep " " (
    [ "${cfg.package}/libexec/skvpn/nft-bypass apply" ]
    ++ lib.optional cfg.tailscale.enable "--tailscale"
    ++ lib.optional cfg.docker.enable "--docker"
    ++ lib.optional cfg.syncthing.enable "--syncthing"
  );

  # The guard is what runs while no profile is up, and exists only with something to refuse
  guardGeosite =
    lib.optionalAttrs cfg.guard.ai.enable { inherit (ruleSetFiles) geosite-ai; } // cfg.guard.geosite;
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

  # What a profile instance and the guard share; only the config and state paths differ
  singBoxService = {
    after = [
      "network-online.target"
      "nss-lookup.target"
    ];
    wants = [ "network-online.target" ];

    path = [ pkgs.nftables ];
    postStart = bypassCommand;

    serviceConfig = {
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
      ];
      # Direct names resolve outside the tunnel too, or the answer is geo-wrong and the
      # query travels to a node that may refuse to carry it
      rules =
        lib.optional (directZones != [ ]) {
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
    ];

    route = {
      auto_detect_interface = true;
      default_domain_resolver = "bootstrap";

      # hijack-dns before ip_is_private: the TUN's own DNS address is private and would be
      # lost
      rules = [
        { action = "sniff"; }
        {
          protocol = "dns";
          action = "hijack-dns";
        }
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
      default = "8.8.8.8";
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
      lib.mapAttrs (_: preset: {
        enable = lib.mkEnableOption "" // {
          description = ''
            Route ${preset.label} destinations around the tunnel: the
            ${lib.concatStringsSep ", " (map (z: "`${z}`") preset.zones)} zone suffixes plus
            the `${preset.geosite}` and `${preset.geoip}` rule-sets pinned in this flake's
            own lock — for exits that refuse or geo-mangle that traffic. The suffixes carry
            most of it: a geosite set always misses plenty
          '';
        };
      }) presets
      // {
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
          Refuse AI services while no profile is up: the `geosite-category-ai-!cn` rule-set
          pinned in this flake's own lock — the services outside China, which are the ones
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

    # TUN replies arrive on the TUN interface but route via the LAN link, so a strict
    # rpfilter drops every UDP answer
    networking.firewall.checkReversePath = lib.mkIf cfg.fixDiscordVoice (lib.mkDefault "loose");
  };
}
