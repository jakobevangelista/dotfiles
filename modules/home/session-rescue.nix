{ pkgs, ... }:

let
  sessions = pkgs.callPackage ../../pkgs/odin-sessions { };
in
{
  home.packages = [ sessions ];

  # A legacy ~/.local/bin launcher may shadow this, depending on PATH.
  # Handle that launcher separately and preserve the private snapshots.
  home.file."bin/odin-sessions".source = "${sessions}/bin/odin-sessions";
}
