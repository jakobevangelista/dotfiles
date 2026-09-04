{
  autoPatchelfHook,
  fetchurl,
  lib,
  makeBinaryWrapper,
  ripgrep,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "amp-cli";
  version = "0.0.1788436865-g512c6e";

  src = fetchurl {
    url = "https://static.ampcode.com/cli/${finalAttrs.version}/amp-linux-x64";
    hash = "sha256-qTiNq64H26gCo0zzQYq5VjJy/9Xbtg4nXzM94nRqNkU=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeBinaryWrapper
  ];

  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 $src $out/bin/amp

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/amp \
      --prefix PATH : ${lib.makeBinPath [ ripgrep ]} \
      --set AMP_SKIP_UPDATE_CHECK 1
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    tmp_home="$(mktemp -d)"
    actual_version="$(HOME="$tmp_home" $out/bin/amp --version)"
    rm -rf "$tmp_home"

    if [[ "$actual_version" != *"${finalAttrs.version}"* ]]; then
      echo "Built Amp reported $actual_version, expected ${finalAttrs.version}." >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "Frontier coding agent for the terminal and editor";
    homepage = "https://ampcode.com/";
    downloadPage = "https://ampcode.com/manual#installation";
    license = lib.licenses.unfree;
    mainProgram = "amp";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
