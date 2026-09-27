{
  bubblewrap,
  fetchurl,
  lib,
  makeBinaryWrapper,
  python3,
  procps,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "codex";
  version = "0.160.1";

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${finalAttrs.version}/codex-package-x86_64-unknown-linux-musl.tar.gz";
    hash = "sha256-NAgBVlkGpwKPa6qpq2hTrdrvIh8AFqFBenwf/dlsIfA=";
  };

  nativeBuildInputs = [ makeBinaryWrapper ];

  unpackPhase = ''
    runHook preUnpack

    mkdir source
    tar -xzf $src -C source
    cd source

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    # Keep the upstream package layout intact. The daemon copies this bundle
    # and checks that its declared entrypoint matches the running executable.
    mkdir -p $out/bin $out/libexec/codex
    cp -R . $out/libexec/codex/
    ln -s ../libexec/codex/bin/codex-code-mode-host $out/bin/codex-code-mode-host

    runHook postInstall
  '';

  postFixup = ''
    makeBinaryWrapper $out/libexec/codex/bin/codex $out/bin/codex \
      --prefix PATH : ${lib.makeBinPath [ bubblewrap procps ]}
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ python3 ];
  installCheckPhase = ''
    runHook preInstallCheck
    ${python3}/bin/python3 -B ${./test_daemon.py} $out/bin/codex
    runHook postInstallCheck
  '';

  meta = {
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    changelog = "https://raw.githubusercontent.com/openai/codex/refs/tags/rust-v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = [ "x86_64-linux" ];
  };
})
