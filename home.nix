{ pkgs, ... }:

let homeDir = "/Users/jakobevangelista";
in {
  home = {
    username = "jakobevangelista";
    homeDirectory = homeDir;
    stateVersion = "25.05";

    sessionPath = [
      "${homeDir}/bin"

      # Prefer Homebrew-owned CLI tools; keep the Nix profile available for HM helpers.
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"
      "/etc/profiles/per-user/jakobevangelista/bin"

      "${homeDir}/.cargo/bin"
      "${homeDir}/.pnpm"
      "${homeDir}/.bun/bin"
      "${homeDir}/go/bin"
      "${homeDir}/.opencode/bin"
      "${homeDir}/.krew/bin"

      # Keep vite-plus late so stale versioned Node shims do not shadow Nix/Homebrew.
      "${homeDir}/.vite-plus/bin"
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
      ".config/bat/config".text = ''
        --theme=base16
      '';
      ".config/direnv/lib/hm-nix-direnv.sh".source = "${pkgs.nix-direnv}/share/nix-direnv/direnvrc";
      ".config/opencode/opencode.jsonc" = {
        source = ./.config/opencode/opencode.jsonc;
        force = true;
      };
      ".config/opencode/tui.json" = {
        source = ./.config/opencode/tui.json;
        force = true;
      };
      ".config/starship.toml".source = ./.config/starship.toml;

      # Scripts
      "bin/tmux-sessionizer" = {
        source = ./.config/tmux/scripts/tmux-sessionizer;
        executable = true;
      };

      "bin/opencode" = {
        text = ''
          #!/usr/bin/env sh

          case "$PWD" in
            "$HOME/personal"|"$HOME/personal"/*)
              if [ -z "$OPENCODE_PERMISSION" ]; then
                export OPENCODE_PERMISSION='{"bash":"allow","edit":"allow","external_directory":"allow"}'
              fi
              ;;
          esac

          exec "$HOME/.opencode/bin/opencode" "$@"
        '';
        executable = true;
      };
    };
  };

  programs = {
    home-manager.enable = true;

    git = {
      enable = true;
      package = null;
      settings = {
        user = {
          name = "jakobevangelista";
          email = "jakobevangelista@gmail.com";
        };

        init.defaultBranch = "master";
        pull.rebase = true;

        # Rewrite HTTPS GitHub URLs to SSH so you never get password prompts
        url."git@github.com:".insteadOf = "https://github.com/";
      };
    };

    # eza — modern ls replacement with git integration and colors
    eza = {
      enable = true;
      package = null;
      enableZshIntegration = true; # aliases ls, ll, la, lt, lla
      git = true;
      icons = "auto";
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
        mkproj = "~/dotfiles/scripts/make_video_project.sh";
        backupSdCard = "~/dotfiles/scripts/backup_sd_videos.sh";
        ingestFootage = "~/dotfiles/scripts/ingest_footage.sh";
        backupProject = "~/dotfiles/scripts/backup_project.sh";
        restoreProjectMedia = "~/dotfiles/scripts/restore_project_media.sh";
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
        oc = "ANTHROPIC_API_KEY=dummy ANTHROPIC_BASE_URL=http://100.125.253.7:3456 opencode";
      };

      initContent = ''
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

        # Homebrew-managed shell integrations
        if command -v direnv >/dev/null 2>&1; then
          eval "$(direnv hook zsh)"
        fi

        [ -r /opt/homebrew/opt/fzf/shell/completion.zsh ] && source /opt/homebrew/opt/fzf/shell/completion.zsh
        [ -r /opt/homebrew/opt/fzf/shell/key-bindings.zsh ] && source /opt/homebrew/opt/fzf/shell/key-bindings.zsh

        if command -v zoxide >/dev/null 2>&1; then
          eval "$(zoxide init zsh)"
        fi

        if command -v starship >/dev/null 2>&1; then
          eval "$(starship init zsh)"
        fi
      '';
    };
  };

  manual.manpages.enable = false;
}
