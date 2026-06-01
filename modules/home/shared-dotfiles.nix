{ pkgs, ... }:

{
  programs.jujutsu = {
    enable = true;
    settings.user = {
      name = "jakobevangelista";
      email = "jakobevangelista@gmail.com";
    };
  };

  home.packages = with pkgs; [
    eslint_d
    gopls
    lua-language-server
    marksman
    markdownlint-cli
    prettierd
    pyright
    stylua
    typescript-language-server
  ];

  home.file = {
    ".config/nvim".source = ../../.config/nvim;
    ".config/tmux".source = ../../.config/tmux;
    ".config/starship.toml".source = ../../.config/starship.toml;

    ".config/opencode/opencode.jsonc" = {
      source = ../../.config/opencode/opencode.jsonc;
      force = true;
    };
    ".config/opencode/tui.json" = {
      source = ../../.config/opencode/tui.json;
      force = true;
    };

    "bin/tmux-sessionizer" = {
      source = ../../.config/tmux/scripts/tmux-sessionizer;
      executable = true;
    };
  };
}
