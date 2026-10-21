{
  description = "Manage sing-box VPN profiles as systemd template instances";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Data for the country presets. Both rule-set branches are rebuilt upstream every few
    # days and carry no tags, so the pin belongs in the lock file rather than in a hash
    # beside the URL — the weekly lock bump is what keeps the presets fresh
    sing-geoip = {
      url = "github:SagerNet/sing-geoip/rule-set";
      flake = false;
    };

    sing-geosite = {
      url = "github:SagerNet/sing-geosite/rule-set";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sing-geoip,
      sing-geosite,
    }:
    let
      inherit (nixpkgs) lib;
      # systemd units and a TUN device — there is nothing here that could work elsewhere
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Each piece isolated, so a README edit doesn't rebuild anything
      script = builtins.path {
        name = "skvpn.py";
        path = ./skvpn.py;
      };
      versionFile = builtins.path {
        name = "skvpn-VERSION";
        path = ./VERSION;
      };
      installer = builtins.path {
        name = "install.sh";
        path = ./install.sh;
      };
      nonNixDir = builtins.path {
        name = "skvpn-non-nix";
        path = ./non-nix;
      };
      completionsDir = builtins.path {
        name = "skvpn-completions";
        path = ./completions;
      };
      testsDir = builtins.path {
        name = "skvpn-tests";
        path = ./tests;
      };
      bypassScript = builtins.path {
        name = "nft-bypass.sh";
        path = ./nft-bypass.sh;
      };
      # Presets, the tailnet and where the rule-sets come from: the one place the module,
      # the installer's renderer and the CLI all read
      policy = lib.importJSON ./policy.json;
      policyFile = builtins.path {
        name = "skvpn-policy.json";
        path = ./policy.json;
      };
      checkSh = builtins.path {
        name = "check-sh.sh";
        path = ./check-sh.sh;
      };
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
      });

      # builtins.path keeps single files out of the input trees, so the module's closure
      # carries the enabled presets' rule-set files rather than both branches
      nixosModules.default = import ./nix/module.nix {
        inherit self policy;
        # Every file the presets and the guard name in policy.json, under the tags the
        # module refers to them by
        ruleSetFiles =
          let
            one =
              input: file:
              builtins.path {
                # A store path name takes no `!`, which upstream spells "not" in its file names
                name = builtins.replaceStrings [ "!" ] [ "not-" ] file;
                path = "${input}/${file}";
              };
          in
          lib.listToAttrs (
            lib.concatMap (preset: [
              (lib.nameValuePair "geosite-${preset.tag}" (one sing-geosite preset.geosite))
              (lib.nameValuePair "geoip-${preset.tag}" (one sing-geoip preset.geoip))
            ]) policy.presets
          )
          // {
            "geosite-${policy.guard.tag}" = one sing-geosite policy.guard.geosite;
          };
      };

      # For a consumer who reaches for pkgs rather than this flake's packages directly
      overlays.default = final: _prev: {
        skvpn = self.packages.${final.stdenv.hostPlatform.system}.default;
      };

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          # The behaviour suite: a scratch SKVPN_ROOT in, profiles and unit calls out
          tests =
            pkgs.runCommand "tests"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  coreutils
                  diffutils
                  # find and pgrep: the ping cases look for what the probe left behind
                  findutils
                  gnugrep
                  jq
                  procps
                  python3
                  # The real one, behind the stub on PATH: the phone config has to pass
                  # its check
                  sing-box
                  systemd
                ];
              }
              ''
                mkdir -p repo
                cp ${script} repo/skvpn.py
                cp ${versionFile} repo/VERSION
                cp ${installer} repo/install.sh
                cp ${bypassScript} repo/nft-bypass.sh
                cp ${policyFile} repo/policy.json
                cp -r ${nonNixDir} repo/non-nix
                cp -r ${completionsDir} repo/completions
                cp -r ${testsDir} repo/tests
                chmod -R +w repo
                patchShebangs repo
                bash repo/tests/run.sh
                touch $out
              '';

          # The wrapper is what puts the command and both completions on a system
          package-smoke =
            let
              skvpn = self.packages.${system}.default;
            in
            pkgs.runCommand "package-smoke" { nativeBuildInputs = with pkgs; [ gnugrep ]; } ''
              test -x ${skvpn}/bin/skvpn
              # No systemctl in the sandbox, so the usage line is how far a run can get
              (${skvpn}/bin/skvpn 2>&1 || true) | grep -F 'usage: skvpn' >/dev/null
              test -f ${skvpn}/share/bash-completion/completions/skvpn
              test -f ${skvpn}/share/zsh/site-functions/_skvpn
              # The units run it, so it must be there and runnable from its own shebang
              ${skvpn}/libexec/skvpn/nft-bypass --help | grep -F 'nft-bypass.sh apply' >/dev/null
              touch $out
            '';

          # An input's URL has to be a literal, so it cannot read policy.json; this holds the
          # two spellings of each rule-set source to each other, through the lock
          policy-sources =
            let
              locked = (lib.importJSON ./flake.lock).nodes;
              source = input: "${locked.${input}.original.owner}/${locked.${input}.original.repo}";
              agree =
                input: key:
                lib.assertMsg (
                  source input == policy.ruleSets.${key} && locked.${input}.original.ref == policy.ruleSets.branch
                ) "flake input ${input} and policy.json ruleSets.${key} name different sources";
            in
            assert agree "sing-geosite" "geosite";
            assert agree "sing-geoip" "geoip";
            pkgs.runCommand "policy-sources" { } "touch $out";

          module-wiring =
            let
              wiring = import ./nix/module-test.nix {
                inherit lib pkgs;
                nixosModule = self.nixosModules.default;
              };
            in
            pkgs.runCommand "module-wiring"
              {
                nativeBuildInputs = with pkgs; [ jq ];
                dump = builtins.toJSON wiring;
                passAsFile = [ "dump" ];
              }
              ''
                want() { jq -e "$1" "$dumpPath" >/dev/null || { echo "module wiring: $2"; exit 1; }; }

                # The field names below are written a second time here, so a rename in
                # module-test.nix would otherwise surface as a stray failure in whichever
                # check read the key first — and jq answers 0 for the length of a missing one
                want 'keys == [
                  "aliases", "bareAliases", "bareBase", "bareEtc", "barePostStart", "bareServices",
                  "bareTimers", "base", "bittorrentBase", "capabilities", "extra", "firewall", "guard",
                  "guardBase", "guardRestoreOffWantedBy", "guardUnit", "holdExec", "measureNoFileExec",
                  "measureServices", "measureTimer", "measureUnit", "monitorEtc",
                  "monitorGuardScript", "monitorOffScript", "monitorScript", "offAliases", "offEtc",
                  "offFirewall", "offPackages", "offServices", "offSudoRules", "offTmpfiles", "offUsers",
                  "packages", "postStart", "presetsBase", "restoreOffServices", "services",
                  "splitBase", "splitBroken", "splitSingBoxBroken", "stopPost", "sudoRules", "timerInterval",
                  "tmpfiles", "torBase", "torLyrebird", "torProfile", "torResolv", "torUnit", "torUsers", "torrc",
                  "unitPath", "users"
                ]' "the dump no longer has the keys these checks read"

                # Tor: .onion names get a fake address and go to Tor ahead of every direct
                # rule; the `tor` profile keeps Tor's own traffic and names out of itself
                want '.torBase | fromjson | .dns.rules[0] == {"domain_suffix": ["${policy.tor.onion}"], "action": "route", "server": "onion"}' ".onion names are not answered from the fake range first"
                want '.torBase | fromjson | .dns.servers | any(. == {"tag": "onion", "type": "fakeip", "inet4_range": "${policy.tor.fakeip}"})' "there is no fake range for .onion names"
                want '.torBase | fromjson | .outbounds | any(. == {"type": "socks", "tag": "tor", "server": "127.0.0.1", "server_port": ${toString policy.tor.routePort}})' "the base has no way to Tor's isolating port"
                want '.torBase | fromjson | .route.rules | (map(.outbound == "tor" and .domain_suffix == ["${policy.tor.onion}"]) | index(true)) < (map(.ip_is_private == true) | index(true))' ".onion is not routed to Tor ahead of the direct rules"
                want '.bareBase | fromjson | (.outbounds | all(.tag != "tor")) and (.dns.servers | all(.tag != "onion"))' "a base without Tor routes to one"
                want '.torProfile | fromjson | .outbounds == [{"type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": ${toString policy.tor.routePort}}]' "the tor profile does not send everything to Tor's isolating port"
                want '.torProfile | fromjson | .route.rules == [{"user": ["${policy.tor.user}"], "outbound": "direct"}]' "Tor's own traffic would route back into Tor"
                want '.torProfile | fromjson | .dns.rules == [{"user": ["${policy.tor.user}"], "action": "route", "server": "bootstrap"}, {"action": "route", "server": "tor"}]' "names do not go to Tor's DNSPort, or Tor's own would wait on itself"
                want '.torrc | split("\n") | index("SocksPort 127.0.0.1:19050") and index("SocksPort 127.0.0.1:${toString policy.tor.routePort} IsolateDestAddr") and index("DNSPort 127.0.0.1:${toString policy.tor.dnsPort}")' "the torrc lost a port"
                want '.torrc | split("\n") | index("UseBridges 1") and index("%include /var/lib/skvpn/tor-bridges.conf")' "the torrc does not take the bridges the CLI writes"
                want '.torrc | test("ClientTransportPlugin ${lib.concatStringsSep "," policy.tor.transports} exec /nix/store/[^\n ]*/bin/lyrebird\n")' "the torrc does not run lyrebird for every transport Moat is asked for"
                want '.torUnit.serviceConfig.User == "${policy.tor.user}" and .torUnit.serviceConfig.StateDirectoryMode == "0700"' "Tor does not run as the user the profile tells it apart by"
                want '.torUnit.unitConfig.ConditionPathExists == "/var/lib/skvpn/tor-bridges.conf"' "Tor starts before it has any bridge"
                want '.torUnit.wantedBy == ["multi-user.target"]' "Tor does not come up on boot"
                want '.torResolv == "nameserver 172.19.0.2\n" and .torUnit.serviceConfig.BindReadOnlyPaths == ["/etc/sing-box/tor-resolv.conf:/etc/resolv.conf"] and .torUnit.serviceConfig.Environment == ["GODEBUG=netdns=go"]' "Tor's transports resolve through systemd-resolved, which the tor profile cannot tell apart"
                want '.torUsers | index("${policy.tor.user}")' "the Tor user is missing"
                want '(.users | index("${policy.tor.user}") | not) and (.bareEtc | index("sing-box/tor.json") | not) and (.bareServices | index("skvpn-tor") | not)' "Tor is set up while tor.enable is off"

                # A split entry that would catch sing-box itself is refused at eval time
                want '.splitBroken == []' "a plain split list trips an assertion"
                want '.splitSingBoxBroken | length == 1 and (.[0] | test("sing\\* would"))' "a split entry catching sing-box itself was not refused"

                # A process rule matches only if the unit may read other users' /proc entries
                want '.capabilities | index("CAP_SYS_PTRACE") and index("CAP_DAC_READ_SEARCH")' "the unit cannot match a process to a connection"

                # Split tunnelling: one direct rule per field, wildcards as a path regex, DNS
                # steered for the process fields only
                want '.splitBase | fromjson | .route.rules[-4] == {"process_name": ["firefox"], "outbound": "direct"}' "split names never reached routing"
                want '.splitBase | fromjson | .route.rules[-3] == {"process_path": ["/usr/bin/steam"], "outbound": "direct"}' "split paths never reached routing"
                want '.splitBase | fromjson | .route.rules[-2] == {"process_path_regex": ["(^|/)chrom[^/]*$", "^/opt/[^/]*/bin/tor$"], "outbound": "direct"}' "split wildcards were not rendered as a path regex"
                want '.splitBase | fromjson | .route.rules[-1] == {"ip_cidr": ["10.0.0.0/8"], "outbound": "direct"}' "split addresses never reached routing"
                want '.splitBase | fromjson | .dns.rules == [{"process_name": ["firefox"], "action": "route", "server": "bootstrap"}, {"process_path": ["/usr/bin/steam"], "action": "route", "server": "bootstrap"}, {"process_path_regex": ["(^|/)chrom[^/]*$", "^/opt/[^/]*/bin/tor$"], "action": "route", "server": "bootstrap"}]' "split DNS rules drifted"
                # The action form, not the legacy bare `server` sing-box deprecated in 1.11
                want '.base | fromjson | .dns.rules | all(.action == "route")' "a DNS rule is in the legacy form"
                want '.bareBase | fromjson | .route.rules | map(select(has("process_name") or has("process_path") or has("ip_cidr") or .protocol == ["bittorrent"])) == []' "a bare base carries split rules"

                # BitTorrent: the sniffed protocol direct, and every client policy.json names
                # joins the split names under its own name and the name a Nix wrapper runs as
                want '.bittorrentBase | fromjson | .route.rules | map(select(.protocol == ["bittorrent"] and .outbound == "direct")) | length == 1' "sniffed BitTorrent is not routed direct"
                want '.bittorrentBase | fromjson | [.route.rules[], .dns.rules[] | select(has("process_name")) | .process_name] | length == 2 and all(. as $names | ${
                  builtins.toJSON (
                    [ "firefox" ]
                    ++ lib.concatMap (name: [
                      name
                      ".${name}-wrapped"
                    ]) policy.bittorrent.clients
                  )
                } - $names == [])' "a BitTorrent client or a consumer's split name is missing from routing or DNS"

                # Every policy knob has to reach the rendered base, or it is decoration
                want '.base | fromjson | .dns.rules[0].domain_suffix == [".ru", ".su"]' "zones never reached DNS"
                want '.bareBase | fromjson | .dns.reverse_mapping == true' "a nameless connection would miss every domain rule"
                want '.base | fromjson | .dns.rules[1].rule_set == ["geosite-test"]' "geosite never reached DNS"
                want '.base | fromjson | .route.rules[-1].rule_set == ["geosite-test", "geoip-test"]' "rule-sets never reached routing"
                want '.base | fromjson | .route.rules[-2].domain_suffix == [".ru", ".su"]' "zones never reached routing"
                want '.base | fromjson | .route.rule_set | map(.path) | all(test("/nix/store"))' "rule-set files are not store paths"
                want '.base | fromjson | .inbounds[0].route_exclude_address == ${builtins.toJSON policy.tailnet}' "the tailnet is not excluded"
                want '.base | fromjson | .inbounds[0].exclude_interface == ["docker0"]' "the docker bridge is not excluded"
                # The bypass rules live in the packaged script; the module only picks the flags
                want '.postStart | test("/libexec/skvpn/nft-bypass apply( |$)")' "the unit does not run the packaged bypass script"
                want '.postStart | split(" ") | .[2:] | sort == ["--docker", "--syncthing", "--tailscale"]' "a bypass flag never reached the unit"
                want '.barePostStart | endswith("nft-bypass apply")' "a bare unit passes bypass flags nobody asked for"
                want '.unitPath | test("nftables")' "the bypass script has no nft on its PATH"
                # A crash holds the network with the same flags, so the hold lets past what the TUN does
                want '.stopPost | test("/libexec/skvpn/nft-bypass hold --if-failed( |$)")' "a crashed tunnel does not hold the network"
                want '.stopPost | split(" ") | .[3:] | sort == ["--docker", "--syncthing", "--tailscale"]' "the hold after a crash does not take the bypass flags"
                want '.guardUnit.serviceConfig.ExecStopPost | test("nft-bypass hold --if-failed")' "a crashed guard does not hold the network"
                # The CLI's hold and release: one template running the script's subcommand
                want '.holdExec | test("/libexec/skvpn/nft-bypass %i( |$)")' "the hold unit does not run the packaged script's subcommand"
                want '.holdExec | split(" ") | .[2:] | sort == ["--docker", "--syncthing", "--tailscale"]' "the CLI's hold does not take the bypass flags"
                want '.base | fromjson | .inbounds[0].stack == "gvisor"' "the TUN stack never reached the inbound"
                want '.base | fromjson | .inbounds[0].address == ["172.19.0.1/30"]' "ipv6 = false still gave the TUN a v6 address"
                want '.base | fromjson | .route.final == "proxy"' "the default route is not the tunnel"
                want '.extra | fromjson | .log.level == "debug"' "extraSettings never reached base.d"
                want '.timerInterval == "weekly"' "the sync interval never reached the timer"

                want '.packages | test("sing-box")' "no daemon installed"
                want '.packages | test("skvpn")' "no CLI installed"
                want '.tmpfiles == ["d /etc/sing-box/profiles 2755 root sing-box -"]' "the profiles directory is not declared listable"
                want '.services | sort == ["sing-box@", "skvpn-nft@", "skvpn-restore", "skvpn-sync"]' "a unit is missing"
                want '.firewall == "loose"' "the reverse-path filter was not loosened"
                want '.users == ["sing-box"]' "the service user is not declared"

                # trustedUsers is a pair — the NOPASSWD rule and the alias that types sudo
                want '.sudoRules[0].users == ["alice"]' "the trusted user never reached sudoers"
                want '.sudoRules[0].commands[0].command == "/run/current-system/sw/bin/skvpn"' "the sudo rule names an unstable path"
                want '.sudoRules[0].commands[0].options == ["NOPASSWD"]' "the sudo rule still asks a password"
                want '.aliases.skvpn == "sudo skvpn"' "the alias never landed"

                # A bare enable must invent no policy and write no extra file
                want '.bareBase | fromjson | .dns.rules == []' "a DNS rule appeared out of thin air"
                want '.bareBase | fromjson | .route.rules | length == 3' "a route rule appeared out of thin air"
                want '.bareBase | fromjson | .dns.servers | map(select(.tag == "remote"))[0].server == "1.1.1.1"' "the default resolver is not Cloudflare"
                want '.bareBase | fromjson | .inbounds[0] | has("route_exclude_address") | not' "a tailnet exclusion appeared without Tailscale"
                want '.bareBase | fromjson | .inbounds[0] | has("exclude_interface") | not' "a docker exclusion appeared without docker"
                want '.bareBase | fromjson | .inbounds[0].stack == "system"' "the default TUN stack drifted"
                want '.bareBase | fromjson | .inbounds[0].address == ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]' "the default TUN lost an address"
                want '.bareEtc == ["sing-box/base.d/00-base.json"]' "an empty extraSettings still wrote a file"
                want '.bareAliases == {}' "an alias appeared without trustedUsers"

                # The presets alone carry the zones and rule-sets from this flake's lock
                # The expected values come from policy.json, the presets' one source: their
                # zones in the presets' order, and the tags geosite first, then geoip
                want '.presetsBase | fromjson | .dns.rules[0].domain_suffix == ${
                  builtins.toJSON (lib.concatMap (preset: preset.zones) policy.presets)
                }' "the preset zones never reached DNS"
                want '.presetsBase | fromjson | .route.rule_set | map(.tag) == ${
                  builtins.toJSON (
                    lib.sort lib.lessThan (map (preset: "geosite-${preset.tag}") policy.presets)
                    ++ lib.sort lib.lessThan (map (preset: "geoip-${preset.tag}") policy.presets)
                  )
                }' "the preset rule-sets never landed"
                want '.presetsBase | fromjson | .route.rule_set | map(.path) | all(test("/nix/store"))' "the preset rule-set files are not store paths"

                want '.restoreOffServices | sort == ["sing-box@", "skvpn-nft@", "skvpn-sync"]' "restore.enable = false left the unit in place"

                # The guard: nothing to refuse, no guard
                want '.bareServices | index("skvpn-guard") | not' "a guard unit exists with nothing to refuse"
                want '.bareEtc | index("sing-box/guard.json") | not' "a guard config exists with nothing to refuse"
                # Every source of sites refused, in DNS and in routing
                want '.guard | fromjson | .dns.rules[:2] == [
                  {"domain_suffix": [".example.com"], "action": "predefined", "rcode": "REFUSED"},
                  {"rule_set": ["geosite-${policy.guard.tag}", "geosite-test"], "action": "predefined", "rcode": "REFUSED"}
                ]' "a guarded site still resolves"
                want '.guard | fromjson | .route.rules == [
                  {"domain_suffix": [".example.com"], "action": "reject"},
                  {"rule_set": ["geosite-${policy.guard.tag}", "geosite-test"], "action": "reject"}
                ]' "a guarded site still connects"
                want '.guard | fromjson | .route.rule_set | map(.path) | all(test("/nix/store"))' "a guard rule-set is not a store path"
                # The store name of the pinned file: its upstream name with `!` spelled `not-`
                want '.guard | fromjson | .route.rule_set[0].path | endswith("-${
                  builtins.replaceStrings [ "!" ] [ "not-" ] policy.guard.geosite
                }")' "the AI preset is not the pinned AI rule-set"
                # The base keeps `final`, so the guard must make `proxy` itself direct and send
                # the remaining DNS to the bootstrap instead of the DoT server through it
                want '.guard | fromjson | .outbounds == [{"type": "direct", "tag": "proxy", "domain_resolver": "bootstrap"}]' "the guard's proxy is not a non-empty direct outbound"
                want '.guard | fromjson | .dns.rules[-1] == {"action": "route", "server": "bootstrap"}' "unguarded names would go to DoT dialled direct"
                want '.guardBase | fromjson | .route.final == "proxy"' "the guard changed the base"
                want '.guardUnit.serviceConfig.ExecStart | endswith("-C /etc/sing-box/base.d -c /etc/sing-box/guard.json run")' "the guard does not run the base with its own file"
                want '.guardUnit.serviceConfig.AmbientCapabilities | index("CAP_NET_ADMIN")' "the guard cannot make its TUN"
                want '.guardUnit.postStart | test("nft-bypass apply")' "the guard misses the bypass rules"
                want '.guardUnit.unitConfig.ConditionPathExists == "!/sys/class/net/test-tun"' "the guard would start beside a running profile"
                want '.guardUnit.wantedBy == []' "the guard races boot restore"
                want '.guardRestoreOffWantedBy == ["multi-user.target"]' "without restore nothing starts the guard at boot"

                # The timed measurement: off unless asked for, then a root oneshot counted from
                # its own end, with the limits that keep a stuck run from living on
                want '.bareServices | index("skvpn-measure") | not' "the measurement runs without being asked for"
                want '.bareTimers == ["skvpn-sync"]' "a timer exists beside the sync one without being asked for"
                want '.measureServices | index("skvpn-measure")' "measure.enable never made the unit"
                want '.measureTimer == {"OnBootSec": "5min", "OnUnitInactiveSec": "30min"}' "the measurement timer is not counted from the end of a run, or lost its interval"
                want '.measureUnit.serviceConfig | .Type == "oneshot" and .MemoryMax == "256M" and .TimeoutStartSec == "15min"' "the measurement unit lost a limit"
                want '.measureUnit.serviceConfig.ExecStart | endswith(" measure --textfile /var/lib/collector/skvpn.prom")' "the textfile never reached the unit"
                want '.measureNoFileExec | endswith(" measure")' "a null textfile still reached the unit"
                want '.measureUnit.path | test("curl")' "the measurement unit has no curl"
                want '.measureUnit.environment.SKVPN_SING_BOX | test("/bin/sing-box$")' "the measurement unit does not run the module's sing-box"

                # The Clash API: the secret never goes through the store, so no etc entry
                # carries it; the unit that starts sing-box writes it, whether on or off
                want '.monitorEtc == ["sing-box/base.d/00-base.json"]' "the Clash API became an etc entry, which the store would make world-readable"
                want '.monitorScript != .monitorOffScript' "monitor.enable changes nothing in the script that opens the API"
                want '.monitorGuardScript == .monitorOffScript' "the guard and the profile unit run different scripts for the API"

                # …and everything can be turned off
                want '.offEtc == []' "a config file survives disabling"
                want '.offPackages == []' "a package is installed while disabled"
                want '.offTmpfiles == []' "a tmpfiles rule survives disabling"
                want '.offServices == []' "a unit survives disabling"
                want '.offUsers == []' "the service user survives disabling"
                want '.offFirewall == null' "the firewall is touched while disabled"
                want '.offSudoRules == []' "a sudo rule survives disabling"
                want '.offAliases == {}' "an alias survives disabling"
                touch $out
              '';

          # The script that opens the Clash API writes a secret, so it is run, not only
          # read: the paths it names are redirected into a scratch tree, and the sandbox has
          # no sing-box group to hand the file to
          monitor-script =
            let
              wiring = import ./nix/module-test.nix {
                inherit lib pkgs;
                nixosModule = self.nixosModules.default;
              };
            in
            pkgs.runCommand "monitor-script"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  coreutils
                  gnused
                  jq
                ];
                scriptOn = wiring.monitorScript;
                scriptOff = wiring.monitorOffScript;
              }
              ''
                root=$PWD/root
                mkdir -p "$root/etc/sing-box/base.d"
                api="$root/etc/sing-box/base.d/60-clash.json"
                secret="$root/var/lib/skvpn/clash-secret"
                run() {
                  sed -e "s|/etc/sing-box|$root/etc/sing-box|g; s|/var/lib/skvpn|$root/var/lib/skvpn|g; s|chgrp sing-box|true|" "$1" >run.sh
                  bash run.sh
                }
                fail() { echo "monitor script: $1"; exit 1; }

                run "$scriptOn"
                [ "$(stat -c %a "$secret")" = 600 ] || fail "the secret file is not root-only"
                [ "$(stat -c %a "$api")" = 640 ] || fail "the base.d file is not group-readable only"
                [ "$(wc -c <"$secret")" -ge 24 ] || fail "the secret is short"
                grep -qE '^[A-Za-z0-9]+$' "$secret" || fail "the secret has characters a header can lose"
                jq -e '.experimental.clash_api.external_controller == "127.0.0.1:19097"' "$api" >/dev/null || fail "the API is not on loopback at the option's port"
                jq -e --rawfile s "$secret" '.experimental.clash_api.secret == $s' "$api" >/dev/null || fail "base.d holds a different secret than the secret file"
                [ "$(ls -A "$root/etc/sing-box/base.d")" = 60-clash.json ] || fail "the run left a temporary file in base.d"

                first=$(cat "$secret")
                run "$scriptOn"
                [ "$(cat "$secret")" = "$first" ] || fail "a restart made a new secret"

                # Turned off, nothing of it may stay: a leftover file would open the API again
                run "$scriptOff"
                [ ! -e "$api" ] && [ ! -e "$secret" ] || fail "turning the option off left the API open"
                touch $out
              '';

          # The module and the installer's renderer each write the Tor pair and the base's Tor
          # rules; this holds the two renderings to each other, so neither drifts alone
          tor-parity =
            let
              wiring = import ./nix/module-test.nix {
                inherit lib pkgs;
                nixosModule = self.nixosModules.default;
              };
            in
            pkgs.runCommand "tor-parity"
              {
                nativeBuildInputs = with pkgs; [
                  diffutils
                  jq
                  python3
                ];
                inherit (wiring)
                  torProfile
                  torrc
                  torResolv
                  torBase
                  ;
                passAsFile = [
                  "torProfile"
                  "torrc"
                  "torResolv"
                  "torBase"
                ];
              }
              ''
                mkdir -p repo
                cp ${policyFile} repo/policy.json
                cp -r ${nonNixDir} repo/non-nix
                render() {
                  python3 repo/non-nix/render-base.py --skip-path-check --tor --tor-socks-port 19050 \
                    --tor-plugin ${lib.concatStringsSep "," policy.tor.transports}=${wiring.torLyrebird} "$@"
                }
                fail() { echo "tor parity: $1"; exit 1; }
                render --render tor | jq -S . >renderer.json
                jq -S . "$torProfilePath" >module.json
                diff -u module.json renderer.json || fail "the module and the renderer write different tor profiles"
                render --render torrc >renderer.torrc
                diff -u "$torrcPath" renderer.torrc || fail "the module and the renderer write different torrcs"
                render --render tor-resolv >renderer.resolv
                diff -u "$torResolvPath" renderer.resolv || fail "the module and the renderer give Tor different resolvers"
                pick='{onion: [.dns.servers[] | select(.tag == "onion")], dns: .dns.rules[0], tor: [.outbounds[] | select(.tag == "tor")], route: .route.rules[2]}'
                render | jq -S "$pick" >renderer-base.json
                jq -S "$pick" "$torBasePath" >module-base.json
                diff -u module-base.json renderer-base.json || fail "the module and the renderer route .onion differently"
                touch $out
              '';

          # The stub test above cannot see this: a stubbed option accepts anything, so a
          # module that writes to the wrong one still passes it. Here the real module set
          # gets to refuse
          nixos-eval =
            let
              real = import ./nix/nixos-eval.nix {
                inherit lib nixpkgs system;
                module = self.nixosModules.default;
              };
            in
            pkgs.runCommand "nixos-eval"
              {
                nativeBuildInputs = with pkgs; [ jq ];
                dump = builtins.toJSON real;
                passAsFile = [ "dump" ];
              }
              ''
                want() { jq -e "$1" "$dumpPath" >/dev/null || { echo "nixos eval: $2"; exit 1; }; }

                want 'keys == [
                  "dockerFollowBase", "enabledAlias", "enabledBase", "enabledBroken",
                  "enabledExtra", "enabledFirewall", "enabledGuardConfig", "enabledGuardUnit",
                  "enabledMeasureTimer", "enabledMeasureUnit", "enabledNftUnit", "enabledRestore", "enabledSudo",
                  "enabledTemplateUnit", "enabledTimer", "enabledTmpfiles", "enabledTorUnit",
                  "hostStrictBroken", "hostStrictFirewall", "offAlias", "offBroken", "offEtc",
                  "offRestore", "offUser", "restoreOffPresent", "restoreOffTemplate",
                  "singBoxUserGroup", "syncthingFollowPostStart", "torUserGroup"
                ]' "the dump no longer has the keys these checks read"

                want '.enabledTorUnit | test("ExecStart=/nix/store/[^\n]*/bin/tor -f /etc/sing-box/torrc") and test("User=${policy.tor.user}") and test("ConditionPathExists=/var/lib/skvpn/tor-bridges.conf")' "the Tor unit did not survive the real module set"
                want '.torUserGroup == "${policy.tor.user}"' "the Tor user lost its group"

                want '.enabledBroken == []' "an enabled module breaks the system"
                want '.enabledBase | fromjson | .route.final == "proxy"' "the base did not survive the real module set"
                want '.enabledBase | fromjson | .inbounds[0].route_exclude_address | length == 2' "the tailnet exclusion did not survive"
                want '.enabledBase | fromjson | .route.rules | any(.process_name == ["firefox"])' "the split list did not survive the real module set"
                want '.dockerFollowBase | fromjson | .inbounds[0].route_exclude_address == ["10.42.0.0/16"]' "docker address pools did not follow the host docker settings"
                want '.dockerFollowBase | fromjson | .inbounds[0].exclude_interface == ["docker0"]' "docker default bridge is not excluded"
                want '.enabledExtra | fromjson | .log.level == "debug"' "extraSettings did not survive"
                want '.syncthingFollowPostStart | endswith("apply --syncthing")' "syncthing.enable does not follow the host's Syncthing"
                want '.enabledGuardConfig | fromjson | .route.rules[0].action == "reject"' "the guard config did not survive the real module set"
                want '.enabledGuardUnit | test("ConditionPathExists=!/sys/class/net/skvpn-tun")' "the guard unit lost its running-profile condition"
                want '.enabledGuardUnit | test("PATH=[^\n]*nftables")' "the guard unit has no nft on its PATH"
                want '.enabledGuardUnit | test("ExecStartPost=")' "the guard unit lost its bypass rules"
                want '.enabledMeasureUnit | test("Type=oneshot") and test("MemoryMax=256M") and test("TimeoutStartSec=15min")' "the measurement unit lost its limits"
                want '.enabledMeasureUnit | test("ExecStart=[^\n]* measure --textfile /var/lib/collector/skvpn.prom")' "the measurement unit does not write the textfile"
                want '.enabledMeasureUnit | test("PATH=[^\n]*curl")' "the measurement unit has no curl on its PATH"
                want '.enabledMeasureTimer | test("OnUnitInactiveSec=1h") and test("OnBootSec=5min")' "the measurement timer is not counted from the end of a run"
                want '.enabledTemplateUnit | test("ExecStartPre=\\+/nix/store/[^\n]*skvpn-clash-api")' "the template unit does not run the Clash API script as root"
                want '.enabledTemplateUnit | test("ExecStopPost=/nix/store/[^\n]*nft-bypass hold --if-failed")' "the template unit does not hold the network after a crash"
                want '.enabledNftUnit | test("Type=oneshot") and test("ExecStart=/nix/store/[^\n]*nft-bypass %i") and test("PATH=[^\n]*nftables")' "the hold unit cannot run nft-bypass"
                want '.enabledTmpfiles == ["d /etc/sing-box/profiles 2755 root sing-box -"]' "the tmpfiles rule did not survive"
                want '.enabledTimer == "daily"' "the default sync interval did not survive"
                want '.enabledFirewall == "loose"' "the reverse-path filter was not loosened"
                want '.enabledRestore' "the restore unit is missing"
                want '.singBoxUserGroup == "sing-box"' "the service user lost its group"
                want '.enabledSudo | length == 1' "the NOPASSWD rule did not survive the real sudo module"
                want '.enabledSudo[0].users == ["alice"]' "the trusted user fell out of the rule"
                want '.enabledAlias == "sudo skvpn"' "the alias did not survive"

                # mkDefault is the whole point: an explicit host value must win
                want '.hostStrictBroken == []' "a host with its own rpfilter breaks"
                want '.hostStrictFirewall == true' "the module overrode the host's explicit rpfilter"

                want '.restoreOffPresent == false' "restore.enable = false left the unit in place"
                want '.restoreOffTemplate' "restore.enable = false took the template unit with it"

                want '.offBroken == []' "a disabled module breaks the system"
                want '.offEtc == false' "a config file survives disabling"
                want '.offUser == false' "the service user survives disabling"
                want '.offRestore == false' "a unit survives disabling"
                want '.offAlias == null' "an alias survives disabling"
                touch $out
              '';

          scripts-lint =
            pkgs.runCommand "scripts-lint"
              {
                nativeBuildInputs = with pkgs; [
                  # check-sh.sh below is moving to reading the script it is given as a tree,
                  # out of `shfmt --to-json`, with jq flattening that tree into rows. This
                  # sandbox has a scrubbed PATH, so the dev shell's jq is not reachable here
                  # and the tool has to be named on this derivation
                  jq
                  python3.pkgs.flake8
                  shellcheck
                  shfmt
                  zsh
                ];
              }
              ''
                files="${installer} ${bypassScript} ${testsDir}/run.sh ${testsDir}/distro.sh ${testsDir}/docker-routing.sh ${testsDir}/stub/* ${completionsDir}/skvpn.bash ${completionsDir}/install.sh.bash ${checkSh}"
                # shellcheck disable=SC2086
                shellcheck $files
                # shellcheck disable=SC2086
                shfmt -d -i 2 -ci $files
                # zsh is not shellcheck's language; a parse is what can be checked
                zsh -n ${completionsDir}/_skvpn
                zsh -n ${completionsDir}/install.sh.zsh
                flake8 --max-line-length=88 ${nonNixDir}/render-base.py

                # install.sh, its help and its completions must not drift apart
                mkdir -p repo
                cp ${installer} repo/install.sh
                cp ${versionFile} repo/VERSION
                cp -r ${completionsDir} repo/completions
                cp ${checkSh} repo/check-sh.sh
                (cd repo && bash ./check-sh.sh -c completions/install.sh.bash completions/install.sh.zsh install.sh)
                touch $out
              '';
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            python3
            python3.pkgs.flake8
            shellcheck
            shfmt
            # tests/run.sh checks the phone config with the real one, behind its stub
            sing-box
          ];
        };
        ci-docker-routing = pkgs.mkShell {
          packages = with pkgs; [
            nftables
            sing-box
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
