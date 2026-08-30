# Evaluates the module inside a real nixpkgs module set, not against stubs. The stub test
# in module-test.nix answers "does the option reach the config"; this one answers "would
# nixpkgs accept the config at all" — a stub takes anything, while the real module set has
# types and assertions, and a module that writes to the wrong option there fails a whole
# system with an error that never names this module.
#
# What gets forced is config.assertions and a handful of values, not system.build.toplevel:
# a check is realised rather than merely evaluated, so making the toplevel the check would
# build a whole system closure
{
  lib,
  nixpkgs,
  system,
  module,
}:

let
  # The smallest config nixpkgs will call a system: without a root filesystem and a
  # bootloader decision, evaluation stops before it reaches anything of ours
  base = {
    nixpkgs.hostPlatform = system;
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/sda1";
      fsType = "ext4";
    };
    system.stateVersion = "25.11";
  };

  evalWith =
    user:
    (nixpkgs.lib.nixosSystem {
      modules = [
        module
        base
        user
      ];
    }).config;

  broken = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  geositeStub = builtins.toFile "geosite-stub.srs" "geosite";

  enabled = evalWith {
    services.skvpn = {
      enable = true;
      tailscale.enable = true;
      direct = {
        zones = [ ".ru" ];
        geosite.geosite-test = geositeStub;
      };
      extraSettings.log.level = "debug";
      trustedUsers = [ "alice" ];
    };
  };

  # docker.enable defaults to following the host's own docker switch, the way
  # tailscale.enable follows services.tailscale — nothing under services.skvpn set here
  dockerFollow = evalWith {
    virtualisation.docker.enable = true;
    services.skvpn.enable = true;
  };

  # The host's own explicit value has to win over the module's default-priority "loose"
  hostStrict = evalWith {
    networking.firewall.checkReversePath = true;
    services.skvpn.enable = true;
  };

  restoreOff = evalWith {
    services.skvpn = {
      enable = true;
      restore.enable = false;
    };
  };

  off = evalWith { };
in
{
  enabledBroken = broken enabled;
  enabledBase = enabled.environment.etc."sing-box/base.d/00-base.json".text;
  enabledExtra = enabled.environment.etc."sing-box/base.d/50-extra.json".text;
  enabledTmpfiles = lib.filter (lib.hasInfix "sing-box") enabled.systemd.tmpfiles.rules;
  enabledTimer = enabled.systemd.timers.skvpn-sync.timerConfig.OnCalendar;
  enabledFirewall = enabled.networking.firewall.checkReversePath;
  enabledRestore = enabled.systemd.services ? skvpn-restore;
  singBoxUserGroup = enabled.users.users.sing-box.group;

  # Other modules add their own extraRules, so ours is fished out by its command
  enabledSudo = lib.filter (
    rule: lib.any (c: c.command or "" == "/run/current-system/sw/bin/skvpn") (rule.commands or [ ])
  ) enabled.security.sudo.extraRules;
  enabledAlias = enabled.environment.shellAliases.skvpn or null;

  dockerFollowBase = dockerFollow.environment.etc."sing-box/base.d/00-base.json".text;

  hostStrictBroken = broken hostStrict;
  hostStrictFirewall = hostStrict.networking.firewall.checkReversePath;

  restoreOffPresent = restoreOff.systemd.services ? skvpn-restore;
  restoreOffTemplate = restoreOff.systemd.services ? "sing-box@";

  offBroken = broken off;
  offEtc = off.environment.etc ? "sing-box/base.d/00-base.json";
  offUser = off.users.users ? sing-box;
  offRestore = off.systemd.services ? skvpn-restore;
  offAlias = off.environment.shellAliases.skvpn or null;
}
