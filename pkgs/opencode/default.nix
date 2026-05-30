{
  fetchFromGitHub,
  opencode,
}:

let
  version = "1.15.12";
  src = fetchFromGitHub {
    owner = "anomalyco";
    repo = "opencode";
    tag = "v${version}";
    hash = "sha256-ecSZVJ1uyubWcIhp29FS0MA2MCgURN2jo6CFRJ1mm2I=";
  };
in
opencode.overrideAttrs (old: {
  inherit version src;

  node_modules = old.node_modules.overrideAttrs (_: {
    inherit version src;
    outputHash = "sha256-x5qbmA4/EhEbqyGHAy8VRXw9Do8QYHTRLeZXuyvd4QY=";
  });
})
