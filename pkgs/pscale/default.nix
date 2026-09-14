{
  fetchurl,
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pscale";
  version = "0.335.0";

  src = fetchurl {
    url = "https://github.com/planetscale/cli/releases/download/v${finalAttrs.version}/pscale_${finalAttrs.version}_linux_amd64.tar.gz";
    hash = "sha256-gmvzRbviGTjp7xp0N9nPYq4KS7Nz573BIGi6S4iz4yU=";
  };

  sourceRoot = ".";
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 pscale "$out/bin/pscale"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/pscale" version | grep -F '${finalAttrs.version}'
    "$out/bin/pscale" insights queries --help >/dev/null
    "$out/bin/pscale" insights errors --help >/dev/null
  '';

  meta = {
    description = "PlanetScale CLI including Postgres Insights";
    homepage = "https://github.com/planetscale/cli";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "pscale";
    platforms = [ "x86_64-linux" ];
  };
})
