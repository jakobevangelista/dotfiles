{
  fetchurl,
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "grok";
  version = "1.0.52";

  src = fetchurl {
    urls = [
      "https://x.ai/cli/grok-${finalAttrs.version}-linux-x86_64"
      "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${finalAttrs.version}-linux-x86_64"
    ];
    hash = "sha256-FmhBSwR+EFCpbSX+F9/D7+YxkPv2bYzBw96GM8r1DRE=";
  };

  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 $src $out/bin/grok
    ln -s grok $out/bin/agent

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    tmp_home="$(mktemp -d)"
    actual_version="$(HOME="$tmp_home" $out/bin/grok --version)"
    rm -rf "$tmp_home"

    if [[ "$actual_version" != *"${finalAttrs.version}"* ]]; then
      echo "Built Grok reported $actual_version, expected ${finalAttrs.version}." >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "Terminal-based AI coding agent from xAI";
    homepage = "https://x.ai/cli";
    downloadPage = "https://github.com/xai-org/grok-build";
    changelog = "https://x.ai/build/changelog";
    license = lib.licenses.asl20;
    mainProgram = "grok";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
