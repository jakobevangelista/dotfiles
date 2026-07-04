{
  fetchFromGitHub,
  opencode,
}:

let
  version = "1.18.3";
  src = fetchFromGitHub {
    owner = "anomalyco";
    repo = "opencode";
    tag = "v${version}";
    hash = "sha256-Wdkzms59oHw3M/Em2RH7BPhZME8AtLmtNFSnsUxO1V4=";
  };
in
opencode.overrideAttrs (old: {
  inherit version src;

  node_modules = old.node_modules.overrideAttrs (_: {
    inherit version src;
    outputHash = "sha256-jOK4jJv6SY+JIRUG9ryiBe8IfhDLAnGG52ACUJssNtA=";
  });
})
