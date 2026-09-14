{
  awscli2,
  callPackage,
  google-cloud-sdk,
  kubectl,
  openssh,
  python3,
  tailscale,
  writeShellApplication,
}:

writeShellApplication {
  name = "work";
  runtimeInputs = [
    awscli2
    google-cloud-sdk
    kubectl
    openssh
    tailscale
    (callPackage ../datadog-pup { })
    (callPackage ../pscale { })
  ];
  text = ''
    # Do not put the entire virtiofs-backed /nix/store on Python's import path.
    exec ${python3}/bin/python3 -P ${./work.py} "$@"
  '';
  derivationArgs = {
    doCheck = true;
    checkPhase = ''
      ${python3}/bin/python3 -P ${./test_work.py} ${./work.py}
    '';
  };
}
