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

  ruleSetFile = tag: path: {
    inherit tag;
    type = "local";
    format = "binary";
    path = "${path}";
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
          server = "bootstrap";
        }
        ++ lib.optional (directGeosite != { }) {
          rule_set = lib.attrNames directGeosite;
          server = "bootstrap";
        };
      final = "remote";
      strategy = "ipv4_only";
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

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        log.level = "debug";
      };
      description = ''
        Written as a second file in `base.d`, merged by sing-box's own `-C` semantics:
        objects merge recursively, arrays are appended, scalars are replaced by the later
        file. Appending is the reach of this option — a scalar inside an existing array
        element (say, the TUN inbound) cannot be changed from here
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
    environment.systemPackages = [
      cfg.singBoxPackage
      cfg.package
    ];

    environment.etc = {
      "sing-box/base.d/00-base.json".text = builtins.toJSON baseConfig;
    }
    // lib.optionalAttrs (cfg.extraSettings != { }) {
      "sing-box/base.d/50-extra.json".text = builtins.toJSON cfg.extraSettings;
    };

    # Written by root, contents read by the service user; the directory itself lists for
    # everyone, so shell completion can offer profile names without root
    systemd.tmpfiles.rules = [ "d /etc/sing-box/profiles 2755 root sing-box -" ];

    systemd.services."sing-box@" = {
      description = "sing-box, profile %i";

      after = [
        "network-online.target"
        "nss-lookup.target"
      ];
      wants = [ "network-online.target" ];

      # A rebuild that changes the base config has to restart the active instance, or the
      # policy on the wire silently stays the old one
      restartTriggers = [
        (builtins.toJSON baseConfig)
        (builtins.toJSON cfg.extraSettings)
      ];

      # sing-box only accepts exact names in exclude_interface. Docker names user-defined
      # bridges br-<network-id>, so insert nftables wildcard returns after sing-box creates
      # its table; these also match bridges created later without restarting the VPN
      postStart = lib.optionalString cfg.docker.enable ''
        for _ in {1..50}; do
          ${pkgs.nftables}/bin/nft list chain inet sing-box prerouting >/dev/null 2>&1 && break
          sleep 0.1
        done
        ${pkgs.nftables}/bin/nft -f - <<'EOF'
        insert rule inet sing-box prerouting iifname "br-*" return comment "skvpn: bypass Docker bridges"
        insert rule inet sing-box prerouting_udp_icmp iifname "br-*" return comment "skvpn: bypass Docker bridges"
        EOF
      '';

      serviceConfig = {
        User = "sing-box";
        StateDirectory = "sing-box-%i";
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
          "CAP_NET_BIND_SERVICE"
        ];
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
          "CAP_NET_BIND_SERVICE"
        ];
        ExecStart = "${lib.getExe cfg.singBoxPackage} -D /var/lib/sing-box-%i -C /etc/sing-box/base.d -c /etc/sing-box/profiles/%i.json run";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = "10s";
        LimitNOFILE = "infinity";
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
