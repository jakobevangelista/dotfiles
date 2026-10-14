{
  fetchurl,
  lib,
  stdenvNoCC,
}:

let
  manifest = lib.importJSON ./manifest.json;
  artifact = manifest.artifacts.x86_linux;
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "muse";
  inherit (manifest) version;

  src = fetchurl {
    name = "muse";
    url = artifact.url;
    sha256 = artifact.checksum;
  };

  # Upstream ships a static executable, including its Linux sandbox helper.
  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 $src $out/bin/muse

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    tmp_home="$(mktemp -d)"
    actual_version="$(cd "$tmp_home" && HOME="$tmp_home" $out/bin/muse --version)"
    rm -rf "$tmp_home"

    if [[ "$actual_version" != *"${finalAttrs.version}"* ]]; then
      echo "Built Muse reported $actual_version, expected ${finalAttrs.version}." >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "Meta's coding agent for the terminal";
    homepage = "https://dev.meta.ai/docs/muse-code";
    downloadPage = "https://dev.meta.ai/install.sh";
    license = lib.licenses.unfree;
    mainProgram = "muse";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
