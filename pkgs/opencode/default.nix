{
  autoPatchelfHook,
  fetchurl,
  lib,
  makeBinaryWrapper,
  ripgrep,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "opencode";
  version = "1.18.27";

  src = fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v${finalAttrs.version}/opencode-linux-x64.tar.gz";
    hash = "sha256-SvVJT5Qz9Z24weNEGY8O5ypQwG7ACftKiuq0wtSr1wI=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeBinaryWrapper
  ];

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;

  unpackPhase = ''
    runHook preUnpack

    mkdir source
    tar -xzf $src -C source
    cd source

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 opencode $out/bin/opencode

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/opencode \
      --prefix PATH : ${lib.makeBinPath [ ripgrep ]}
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    tmp_home="$(mktemp -d)"
    actual_version="$(cd "$tmp_home" && HOME="$tmp_home" $out/bin/opencode --version)"
    rm -rf "$tmp_home"

    if [[ "$actual_version" != *"${finalAttrs.version}"* ]]; then
      echo "Built OpenCode reported $actual_version, expected ${finalAttrs.version}." >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "AI coding agent built for the terminal";
    homepage = "https://opencode.ai/";
    downloadPage = "https://github.com/anomalyco/opencode/releases";
    license = lib.licenses.mit;
    mainProgram = "opencode";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
