{
  fetchFromGitHub,
  opencode,
}:

let
  version = "1.17.9";
  src = fetchFromGitHub {
    owner = "anomalyco";
    repo = "opencode";
    tag = "v${version}";
    hash = "sha256-OWfI2dp0PeNShVZMzEdm69EtxWX7UwmyPmX02SfrjP8=";
  };
in
opencode.overrideAttrs (old: {
  inherit version src;

  node_modules = old.node_modules.overrideAttrs (_: {
    inherit version src;
    outputHash = "sha256-ERywlcNEF9EUW3JDGH8987g+GAj76RylUtegqMvStyg=";
  });
})
