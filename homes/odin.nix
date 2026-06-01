{ lib, pkgs, ... }:

let
  username = "jakob";
  homeDir = "/home/${username}";
  odinStarshipConfig = builtins.replaceStrings
    [ ''format = "$directory'' ]
    [ ''format = "$username$hostname$directory'' ]
    (builtins.readFile ../.config/starship.toml) + ''

    [username]
    format = "[$user]($style)"
    style_user = "bold cyan"
    style_root = "bold red"
    show_always = true

    [hostname]
    format = "[@$hostname]($style) "
    style = "bold cyan"
    ssh_only = false
  '';
  odinOpencodeTuiConfig = lib.recursiveUpdate
    (builtins.fromJSON (builtins.readFile ../.config/opencode/tui.json))
    (builtins.fromJSON (builtins.readFile ../.config/opencode/hosts/odin-tui.json));
in {
  imports = [ ../modules/home/shared-dotfiles.nix ];

  home = {
    inherit username;
    homeDirectory = homeDir;
    stateVersion = "25.05";

    packages = with pkgs; [
      bat
      codex
      fd
      gcc
      go
      ghostty.terminfo
      jq
      neovim
      opencode
      ripgrep
      tmux
      tree-sitter
      unzip
      wget
    ];

    sessionPath = [
      "${homeDir}/bin"
      "${homeDir}/.local/bin"
      "${homeDir}/.cargo/bin"
      "${homeDir}/.pnpm"
      "${homeDir}/.bun/bin"
      "${homeDir}/go/bin"
      "${homeDir}/.opencode/bin"
    ];

    sessionVariables = {
      EDITOR = "nvim";
      PAGER = "less";
      LESS = "-R";
      PY_COLORS = "1";
      PNPM_HOME = "${homeDir}/.pnpm";
      BUN_INSTALL = "${homeDir}/.bun";
      NVM_DIR = "${homeDir}/.nvm";
    };

    file = {
      ".config/bat/config".text = ''
        --theme=base16
      '';

      ".config/starship.toml" = lib.mkForce { text = odinStarshipConfig; };
      ".config/opencode/tui.json" =
        lib.mkForce { text = builtins.toJSON odinOpencodeTuiConfig + "\n"; };
    };
  };

  programs = {
    home-manager.enable = true;

    git = {
      enable = true;
      settings = {
        user = {
          name = "jakobevangelista";
          email = "jakobevangelista@gmail.com";
        };

        init.defaultBranch = "master";
        pull.rebase = true;
        url."git@github.com:".insteadOf = "https://github.com/";
      };
    };

    eza = {
      enable = true;
      enableZshIntegration = true;
      git = true;
      icons = "auto";
    };

    direnv = {
      enable = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
    };

    fzf = {
      enable = true;
      enableZshIntegration = true;
    };

    starship = {
      enable = true;
      enableZshIntegration = true;
    };

    zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;

      history = {
        path = "${homeDir}/.zsh_history";
        size = 50000;
        save = 10000;
        extended = true;
        ignoreDups = true;
        ignoreSpace = true;
        expireDuplicatesFirst = true;
        share = true;
      };

      plugins = [{
        name = "zsh-history-substring-search";
        src = pkgs.zsh-history-substring-search;
        file =
          "share/zsh-history-substring-search/zsh-history-substring-search.zsh";
      }];

      shellAliases = {
        vim = "nvim";
        md = "mkdir -p";
        "..." = "cd ../..";
        "...." = "cd ../../..";
        "....." = "cd ../../../..";

        gst = "git status";
        gss = "git status --short";
        gco = "git checkout";
        gsw = "git switch";
        gswc = "git switch --create";
        ga = "git add";
        gaa = "git add --all";
        gcmsg = "git commit --message";
        gcam = "git commit --all --message";
        gd = "git diff";
        gds = "git diff --staged";
        gcb = "git checkout -b";
        gb = "git branch";
        gbd = "git branch --delete";
        gl = "git pull";
        gp = "git push";
        gf = "git fetch";
        glog = "git log --oneline --decorate --graph";
        gsta = "git stash push";
        gstp = "git stash pop";
        oc = "opencode";
      };

      initContent = ''
        setopt auto_cd auto_pushd pushd_ignore_dups pushdminus
        setopt auto_menu complete_in_word always_to_end
        setopt interactivecomments long_list_jobs multios prompt_subst
        unsetopt menu_complete flow_control

        zmodload -i zsh/complist
        WORDCHARS=""
        zstyle ':completion:*' menu select
        zstyle ':completion:*' matcher-list 'm:{[:lower:][:upper:]}={[:upper:][:lower:]}' 'r:|=*' 'l:|=* r:|=*'
        zstyle ':completion:*' special-dirs true
        zstyle ':completion:*' list-colors ""

        autoload -U up-line-or-beginning-search down-line-or-beginning-search edit-command-line
        zle -N up-line-or-beginning-search
        zle -N down-line-or-beginning-search
        zle -N edit-command-line
        bindkey '^[[A' up-line-or-beginning-search
        bindkey '^[[B' down-line-or-beginning-search
        bindkey '^[[1;5C' forward-word
        bindkey '^[[1;5D' backward-word
        bindkey '^[[3~' delete-char
        bindkey '^x^e' edit-command-line

        function _lazy_load_nvm() {
          unset -f nvm node npm npx
          [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
          [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        }
        function nvm() { _lazy_load_nvm; nvm "$@"; }
        function node() { _lazy_load_nvm; node "$@"; }
        function npm() { _lazy_load_nvm; npm "$@"; }
        function npx() { _lazy_load_nvm; npx "$@"; }

        [ -s "${homeDir}/.bun/_bun" ] && source "${homeDir}/.bun/_bun"
        [ -f "$HOME/.env" ] && source "$HOME/.env"
      '';
    };
  };

  manual.manpages.enable = false;
}
