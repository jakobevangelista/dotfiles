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
      "1password"
      "chatgpt"
      "claude-code@latest"
      "codex"
      "ghostty"
      "google-chrome"
      "karabiner-elements"
      "ngrok"
      "notion"
      "obs"
      "orbstack"
      "raycast"
      "rectangle"
      "slack"
      "syncthing-app"
      "tableplus"
      "tailscale-app"
      "zoom"
    ];
  };

  # Preserve Rectangle's useful behavior and shortcuts. Version, launch-history,
  # and menu-bar-position values are intentionally omitted as transient state.
  system.defaults.CustomUserPreferences."com.knollsoft.Rectangle" = {
    SUEnableAutomaticChecks = false;
    allowAnyShortcut = true;
    alternateDefaultShortcuts = true;
    subsequentExecutionMode = 1;

    leftHalf = {
      keyCode = 4;
      modifierFlags = 786432;
    };
    rightHalf = {
      keyCode = 37;
      modifierFlags = 786432;
    };
    nextDisplay = {
      keyCode = 37;
      modifierFlags = 1835008;
    };
    previousDisplay = {
      keyCode = 4;
      modifierFlags = 1835008;
    };
    reflowTodo = {
      keyCode = 45;
      modifierFlags = 786432;
    };
    toggleTodo = {
      keyCode = 11;
      modifierFlags = 786432;
    };
  };

  # Preserve non-sensitive Raycast preferences. Extensions, quicklinks,
  # snippets, notes, and credentials remain in Raycast's encrypted data store
  # and should be restored with Raycast's encrypted export or Cloud Sync.
  system.defaults.CustomUserPreferences."com.raycast.macos" = {
    raycastGlobalHotkey = "Command-49";
    raycastPreferredWindowMode = "default";
    raycastShouldFollowSystemAppearance = true;
    useHyperKeyIcon = false;
    floatingNotes_raycastNotesFormatBarVisible = false;
    screenshots_dataSourceEnabled = true;
  };

  # User definition — required for home-manager integration
  users.users.jakobevangelista = {
    name = "jakobevangelista";
    home = "/Users/jakobevangelista";
  };

  # Required for nix-darwin
  system.primaryUser = "jakobevangelista";
  system.stateVersion = 6;
}
