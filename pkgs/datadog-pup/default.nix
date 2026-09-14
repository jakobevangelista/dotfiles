{
  autoPatchelfHook,
  fetchurl,
  lib,
  makeWrapper,
  openssl,
  stdenv,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "datadog-pup";
  version = "1.22.1";

  src = fetchurl {
    url = "https://github.com/DataDog/pup/releases/download/v${finalAttrs.version}/pup_${finalAttrs.version}_Linux_x86_64.tar.gz";
    hash = "sha256-eWDMDGPDufIn79F+rOS9zzzD4KTUP1Y6rlSkJIsXSZk=";
  };

  sourceRoot = ".";
  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [
    openssl
    stdenv.cc.cc.lib
  ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 pup "$out/bin/pup"
    runHook postInstall
  '';

  # SSH sessions have no unlocked desktop keyring. Keep the backend identical
  # for login and subsequent commands, including non-interactive invocations.
  postFixup = ''
    wrapProgram "$out/bin/pup" --set-default DD_TOKEN_STORAGE file
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/pup" --version | grep -F '${finalAttrs.version}'
    "$out/bin/pup" auth login --help | grep -F -- '--callback-port'
  '';

  meta = {
    description = "Datadog CLI with browser OAuth support";
    homepage = "https://github.com/DataDog/pup";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "pup";
    platforms = [ "x86_64-linux" ];
  };
})
