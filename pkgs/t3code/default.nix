{
  autoPatchelfHook,
  fetchurl,
  lib,
  makeBinaryWrapper,
  stdenv,
  stdenvNoCC,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "t3code";
  version = "0.0.46-nightly.20261013.3080";

  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${finalAttrs.version}/t3-${finalAttrs.version}-linux-x64.tar.gz";
    hash = "sha256-099oL/2voB7PGhJos4C13dKEIb75QEZ0puhu2F9FT4E=";
  };

  nativeBuildInputs = [ autoPatchelfHook makeBinaryWrapper ];
  buildInputs = [ stdenv.cc.cc.lib ];
  dontBuild = true;
  # The Bun executable embeds its server bundle; stripping can corrupt it.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/libexec/t3code" "$out/bin"
    cp -a t3 client node_modules resource-monitor "$out/libexec/t3code/"
    # NixOS uses glibc; this bundled alternative must not be patched against it.
    rm -r "$out/libexec/t3code/node_modules/@ff-labs/fff-bin-linux-x64-musl"

    makeBinaryWrapper "$out/libexec/t3code/t3" "$out/bin/t3" \
      --set-default T3CODE_RESOURCE_MONITOR_PATH \
      "$out/libexec/t3code/resource-monitor/linux-x64/t3-resource-monitor"

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook writableTmpDirAsHomeHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "T3 Code nightly headless server for coding agents";
    homepage = "https://github.com/pingdotgg/t3code";
    changelog = "https://github.com/pingdotgg/t3code/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "t3";
    platforms = [ "x86_64-linux" ];
  };
})
