# Jakob's Dotfiles

Personal macOS configuration managed with [nix-darwin](https://github.com/LnL7/nix-darwin) and [Home Manager](https://github.com/nix-community/home-manager).

## What's Managed

**System (nix-darwin / `darwin.nix`):**
- Homebrew formulae, casks, and taps (declarative — anything not listed gets removed)
- macOS system settings (optional, commented out by default)

**User (Home Manager / `home.nix`):**
- Zsh (plugins, aliases, completions, history)
- Neovim
- Starship prompt
- Direnv + nix-direnv
- Git
- Tmux config
- Ghostty config

## Setup

### Prerequisites

Install Nix via the [Determinate installer](https://github.com/DeterminateSystems/nix-installer):

```bash
curl -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate
```

### Clone and Bootstrap

```bash
git clone https://github.com/jakobevangelista/dotfiles ~/dotfiles
cd ~/dotfiles
nix run nix-darwin/master#darwin-rebuild -- switch --flake .
```

The bootstrap command installs nix-darwin and applies the full configuration (system + user). This only needs to be run once.

### Secrets

API keys are stored in `~/.env` (not tracked in git). This file is sourced automatically by zsh on startup.

## Updating

After editing any `.nix` file:

```bash
darwin-rebuild switch --flake ~/dotfiles
```

This rebuilds everything: system packages, Homebrew, shell config, and dotfile symlinks.

### Adding a Homebrew package

Add it to `darwin.nix` under `brews` (formulae) or `casks` (GUI apps), then rebuild:

```bash
# Edit darwin.nix, then:
darwin-rebuild switch --flake ~/dotfiles
```

**Note:** `cleanup = "zap"` is enabled. If you `brew install` something ad-hoc without adding it to `darwin.nix`, it will be removed on the next rebuild.

## Rollback

```bash
# List previous generations
darwin-rebuild --list-generations

# Roll back to a specific generation
darwin-rebuild switch --switch-generation <number>
```

## Structure

```
flake.nix    - Nix flake entry point (inputs + wiring)
darwin.nix   - nix-darwin config (Homebrew, system settings)
home.nix     - Home Manager config (zsh, aliases, plugins, packages, paths)
.config/     - App configs (nvim, tmux, ghostty)
scripts/     - Utility scripts
.env         - Secrets (not in git)
```
