# The CLI alone: the units, the sing-box user and the base config live in the NixOS module.
# sing-box itself is deliberately NOT a runtime input — the tool only writes profiles and
# talks to systemd, and the daemon the unit starts is the module's own choice
{
  lib,
  stdenvNoCC,
  installShellFiles,
  python3,
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
  buildInputs = [ python3 ];

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
    patchShebangs $out/bin
    # skvpn --version reads this at share/skvpn/VERSION relative to the binary
    install -Dm644 ${versionFile} $out/share/skvpn/VERSION

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
