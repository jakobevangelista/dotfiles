# Jakob's Dotfiles

Personal macOS and NixOS configuration managed with [nix-darwin](https://github.com/LnL7/nix-darwin), NixOS flakes, and [Home Manager](https://github.com/nix-community/home-manager).

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

**Shared Linux/macOS dotfiles (`modules/home/shared-dotfiles.nix`):**
- Neovim
- Tmux
- OpenCode
- Starship
- `tmux-sessionizer`

**NixOS hosts (`hosts/nixos/*`):**
- `odin` server scaffold
- Host system config
- Generated hardware config per machine

## Setup

### Prerequisites

Install Nix via the [Determinate installer](https://github.com/DeterminateSystems/nix-installer):

```bash
curl -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate
```

### SSH Key

Generate a key and add it to [GitHub](https://github.com/settings/keys):

```bash
ssh-keygen -t ed25519 -C "jakobevangelista@gmail.com"
pbcopy < ~/.ssh/id_ed25519.pub
```

Until the first rebuild, `~/.ssh/config` doesn't exist yet. Create it manually:

```bash
mkdir -p ~/.ssh && cat <<'EOF' > ~/.ssh/config
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519
EOF
chmod 600 ~/.ssh/config
```

### Clone and Bootstrap

```bash
git clone git@github.com:jakobevangelista/dotfiles.git ~/dotfiles
cd ~/dotfiles
nix run nix-darwin/master#darwin-rebuild -- switch --flake .
```

The bootstrap command installs nix-darwin and applies the full configuration (system + user). This only needs to be run once. After rebuild, git is configured to rewrite all HTTPS GitHub URLs to SSH automatically.

## Odin NixOS Server

The Odin host is built from the `#odin` flake output. The installer clone under `/mnt/etc/dotfiles` is only for install; after reboot, manage the repo from `~/dotfiles`.

### Fresh Install

Boot the NixOS installer, become root, and confirm the target disk. These partition commands wipe `/dev/vda`.

```bash
sudo -i
lsblk -f
ls /sys/firmware/efi/efivars
```

Create a simple UEFI layout:

```bash
parted /dev/vda -- mklabel gpt
parted /dev/vda -- mkpart ESP fat32 1MiB 512MiB
parted /dev/vda -- set 1 esp on
parted /dev/vda -- mkpart primary ext4 512MiB 100%

mkfs.fat -F 32 -n BOOT /dev/vda1
mkfs.ext4 -L nixos /dev/vda2

mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/BOOT /mnt/boot
```

Generate hardware config, clone this repo, and copy the generated hardware config into the Odin host:

```bash
nixos-generate-config --root /mnt
git clone https://github.com/jakobevangelista/dotfiles.git /mnt/etc/dotfiles
cp /mnt/etc/nixos/hardware-configuration.nix /mnt/etc/dotfiles/hosts/nixos/odin/hardware-configuration.nix
```

Enable flakes in the installer shell and install:

```bash
mkdir -p ~/.config/nix
printf 'experimental-features = nix-command flakes\n' > ~/.config/nix/nix.conf

nixos-install --flake /mnt/etc/dotfiles#odin
nixos-enter --root /mnt -c 'passwd jakob'
reboot
```

### After Reboot

Log in as `jakob`, clone the repo into your home directory, and rebuild from there going forward:

```bash
git clone https://github.com/jakobevangelista/dotfiles.git ~/dotfiles
sudo nixos-rebuild switch --flake ~/dotfiles#odin
exec zsh -l
```

### Secrets

API keys are stored in `~/.env` (not tracked in git). This file is sourced automatically by zsh on startup.

## Updating

After editing any macOS `.nix` file:

```bash
darwin-rebuild switch --flake ~/dotfiles
```

This rebuilds everything: system packages, Homebrew, shell config, and dotfile symlinks.

After editing any Odin `.nix` file:

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#odin
```

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
homes/       - Host-specific Home Manager configs
hosts/       - Host-specific system configs
modules/     - Shared Nix/Home Manager modules
.config/     - App configs (nvim, tmux, ghostty)
scripts/     - Utility scripts
.env         - Secrets (not in git)
```
