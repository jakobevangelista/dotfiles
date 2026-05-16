# Agent Guide

This repo manages Jakob's dotfiles across macOS and NixOS.

## What This Repo Does

- `flake.nix` wires the macOS and NixOS hosts.
- `darwin.nix` manages macOS system settings and Homebrew packages through nix-darwin.
- `home.nix` manages the macOS user environment through Home Manager.
- `hosts/nixos/odin/` contains the NixOS system config for the Odin server.
- `homes/odin.nix` contains Odin's Home Manager config.
- `modules/home/shared-dotfiles.nix` shares user config between macOS and Odin.
- `.config/` contains app configs for Neovim, tmux, Ghostty, OpenCode, and Starship.

## Important Context

- macOS intentionally uses Homebrew for many CLI tools and apps.
- Odin intentionally uses Nix packages through Home Manager/NixOS.
- Neovim, tmux, OpenCode, Starship, and `tmux-sessionizer` are shared between hosts.
- Ghostty is macOS-only.
- Do not remove generated hardware config from `hosts/nixos/odin/hardware-configuration.nix` unless replacing it with a freshly generated one from Odin.

## Safe Workflow

- Prefer small, targeted changes over large rewrites.
- Do not run destructive Git commands unless explicitly requested.
- Do not commit unless explicitly requested.
- Check the current worktree before editing with `git status --short`.
- Validate Nix changes when practical with `nix flake check path:/Users/jakobevangelista/dotfiles`.
- Validate macOS builds with `darwin-rebuild build --flake path:/Users/jakobevangelista/dotfiles#jakobs-goated-inngest-macbook`.
- Validate Odin changes on Odin with `sudo nixos-rebuild switch --flake ~/dotfiles#odin`.

## Agent Usage Tips

- Tell the agent which host you are changing: macOS, Odin, or shared.
- Mention whether you want implementation, diagnosis, or just a plan.
- For Nix changes, say whether the tool should update `flake.lock`.
- For package changes, say whether the package should be Homebrew-managed on macOS or Nix-managed on Odin.
- For shared app config, ask the agent to preserve behavior on both hosts unless you explicitly want host-specific behavior.
- If something broke, paste the exact command and error output.
