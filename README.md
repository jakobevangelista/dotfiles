# Jakob's Dotfiles

Personal configuration managed with Nix Home Manager (Phase 1).

## What's This?

This repo contains my dotfiles, now with Nix for reproducibility. Currently in **Phase 1**: Home Manager only, Homebrew still active.

## Setup

### First Time Installation

**Prerequisites**: Nix should already be installed. If not:
```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

### Apply Home Manager Configuration

```bash
cd ~/dotfiles
nix run home-manager/master -- switch --flake .#jakobevangelista
```

### Secrets Setup

API keys are stored in `~/.env` (not tracked in git). This file is sourced by `.zshrc`.

## Updating Configuration

After making changes to `home.nix` or `flake.nix`:
```bash
home-manager switch --flake ~/dotfiles#jakobevangelista
```

## Structure

- `flake.nix` - Nix flake entry point
- `home.nix` - Home Manager configuration
- `.config/` - Application configurations (nvim, tmux, ghostty)
- `.zshrc` - Shell configuration (using oh-my-zsh)
- `.env` - Secrets (not in git)

## Rollback

If something breaks:

**Rollback to previous Home Manager generation:**
```bash
home-manager generations  # List previous generations
home-manager switch --switch-generation <number>
```

**Or restore your old setup:**
```bash
cp ~/.zshrc.backup ~/.zshrc
source ~/.zshrc
```

## Old Setup (pre-Nix)

### Requirements
- git
- build neovim from source
- gnu stow
- ripgrep
- tmux

### Download
- download all the zsh plugins
- download and install tpm first
- <prefix>+I (prefix + capital i) to install tmux stuff within tmux
- install nerdfont for tmux

```zsh
git clone https://github.com/jakobevangelista/dotfiles.git
cd dotfiles
stow .
```

## Phase 2 (Coming Soon)

- Add nix-darwin for system configuration
- Manage Homebrew declaratively via Nix
