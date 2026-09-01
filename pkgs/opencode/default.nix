{
  fetchFromGitHub,
  opencode,
}:

let
  version = "1.18.21";
  src = fetchFromGitHub {
    owner = "anomalyco";
    repo = "opencode";
    tag = "v${version}";
    hash = "sha256-WKG/lts+wzDjYJ5pOZ0X4Kb0rJ1TzYQzQgjyQBY+bxs=";
  };
in
opencode.overrideAttrs (old: {
  inherit version src;

  node_modules = old.node_modules.overrideAttrs (_: {
    inherit version src;
    outputHash = "sha256-dGASaxZnxzJZY1PuDeqQCnYgMm2gEf5HZQsWOnt2JaU=";
  });
})
