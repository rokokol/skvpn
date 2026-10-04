# Evaluates the module against stubs for the option paths it writes to, so the wiring is
# checked without pulling nixpkgs' module set in. Produces the values it would emit;
# flake.nix turns them into assertions
{
  lib,
  pkgs,
  nixosModule,
}:

let
  stubs =
    { lib, ... }:
    {
      options = {
        assertions = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [ ];
        };
        environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
        };
        environment.etc = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        systemd.tmpfiles.rules = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        systemd.timers = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        users.users = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        users.groups = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        networking.firewall.checkReversePath = lib.mkOption {
          type = lib.types.anything;
          default = null;
        };
        security.sudo.extraRules = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        environment.shellAliases = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
        };
      };
    };

  eval =
    user:
    (lib.evalModules {
      modules = [
        stubs
        nixosModule
        user
      ];
      specialArgs = { inherit pkgs lib; };
    }).config;

  # Joined rather than indexed, so "installed nothing" fails the assertion instead of
  # blowing up during evaluation with an unhelpful list error
  names = packages: lib.concatMapStringsSep " " toString packages;

  geositeStub = builtins.toFile "geosite-stub.srs" "geosite";
  geoipStub = builtins.toFile "geoip-stub.srs" "geoip";

  # The full policy a consumer would write, every knob turned away from its default
  tuned = eval {
    services.skvpn = {
      enable = true;
      tailscale = {
        enable = true;
        viaTunnel = [
          "192.0.2.10"
          "2001:db8::10"
        ];
      };
      docker.enable = true;
      syncthing.enable = true;
      tun = {
        ipv6 = false;
        stack = "gvisor";
      };
      direct = {
        zones = [
          ".ru"
          ".su"
        ];
        geosite.geosite-test = geositeStub;
        geoip.geoip-test = geoipStub;
      };
      extraSettings.log.level = "debug";
      sync.interval = "weekly";
      trustedUsers = [ "alice" ];
    };
  };

  # Nothing but enable: the base must carry no rules invented out of thin air
  bare = eval { services.skvpn.enable = true; };

  # The presets alone: zones and rule-sets appear without the consumer naming a file
  presetsOn = eval {
    services.skvpn = {
      enable = true;
      direct = {
        russia.enable = true;
        china.enable = true;
        iran.enable = true;
      };
    };
  };

  restoreOff = eval {
    services.skvpn = {
      enable = true;
      restore.enable = false;
    };
  };

  # Split tunnelling on its own, so the tuned base keeps its last rules where the
  # assertions index them
  splitOn = eval {
    services.skvpn = {
      enable = true;
      split = {
        names = [
          "firefox"
          "chrom*"
        ];
        paths = [
          "/usr/bin/steam"
          "/opt/*/bin/tor"
        ];
        ips = [ "10.0.0.0/8" ];
      };
    };
  };

  # BitTorrent beside a split name of the consumer's own, which the client list joins
  bittorrentOn = eval {
    services.skvpn = {
      enable = true;
      direct.bittorrent.enable = true;
      split.names = [ "firefox" ];
    };
  };

  # The guard with every source of sites on, under a TUN name moved away from the default
  guardOn = eval {
    services.skvpn = {
      enable = true;
      tun.interfaceName = "test-tun";
      guard = {
        ai.enable = true;
        zones = [ ".example.com" ];
        geosite.geosite-test = geositeStub;
      };
    };
  };

  # Without restore nothing would start the guard at boot, so boot itself wants it
  guardRestoreOff = eval {
    services.skvpn = {
      enable = true;
      restore.enable = false;
      guard.zones = [ ".example.com" ];
    };
  };

  # An entry that would catch sing-box itself has to be refused at eval time
  splitSingBox = eval {
    services.skvpn = {
      enable = true;
      split.names = [ "sing*" ];
    };
  };

  viaTunnelAlone = eval {
    services.skvpn = {
      enable = true;
      tailscale = {
        enable = false;
        viaTunnel = [ "192.0.2.10" ];
      };
    };
  };

  off = eval { };

  broken = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
in
{
  base = tuned.environment.etc."sing-box/base.d/00-base.json".text;
  extra = tuned.environment.etc."sing-box/base.d/50-extra.json".text;
  packages = names tuned.environment.systemPackages;
  tmpfiles = tuned.systemd.tmpfiles.rules;
  services = lib.attrNames tuned.systemd.services;
  postStart = tuned.systemd.services."sing-box@".postStart;
  unitPath = names tuned.systemd.services."sing-box@".path;
  capabilities = tuned.systemd.services."sing-box@".serviceConfig.AmbientCapabilities;
  timerInterval = tuned.systemd.timers.skvpn-sync.timerConfig.OnCalendar;
  firewall = tuned.networking.firewall.checkReversePath;
  users = lib.attrNames tuned.users.users;
  sudoRules = tuned.security.sudo.extraRules;
  aliases = tuned.environment.shellAliases;

  bareBase = bare.environment.etc."sing-box/base.d/00-base.json".text;
  bareEtc = lib.attrNames bare.environment.etc;
  bareAliases = bare.environment.shellAliases;
  barePostStart = bare.systemd.services."sing-box@".postStart;
  bareServices = lib.attrNames bare.systemd.services;

  guard = guardOn.environment.etc."sing-box/guard.json".text;
  guardBase = guardOn.environment.etc."sing-box/base.d/00-base.json".text;
  guardUnit = {
    inherit (guardOn.systemd.services.skvpn-guard) wantedBy postStart serviceConfig;
    # A missing condition has to reach its own assertion, not stop the evaluation
    unitConfig = guardOn.systemd.services.skvpn-guard.unitConfig or { };
  };
  guardRestoreOffWantedBy = guardRestoreOff.systemd.services.skvpn-guard.wantedBy;

  presetsBase = presetsOn.environment.etc."sing-box/base.d/00-base.json".text;

  bittorrentBase = bittorrentOn.environment.etc."sing-box/base.d/00-base.json".text;

  restoreOffServices = lib.attrNames restoreOff.systemd.services;

  splitBase = splitOn.environment.etc."sing-box/base.d/00-base.json".text;
  splitBroken = broken splitOn;
  splitSingBoxBroken = broken splitSingBox;

  tunedBroken = broken tuned;
  viaTunnelAloneBroken = broken viaTunnelAlone;

  offEtc = lib.attrNames off.environment.etc;
  offPackages = off.environment.systemPackages;
  offTmpfiles = off.systemd.tmpfiles.rules;
  offServices = lib.attrNames off.systemd.services;
  offUsers = lib.attrNames off.users.users;
  offFirewall = off.networking.firewall.checkReversePath;
  offSudoRules = off.security.sudo.extraRules;
  offAliases = off.environment.shellAliases;
}
