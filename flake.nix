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
                  "base", "bittorrentBase", "capabilities", "extra", "firewall", "guard", "guardBase",
                  "guardRestoreOffWantedBy", "guardUnit", "offAliases", "offEtc", "offFirewall",
                  "offPackages", "offServices", "offSudoRules", "offTmpfiles", "offUsers",
                  "packages", "postStart", "presetsBase", "restoreOffServices", "services",
                  "splitBase", "splitBroken", "splitSingBoxBroken", "sudoRules", "timerInterval",
                  "tmpfiles", "tunedBroken", "unitPath", "users", "viaTunnelAloneBroken"
                ]' "the dump no longer has the keys these checks read"

                # An exit address only narrows the Tailscale bypass, so it needs one to narrow
                want '.tunedBroken == []' "a tailnet with an exit address trips an assertion"
                want '.viaTunnelAloneBroken | length == 1 and (.[0] | test("viaTunnel"))' "an exit address without the Tailscale bypass was not refused"

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
                want '.postStart | split(" ") | .[2:] | map(select(startswith("--"))) | unique == ["--docker", "--syncthing", "--tailscale", "--tailscale-via-tunnel"]' "a bypass flag never reached the unit"
                want '.postStart | test(" --tailscale-via-tunnel 192\\.0\\.2\\.10 --tailscale-via-tunnel 2001:db8::10( |$)")' "an exit address never reached the unit"
                want '.barePostStart | endswith("nft-bypass apply")' "a bare unit passes bypass flags nobody asked for"
                want '.unitPath | test("nftables")' "the bypass script has no nft on its PATH"
                want '.base | fromjson | .inbounds[0].stack == "gvisor"' "the TUN stack never reached the inbound"
                want '.base | fromjson | .inbounds[0].address == ["172.19.0.1/30"]' "ipv6 = false still gave the TUN a v6 address"
                want '.base | fromjson | .route.final == "proxy"' "the default route is not the tunnel"
                want '.extra | fromjson | .log.level == "debug"' "extraSettings never reached base.d"
                want '.timerInterval == "weekly"' "the sync interval never reached the timer"

                want '.packages | test("sing-box")' "no daemon installed"
                want '.packages | test("skvpn")' "no CLI installed"
                want '.tmpfiles == ["d /etc/sing-box/profiles 2755 root sing-box -"]' "the profiles directory is not declared listable"
                want '.services | sort == ["sing-box@", "skvpn-restore", "skvpn-sync"]' "a unit is missing"
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

                want '.restoreOffServices | sort == ["sing-box@", "skvpn-sync"]' "restore.enable = false left the unit in place"

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
                  "enabledRestore", "enabledSudo", "enabledTimer", "enabledTmpfiles",
                  "hostStrictBroken", "hostStrictFirewall", "offAlias", "offBroken", "offEtc",
                  "offRestore", "offUser", "restoreOffPresent", "restoreOffTemplate",
                  "singBoxUserGroup", "syncthingFollowPostStart"
                ]' "the dump no longer has the keys these checks read"

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
                files="${installer} ${bypassScript} ${testsDir}/run.sh ${testsDir}/distro.sh ${testsDir}/docker-routing.sh ${testsDir}/tailscale-routing.sh ${testsDir}/stub/* ${completionsDir}/skvpn.bash ${completionsDir}/install.sh.bash ${checkSh}"
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
            iproute2
            nftables
            python3
            sing-box
            util-linux
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
