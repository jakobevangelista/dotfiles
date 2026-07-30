{ lib, pkgs, ... }:

let
  goimports = pkgs.runCommand "goimports-${pkgs.gotools.version}" { } ''
    mkdir -p "$out/bin"
    ln -s "${pkgs.gotools}/bin/goimports" "$out/bin/goimports"
  '';
in
{
  programs.jujutsu = {
    enable = true;
    settings.user = {
      name = "jakobevangelista";
      email = "jakobevangelista@gmail.com";
    };
  };

  home.packages = with pkgs;
    [
      eslint_d
      gopls
      goimports
      lua-language-server
      marksman
      markdownlint-cli
      prettierd
      pyright
      stylua
      typescript-language-server
    ]
    ++ lib.optionals stdenv.isLinux [ golangci-lint ];

  home.file = {
    ".config/nvim".source = ../../.config/nvim;
    ".config/tmux".source = ../../.config/tmux;
    ".config/starship.toml".source = ../../.config/starship.toml;

    ".config/agents/skills" = {
      source = ../../.config/agents/skills;
      force = true;
    };

    ".codex/skills/testing-simcity-e2e" = {
      source = ../../.config/agents/skills/testing-simcity-e2e;
      force = true;
    };
    ".codex/skills/testing-simcity-staging-e2e" = {
      source = ../../.config/agents/skills/testing-simcity-staging-e2e;
      force = true;
    };
    ".codex/skills/testing-simcity-production-e2e" = {
      source = ../../.config/agents/skills/testing-simcity-production-e2e;
      force = true;
    };
    ".codex/skills/testing-monorepo-local-e2e" = {
      source = ../../.config/agents/skills/testing-monorepo-local-e2e;
      force = true;
    };

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
