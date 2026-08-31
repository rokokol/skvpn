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
      tailscale.enable = true;
      docker.enable = true;
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

  off = eval { };
in
{
  base = tuned.environment.etc."sing-box/base.d/00-base.json".text;
  extra = tuned.environment.etc."sing-box/base.d/50-extra.json".text;
  packages = names tuned.environment.systemPackages;
  tmpfiles = tuned.systemd.tmpfiles.rules;
  services = lib.attrNames tuned.systemd.services;
  timerInterval = tuned.systemd.timers.skvpn-sync.timerConfig.OnCalendar;
  firewall = tuned.networking.firewall.checkReversePath;
  users = lib.attrNames tuned.users.users;
  sudoRules = tuned.security.sudo.extraRules;
  aliases = tuned.environment.shellAliases;

  bareBase = bare.environment.etc."sing-box/base.d/00-base.json".text;
  bareEtc = lib.attrNames bare.environment.etc;
  bareAliases = bare.environment.shellAliases;

  presetsBase = presetsOn.environment.etc."sing-box/base.d/00-base.json".text;

  restoreOffServices = lib.attrNames restoreOff.systemd.services;

  offEtc = lib.attrNames off.environment.etc;
  offPackages = off.environment.systemPackages;
  offTmpfiles = off.systemd.tmpfiles.rules;
  offServices = lib.attrNames off.systemd.services;
  offUsers = lib.attrNames off.users.users;
  offFirewall = off.networking.firewall.checkReversePath;
  offSudoRules = off.security.sudo.extraRules;
  offAliases = off.environment.shellAliases;
}
