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
      lib = nixpkgs.lib;
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
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
      });

      # builtins.path keeps single files out of the input trees, so the module's closure
      # carries the enabled presets' rule-set files rather than both branches
      nixosModules.default = import ./nix/module.nix {
        inherit self;
        ruleSetFiles =
          let
            one =
              input: file:
              builtins.path {
                name = file;
                path = "${input}/${file}";
              };
          in
          {
            geosite-ru = one sing-geosite "geosite-category-ru.srs";
            geoip-ru = one sing-geoip "geoip-ru.srs";
            geosite-cn = one sing-geosite "geosite-cn.srs";
            geoip-cn = one sing-geoip "geoip-cn.srs";
            geosite-ir = one sing-geosite "geosite-category-ir.srs";
            geoip-ir = one sing-geoip "geoip-ir.srs";
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
                  systemd
                ];
              }
              ''
                mkdir -p repo
                cp ${script} repo/skvpn.py
                cp ${versionFile} repo/VERSION
                cp ${installer} repo/install.sh
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
            pkgs.runCommand "package-smoke" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
              test -x ${skvpn}/bin/skvpn
              # No systemctl in the sandbox, so the usage line is how far a run can get
              (${skvpn}/bin/skvpn 2>&1 || true) | grep -F 'usage: skvpn' >/dev/null
              test -f ${skvpn}/share/bash-completion/completions/skvpn
              test -f ${skvpn}/share/zsh/site-functions/_skvpn
              touch $out
            '';

          module-wiring =
            let
              wiring = import ./nix/module-test.nix {
                inherit lib pkgs;
                nixosModule = self.nixosModules.default;
              };
            in
            pkgs.runCommand "module-wiring"
              {
                nativeBuildInputs = [ pkgs.jq ];
                dump = builtins.toJSON wiring;
                passAsFile = [ "dump" ];
              }
              ''
                want() { jq -e "$1" "$dumpPath" >/dev/null || { echo "module wiring: $2"; exit 1; }; }

                # The field names below are written a second time here, so a rename in
                # module-test.nix would otherwise surface as a stray failure in whichever
                # check read the key first — and jq answers 0 for the length of a missing one
                want 'keys == [
                  "aliases", "bareAliases", "bareBase", "bareEtc", "base", "capabilities", "dockerPostStart",
                  "extra", "firewall", "offAliases", "offEtc", "offFirewall", "offPackages",
                  "offServices", "offSudoRules", "offTmpfiles", "offUsers", "packages",
                  "presetsBase", "restoreOffServices", "services", "splitBase", "splitBroken",
                  "splitSingBoxBroken", "sudoRules", "timerInterval", "tmpfiles", "users"
                ]' "the dump no longer has the keys these checks read"

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
                want '.splitBase | fromjson | .dns.rules == [{"process_name": ["firefox"], "server": "bootstrap"}, {"process_path": ["/usr/bin/steam"], "server": "bootstrap"}, {"process_path_regex": ["(^|/)chrom[^/]*$", "^/opt/[^/]*/bin/tor$"], "server": "bootstrap"}]' "split DNS rules drifted"
                want '.bareBase | fromjson | .route.rules | map(select(has("process_name") or has("process_path") or has("ip_cidr"))) == []' "a bare base carries split rules"

                # Every policy knob has to reach the rendered base, or it is decoration
                want '.base | fromjson | .dns.rules[0].domain_suffix == [".ru", ".su"]' "zones never reached DNS"
                want '.bareBase | fromjson | .dns.reverse_mapping == true' "a nameless connection would miss every domain rule"
                want '.base | fromjson | .dns.rules[1].rule_set == ["geosite-test"]' "geosite never reached DNS"
                want '.base | fromjson | .route.rules[-1].rule_set == ["geosite-test", "geoip-test"]' "rule-sets never reached routing"
                want '.base | fromjson | .route.rules[-2].domain_suffix == [".ru", ".su"]' "zones never reached routing"
                want '.base | fromjson | .route.rule_set | map(.path) | all(test("/nix/store"))' "rule-set files are not store paths"
                want '.base | fromjson | .inbounds[0].route_exclude_address == ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]' "the tailnet is not excluded"
                want '.base | fromjson | .inbounds[0].exclude_interface == ["docker0"]' "the docker bridge is not excluded"
                want '.dockerPostStart | contains("iifname \"br-*\"")' "dynamic Docker bridges are not excluded"
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
                want '.bareBase | fromjson | .inbounds[0] | has("route_exclude_address") | not' "a tailnet exclusion appeared without Tailscale"
                want '.bareBase | fromjson | .inbounds[0] | has("exclude_interface") | not' "a docker exclusion appeared without docker"
                want '.bareBase | fromjson | .inbounds[0].stack == "system"' "the default TUN stack drifted"
                want '.bareBase | fromjson | .inbounds[0].address == ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]' "the default TUN lost an address"
                want '.bareEtc == ["sing-box/base.d/00-base.json"]' "an empty extraSettings still wrote a file"
                want '.bareAliases == {}' "an alias appeared without trustedUsers"

                # The presets alone carry the zones and rule-sets from this flake's lock
                want '.presetsBase | fromjson | .dns.rules[0].domain_suffix == [
                  ".ru", ".su", ".xn--p1ai", ".cn", ".xn--fiqs8s", ".xn--fiqz9s", ".ir", ".xn--mgba3a4f16a"
                ]' "the preset zones never reached DNS"
                want '.presetsBase | fromjson | .route.rule_set | map(.tag) == [
                  "geosite-cn", "geosite-ir", "geosite-ru", "geoip-cn", "geoip-ir", "geoip-ru"
                ]' "the preset rule-sets never landed"
                want '.presetsBase | fromjson | .route.rule_set | map(.path) | all(test("/nix/store"))' "the preset rule-set files are not store paths"

                want '.restoreOffServices | sort == ["sing-box@", "skvpn-sync"]' "restore.enable = false left the unit in place"

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
                nativeBuildInputs = [ pkgs.jq ];
                dump = builtins.toJSON real;
                passAsFile = [ "dump" ];
              }
              ''
                want() { jq -e "$1" "$dumpPath" >/dev/null || { echo "nixos eval: $2"; exit 1; }; }

                want 'keys == [
                  "dockerFollowBase", "enabledAlias", "enabledBase", "enabledBroken",
                  "enabledExtra", "enabledFirewall", "enabledRestore", "enabledSudo",
                  "enabledTimer", "enabledTmpfiles", "hostStrictBroken",
                  "hostStrictFirewall", "offAlias", "offBroken", "offEtc", "offRestore",
                  "offUser", "restoreOffPresent", "restoreOffTemplate", "singBoxUserGroup"
                ]' "the dump no longer has the keys these checks read"

                want '.enabledBroken == []' "an enabled module breaks the system"
                want '.enabledBase | fromjson | .route.final == "proxy"' "the base did not survive the real module set"
                want '.enabledBase | fromjson | .inbounds[0].route_exclude_address | length == 2' "the tailnet exclusion did not survive"
                want '.enabledBase | fromjson | .route.rules | any(.process_name == ["firefox"])' "the split list did not survive the real module set"
                want '.dockerFollowBase | fromjson | .inbounds[0].route_exclude_address == ["10.42.0.0/16"]' "docker address pools did not follow the host docker settings"
                want '.dockerFollowBase | fromjson | .inbounds[0].exclude_interface == ["docker0"]' "docker default bridge is not excluded"
                want '.enabledExtra | fromjson | .log.level == "debug"' "extraSettings did not survive"
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
                nativeBuildInputs = [
                  pkgs.python3.pkgs.flake8
                  pkgs.shellcheck
                  pkgs.shfmt
                  pkgs.zsh
                ];
              }
              ''
                files="${installer} ${testsDir}/run.sh ${testsDir}/distro.sh ${testsDir}/docker-routing.sh ${testsDir}/check-completions.sh ${testsDir}/stub/* ${completionsDir}/skvpn.bash ${completionsDir}/install.sh.bash"
                # shellcheck disable=SC2086
                shellcheck $files
                # shellcheck disable=SC2086
                shfmt -d -i 2 -ci $files
                # zsh is not shellcheck's language; a parse is what can be checked
                zsh -n ${completionsDir}/_skvpn
                zsh -n ${completionsDir}/install.sh.zsh
                flake8 --max-line-length=88 ${nonNixDir}/render-base.py

                # install.sh and its completions must not drift apart
                mkdir -p repo/tests
                cp ${installer} repo/install.sh
                cp -r ${completionsDir} repo/completions
                cp ${testsDir}/check-completions.sh repo/tests/
                bash repo/tests/check-completions.sh
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
