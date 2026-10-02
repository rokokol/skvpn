# The CLI alone: the units, the sing-box user and the base config live in the NixOS module.
# sing-box itself is deliberately NOT a runtime input — the tool only writes profiles and
# talks to systemd, and the daemon the unit starts is the module's own choice
{
  lib,
  stdenvNoCC,
  installShellFiles,
  python3,
  bash,
}:

let
  # Each piece isolated, so a README edit doesn't rebuild the package
  script = builtins.path {
    name = "skvpn.py";
    path = ../skvpn.py;
  };
  versionFile = builtins.path {
    name = "skvpn-VERSION";
    path = ../VERSION;
  };
  bashCompletion = builtins.path {
    name = "skvpn.bash";
    path = ../completions/skvpn.bash;
  };
  zshCompletion = builtins.path {
    name = "_skvpn";
    path = ../completions/_skvpn;
  };
  policyFile = builtins.path {
    name = "skvpn-policy.json";
    path = ../policy.json;
  };
  bypassScript = builtins.path {
    name = "nft-bypass.sh";
    path = ../nft-bypass.sh;
  };
in

stdenvNoCC.mkDerivation {
  pname = "skvpn";
  # VERSION is the one place the number lives; CI holds CHANGELOG.md to it
  version = lib.fileContents ../VERSION;

  dontUnpack = true;
  nativeBuildInputs = [
    installShellFiles
    python3.pkgs.flake8
  ];
  # bash for the bypass script's shebang, which patchShebangs resolves from here
  buildInputs = [
    python3
    bash
  ];

  # The same lint writePython3Bin used to run when the script lived in a NixOS config
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    flake8 --extend-ignore E501 ${script}
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 ${script} $out/bin/skvpn
    # skvpn --version reads this at share/skvpn/VERSION relative to the binary
    install -Dm644 ${versionFile} $out/share/skvpn/VERSION
    # skvpn export reads the tailnet and the rule-set sources here, as it reads VERSION
    install -Dm644 ${policyFile} $out/share/skvpn/policy.json
    # The units' ExecStartPost; nft comes from the unit's PATH, which the module sets
    install -Dm755 ${bypassScript} $out/libexec/skvpn/nft-bypass
    patchShebangs $out/bin $out/libexec

    installShellCompletion --bash --name skvpn ${bashCompletion}
    installShellCompletion --zsh --name _skvpn ${zshCompletion}

    runHook postInstall
  '';

  meta = {
    description = "Manage sing-box VPN profiles as systemd template instances";
    homepage = "https://github.com/rokokol/skvpn";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "skvpn";
  };
}
