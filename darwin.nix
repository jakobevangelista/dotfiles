{ pkgs, ... }: {
  # Nix daemon is managed by Determinate — don't let nix-darwin conflict
  nix.enable = false;
  nixpkgs.config.allowUnfree = true;

  # System packages installed via Nix (not Homebrew)
  environment.systemPackages = with pkgs;
    [
      # Add system-level nix packages here if needed
    ];

  # Homebrew — managed declaratively by nix-darwin
  # Anything not listed here gets removed on rebuild (cleanup = "zap")
  # To add a new tool: add it below, then run `darwin-rebuild switch --flake ~/dotfiles`
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
    };

    taps = [ "derailed/k9s" "hashicorp/tap" "stripe/stripe-cli" ];

    brews = [
      "act"
      "aws-vault"
      "awscli"
      "cmake"
      "curl"
      "fzf"
      "gh"
      "go"
      "golangci-lint"
      "hashicorp/tap/terraform"
      "derailed/k9s/k9s"
      "ninja"
      "parallel"
      "pnpm"
      "protobuf"
      "ripgrep"
      "stripe/stripe-cli/stripe"
      "terragrunt"
      "tmux"
    ];

    casks = [ "ghostty" "ngrok" "notion" "orbstack" "syncthing" "zoom" ];
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
