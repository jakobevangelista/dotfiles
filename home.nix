{ pkgs, ... }:

let homeDir = "/Users/jakobevangelista";
in {
  home = {
    username = "jakobevangelista";
    homeDirectory = homeDir;
    stateVersion = "25.05";

    packages = with pkgs; [ neovim ];

    sessionPath = [
      "${homeDir}/bin"
      "${homeDir}/.cargo/bin"
      "${homeDir}/.pnpm"
      "${homeDir}/.bun/bin"
      "${homeDir}/go/bin"
      "${homeDir}/.opencode/bin"
      "${homeDir}/.krew/bin"
      "/opt/homebrew/bin"
      # Nix profile paths before /usr/bin — ensures nix-installed tools (git, etc.)
      # run directly instead of through Apple's xcrun shim, which breaks color output
      "/etc/profiles/per-user/jakobevangelista/bin"
    ];

    sessionVariables = {
      EDITOR = "nvim";

      # Python
      PY_COLORS = "1";

      # Node/pnpm
      PNPM_HOME = "${homeDir}/.pnpm";

      # Bun
      BUN_INSTALL = "${homeDir}/.bun";

      # NVM
      NVM_DIR = "${homeDir}/.nvm";

      # Pager
      PAGER = "less";
      LESS = "-R";
      LSCOLORS = "Gxfxcxdxbxegedabagacad";
    };

    file = {
      ".config/nvim".source = ./.config/nvim;
      ".config/tmux".source = ./.config/tmux;
      ".config/ghostty".source = ./.config/ghostty;
      ".config/starship.toml".source = ./.config/starship.toml;

      # .zshrc is now managed by programs.zsh — no manual symlink

      # OpenCode config
      ".config/opencode/opencode.jsonc".source = ./opencode.jsonc;

      # Scripts
      "bin/tmux-sessionizer" = {
        source = ./.config/tmux/scripts/tmux-sessionizer;
        executable = true;
      };
    };
  };

  programs = {
    home-manager.enable = true;

    # Direnv — managed by HM, hooks into zsh automatically
    direnv = {
      enable = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
    };

    git = {
      enable = true;
      userName = "jakobevangelista";
      userEmail = "jakobevangelista@gmail.com";
      extraConfig = {
        init.defaultBranch = "master";
        pull.rebase = true;
        # Rewrite HTTPS GitHub URLs to SSH so you never get password prompts
        url."git@github.com:".insteadOf = "https://github.com/";
      };
    };

    # fzf — fuzzy finder with shell integration
    # Ctrl+R = fuzzy history, Ctrl+T = fuzzy file finder, Alt+C = fuzzy cd
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };

    # zoxide — smarter cd that learns your most-used directories
    # Use: z <partial-name> to jump to frequently visited dirs
    zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    # eza — modern ls replacement with git integration and colors
    eza = {
      enable = true;
      enableZshIntegration = true; # aliases ls, ll, la, lt, lla
      git = true;
      icons = "auto";
    };

    # bat — modern cat with syntax highlighting
    bat = {
      enable = true;
      config.theme = "base16";
    };

    # Starship prompt — enableZshIntegration adds eval "$(starship init zsh)" automatically
    starship = {
      enable = true;
      enableZshIntegration = true;
    };

    # Zsh — managed by Home Manager, replaces oh-my-zsh
    zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;

      # Optimized compinit — only regenerate dump once per day
      completionInit = ''
        autoload -Uz compinit
        if [[ -n ''${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]; then
          compinit
        else
          compinit -C
        fi
      '';

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
        nviml = "NVIM_APPNAME=lazyvim nvim";
        mkproj = "~/make_video_project.sh";
        backupSdCard = "~/dotfiles/scripts/backup_sd_videos.sh";
        md = "mkdir -p";
        "..." = "cd ../..";
        "...." = "cd ../../..";
        "....." = "cd ../../../..";

        # Git aliases
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
      };

      initExtra = ''
        # Shell options (replicate useful OMZ defaults)
        setopt auto_cd auto_pushd pushd_ignore_dups pushdminus
        setopt auto_menu complete_in_word always_to_end
        setopt interactivecomments long_list_jobs multios prompt_subst
        unsetopt menu_complete flow_control

        # Completion styles
        zmodload -i zsh/complist
        WORDCHARS=""
        zstyle ':completion:*' menu select
        zstyle ':completion:*' matcher-list 'm:{[:lower:][:upper:]}={[:upper:][:lower:]}' 'r:|=*' 'l:|=* r:|=*'
        zstyle ':completion:*' special-dirs true
        zstyle ':completion:*' list-colors ""

        # Key bindings
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

        # git_main_branch helper (for aliases like gcm if added later)
        function git_main_branch() {
          command git rev-parse --git-dir &>/dev/null || return
          local ref
          for ref in refs/{heads,remotes/{origin,upstream}}/{main,trunk,mainline,default,stable,master}; do
            if command git show-ref -q --verify $ref; then
              echo ''${ref:t}
              return 0
            fi
          done
          echo master
        }

        # NVM (lazy-loaded — only sources nvm.sh on first use of nvm/node/npm/npx)
        function _lazy_load_nvm() {
          unset -f nvm node npm npx
          [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
          [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        }
        function nvm() { _lazy_load_nvm; nvm "$@"; }
        function node() { _lazy_load_nvm; node "$@"; }
        function npm() { _lazy_load_nvm; npm "$@"; }
        function npx() { _lazy_load_nvm; npx "$@"; }

        # Bun completions
        [ -s "${homeDir}/.bun/_bun" ] && source "${homeDir}/.bun/_bun"

        # Envman
        [ -s "$HOME/.config/envman/load.sh" ] && source "$HOME/.config/envman/load.sh"

        # Secrets
        [ -f "$HOME/.env" ] && source "$HOME/.env"
      '';
    };
  };
}
