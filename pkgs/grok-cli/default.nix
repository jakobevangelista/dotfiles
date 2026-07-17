{
  buildFHSEnv,
  fetchurl,
  lib,
  stdenvNoCC,
}:

let
  version = "1.1.7";

  grokBinary = stdenvNoCC.mkDerivation {
    pname = "grok-cli-binary";
    inherit version;

    src = fetchurl {
      url = "https://github.com/superagent-ai/grok-cli/releases/download/grok-dev%40${version}/grok-linux-x64";
      hash = "sha256-5ngNLm2ktAboYvSD+0GW/sVvHfNyJD1cv5PNv8ewSl8=";
    };

    dontUnpack = true;

    installPhase = ''
      runHook preInstall

      install -Dm755 $src $out/bin/grok

      runHook postInstall
    '';
  };
in
(buildFHSEnv {
  name = "grok";
  targetPkgs = _pkgs: [ ];
  runScript = "${grokBinary}/bin/grok";
}).overrideAttrs (_old: {
  pname = "grok-cli";
  inherit version;

  passthru = { inherit grokBinary; };

  meta = {
    description = "AI coding agent powered by Grok";
    homepage = "https://github.com/superagent-ai/grok-cli";
    changelog = "https://github.com/superagent-ai/grok-cli/releases/tag/grok-dev%40${version}";
    license = lib.licenses.mit;
    mainProgram = "grok";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
