{ lib, ... }:

{
  # Muninn deliberately presents the same user environment as Odin. The
  # workstation's home is persistent, while selected project directories and
  # portable coding-agent state is available from the host without placing
  # WAL-mode SQLite databases on virtiofs.
  imports = [ ./odin.nix ];

  # Muninn deliberately has no outbound SSH private key. Keep Odin's Git
  # defaults, but let public GitHub URLs remain HTTPS so bootstrap tools and
  # dependency managers do not require copied credentials or agent forwarding.
  programs.git.settings.url = lib.mkForce { };
}
