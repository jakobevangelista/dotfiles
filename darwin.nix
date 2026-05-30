{ ... }: {
  # Nix daemon is managed by Determinate — don't let nix-darwin conflict
  nix.enable = false;
  nixpkgs.config.allowUnfree = true;

  # Avoid building generated option manuals that currently emit upstream warnings.
  documentation.enable = false;

  # Homebrew — managed declaratively by nix-darwin
  # Listed packages are installed on rebuild; manually installed packages are left alone.
  # To add a new tool: add it below, then run `darwin-rebuild switch --flake ~/dotfiles`
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      cleanup = "none";
    };

    taps = [ "derailed/k9s" "hashicorp/tap" "stripe/stripe-cli" ];

    brews = [
      "act"
      "aws-vault"
      "awscli"
      "bat"
      "cmake"
      "curl"
      "direnv"
      "eza"
      "fzf"
      "git"
      "gh"
      "go"
      "golangci-lint"
      "hashicorp/tap/terraform"
      "helm"
      "derailed/k9s/k9s"
      "kind"
      "ninja"
      "neovim"
      "parallel"
      "pnpm"
      "protobuf"
      "ripgrep"
      "starship"
      "stripe/stripe-cli/stripe"
      "terragrunt"
      "tmux"
      "tree-sitter-cli"
      "zoxide"
    ];

    casks = [
      "claude-code@latest"
      "codex"
      "ghostty"
      "ngrok"
      "notion"
      "orbstack"
      "syncthing-app"
      "zoom"
    ];
  };

  # macOS system defaults (uncomment to customize)
  # system.defaults = {
  #   dock.autohide = true;
  #   finder.AppleShowAllExtensions = true;
  #   NSGlobalDomain.AppleShowAllExtensions = true;
  # };

  # User definition — required for home-manager integration
  users.users.jakobevangelista = {
    name = "jakobevangelista";
    home = "/Users/jakobevangelista";
  };

  # Required for nix-darwin
  system.primaryUser = "jakobevangelista";
  system.stateVersion = 6;
}
