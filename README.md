# Jakob's Dotfiles

Personal macOS and NixOS configuration managed with [nix-darwin](https://github.com/LnL7/nix-darwin), NixOS flakes, and [Home Manager](https://github.com/nix-community/home-manager).

## What's Managed

**System (nix-darwin / `darwin.nix`):**
- Required Homebrew formulae, casks, and taps; additional manual installs are left alone
- Rectangle shortcuts plus non-sensitive Raycast preferences

**User (Home Manager / `home.nix`):**
- Zsh (plugins, aliases, completions, history)
- Neovim
- Starship prompt
- Direnv + nix-direnv
- Git
- Tmux config
- Ghostty config
- Karabiner-Elements profile and complex-modification rule

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

Install Apple's Command Line Tools (`xcode-select --install`) and
[Homebrew](https://brew.sh/) first. On Apple Silicon, Homebrew must be available at
`/opt/homebrew/bin/brew`; this configuration manages its packages, not its installation.

Install Nix via the [Determinate installer](https://github.com/DeterminateSystems/nix-installer):

```bash
curl -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate
```

Open a new terminal afterward. `nix.enable = false` lets Determinate manage the daemon.

Homebrew 6 requires explicit trust for third-party formulae. After reviewing these
three vendors' formulae, authorize the packages used by this configuration:

```bash
brew trust --formula hashicorp/tap/terraform derailed/k9s/k9s stripe/stripe-cli/stripe
```

### Choose the Mac

The computer name and account short name are separate settings. These targets use
the existing accounts; rebuilding does not rename an account or move its home.

| Flake target | Account / home | Host additions |
| --- | --- | --- |
| `jakobs-goated-inngest-macbook` | `jakobevangelista` / `/Users/jakobevangelista` | Original Mac configuration |
| `jakob-temp-macbook-pro` | `jakobtest` / `/Users/jakobtest` | 1Password SSH agent and CLI, Geist Mono Nerd Font, Node 24, OpenCode; preserves standalone Codex in `~/.local/bin` |

### SSH with 1Password (new Mac)

Install and sign in to 1Password, then enable **Settings > Developer > Use the SSH
Agent**. On the old Mac, import an existing private key using **New Item > SSH Key >
Add Private Key > Import a Key File**. Importing the same key preserves its existing
GitHub/server authorizations. Alternatively, generate an Ed25519 key in 1Password
and add its **public** key to [GitHub](https://github.com/settings/keys) and any servers.
Private keys stay outside this repository.

The new Mac target writes `~/.ssh/config` with 1Password's agent socket. After
activation, run `ssh -T git@github.com` and approve the 1Password prompt. Successful
GitHub authentication prints a greeting and exits with status 1 (there is no shell).
See the [1Password SSH guide](https://www.1password.dev/ssh/get-started).

If 1Password has already generated `~/.ssh/config`, preserve it as a backup before
the first switch so Home Manager can take ownership of that path.

Tailscale needs a separate sign-in and macOS network-extension approval. Joining
the tailnet provides connectivity; servers still need to authorize your SSH key.

### Clone and Bootstrap

```bash
git clone https://github.com/jakobevangelista/dotfiles.git ~/dotfiles
cd ~/dotfiles
host=jakob-temp-macbook-pro  # Use the matching target from the table above.
nix build --no-update-lock-file "path:$PWD#darwinConfigurations.${host}.system"
sudo ./result/sw/bin/darwin-rebuild switch --flake "path:$PWD#$host"
```

The first command builds the pinned configuration before the privileged switch
installs packages and activates system/user settings. Keep `flake.lock` unchanged
for a first install. The `path:` form also includes newly added local host files.
After activation, open a new terminal. Git rewrites HTTPS GitHub URLs to SSH, so
finish SSH authentication before installing editor plugins or cloning projects.

If the first activation reports an unexpected `/etc/zshenv`, inspect it. The
Determinate installer may have created a Nix-only initialization snippet. Preserve
that file as `/etc/zshenv.before-nix-darwin` before retrying; do not overwrite an
existing backup or discard unrelated settings.

Tmux's config uses TPM if present. Install it once, then install the declared plugins
with **prefix + I** (the prefix is **Ctrl-a**):

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

Neovim installs its plugins on first launch. Its writable Lazy lockfile lives at
`~/.local/state/nvim/lazy-lock.json`, initially seeded from the repository's tracked
lockfile because the managed config is read-only. After intentional plugin updates,
copy that state lockfile back to `.config/nvim/lazy-lock.json` to record the new pins.
On an existing machine, use `:Lazy restore` after copying updated repository pins
to the state lockfile when you want to adopt those exact versions.

Project-specific runtimes, `~/.env` secrets, AI-tool sign-ins, and remote services
are separate setup steps. The `oc` alias expects the existing tailnet proxy at
`100.125.253.7:3456` to be reachable.

## Odin NixOS Server

The Odin host is built from the `#odin` flake output. The installer clone under `/mnt/etc/dotfiles` is only for install; after reboot, manage the repo from `~/dotfiles`.

> **Critical concept — `hardware-configuration.nix` is per-machine and MUST be committed.**
> This file is generated by `nixos-generate-config` and describes this specific machine: the kernel modules needed in the initrd, plus the root/boot filesystem UUIDs. A dirty local installer checkout can work once, but a clean clone only has committed content. If the generated hardware config is copied but never committed, a future rebuild from a fresh clone will fall back to the placeholder stub, produce an initrd with the wrong disk drivers, and the machine can drop to an emergency shell on the next boot, for example while waiting for `/dev/disk/by-label/nixos`.
> **Always `git add && git commit` the hardware config before rebuilding.**

### Fresh Install

Boot the NixOS installer, become root, and **confirm the target disk**. The device name depends on the disk bus:

- **NVMe**: `/dev/nvme0n1`, partitions `nvme0n1p1`/`nvme0n1p2` (note the `p`)
- **SATA/AHCI**: `/dev/sda`, partitions `sda1`/`sda2`
- **virtio VM**: `/dev/vda`, partitions `vda1`/`vda2`

```bash
sudo -i
lsblk -f                       # identify the real target device
ls /sys/firmware/efi/efivars   # must exist (confirms UEFI boot)
```

Choose one partitioning path below. The examples assume `/dev/nvme0n1`; **substitute your actual device everywhere**.

#### Option A: Wipe the Whole Disk

Use this only for a fresh disk or when you intentionally want to erase the full drive. `mklabel gpt` replaces the partition table.

```bash
parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 512MiB
parted /dev/nvme0n1 -- set 1 esp on
parted /dev/nvme0n1 -- mkpart primary ext4 512MiB 100%

mkfs.fat -F 32 -n BOOT /dev/nvme0n1p1
mkfs.ext4 -L nixos /dev/nvme0n1p2

mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/BOOT /mnt/boot
```

#### Option B: Use Existing Unallocated Space

Use this when the disk already has partitions you want to keep. **Do not run `mklabel gpt`**, and do not run `mkfs.*` on existing partitions.

First inspect the disk and find the free range you want to use:

```bash
lsblk -f
parted /dev/nvme0n1 -- print free
```

In the `Free Space` row, use the `Start` value as the start of the new partitions. Use the `End` value as the end, or `100%` only if that free space reaches the end of the disk. You can also choose a smaller end value if you only want to use part of the free space.

Create a dedicated 512 MiB Odin ESP at the start of the free range, then create root after it. This avoids depending on a tiny existing Windows ESP. For example, if free space starts at `200GiB`:

```bash
parted /dev/nvme0n1 -- mkpart ESP fat32 200GiB 200.5GiB
parted /dev/nvme0n1 -- print     # identify the new ESP partition number
parted /dev/nvme0n1 -- set X esp on
parted /dev/nvme0n1 -- mkpart primary ext4 200.5GiB 100%
lsblk -f                       # identify the new ESP/root partition numbers

mkfs.fat -F 32 -n BOOT /dev/nvme0n1pX
mkfs.ext4 -L nixos /dev/nvme0n1pY

mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/BOOT /mnt/boot
```

If you intentionally reuse an existing sufficiently large ESP, skip creating/formatting the `BOOT` partition and mount the existing ESP at `/mnt/boot` instead.

`primary` is just the partition name/type passed to `parted`; the important values are the `Start` and `End` boundaries. Always confirm the new partition names with `lsblk -f` before formatting.

Generate the hardware config, clone this repo, copy the generated hardware config into the Odin host, **and commit it** so the flake actually uses it instead of the stub:

```bash
nixos-generate-config --root /mnt
git clone https://github.com/jakobevangelista/dotfiles.git /mnt/etc/dotfiles
cp /mnt/etc/nixos/hardware-configuration.nix \
   /mnt/etc/dotfiles/hosts/nixos/odin/hardware-configuration.nix

git -C /mnt/etc/dotfiles add hosts/nixos/odin/hardware-configuration.nix
git -C /mnt/etc/dotfiles \
    -c user.email=jakobevangelista@gmail.com -c user.name="Jakob Evangelista" \
    commit -m "odin: machine-specific hardware-configuration.nix"
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

Log in as `jakob`. The generated hardware config persists at `/etc/nixos/hardware-configuration.nix` on the installed system. Clone the repo into your home directory, re-copy and commit that hardware config, then rebuild:

```bash
git clone https://github.com/jakobevangelista/dotfiles.git ~/dotfiles

# A fresh clone may only contain the placeholder stub. Restore this machine's
# generated hardware config before the first rebuild from ~/dotfiles.
cp /etc/nixos/hardware-configuration.nix ~/dotfiles/hosts/nixos/odin/hardware-configuration.nix
git -C ~/dotfiles add hosts/nixos/odin/hardware-configuration.nix
git -C ~/dotfiles commit -m "odin: hardware-configuration.nix for this machine"

sudo nixos-rebuild switch --flake ~/dotfiles#odin
exec zsh -l
```

Because `#odin` represents this one server, push the hardware config commit once it matches the real target machine. If Odin moves to different hardware, regenerate it with `nixos-generate-config`, re-copy it into `hosts/nixos/odin/hardware-configuration.nix`, and commit the replacement before rebuilding.

### Finding Odin's IP & Connecting via SSH

SSH is enabled by the config (`services.openssh.enable = true`), so `sshd` starts automatically once Odin reaches a normal boot. You just need its IP address.

From Odin itself, using the physical console or VM console:

```bash
hostname -I                 # prints all IP addresses
ip -4 addr show             # full per-interface detail, look for the 'inet' line
ip route get 1.1.1.1        # shows the source IP used for outbound traffic
```

From your network or router, check the router's DHCP lease or connected devices list for the host named `odin`, or for the machine's MAC address.

If Odin runs as an Unraid/KVM VM, from the Unraid host shell:

```bash
# Best when the QEMU guest agent is enabled in the guest:
virsh domifaddr Linux

# Works without the guest agent by reading host ARP/DHCP lease tables:
virsh domifaddr Linux --source arp
virsh domifaddr Linux --source lease

# Or look it up by MAC address from the libvirt XML:
arp -an | grep -i <vm-mac-address>
```

The Unraid web UI's **VMs** tab also displays the guest IP. For `virsh domifaddr Linux` without `--source`, and for reliable IP reporting in the UI, enable the guest agent by adding `services.qemuGuest.enable = true;` to `hosts/nixos/odin/default.nix` and rebuilding.

Then connect:

```bash
ssh jakob@<odin-ip>
```

For a stable address, set a DHCP reservation on your router, or configure a static IP in NixOS. If your network resolves hostnames through router DNS or mDNS/Avahi, you may also be able to use `ssh jakob@odin` or `ssh jakob@odin.local`.

### Secrets

API keys are stored in `~/.env` (not tracked in git). This file is sourced automatically by zsh on startup.

## Updating

After pulling or editing macOS configuration, rebuild with the target matching
that Mac's account from the table above:

```bash
host=jakob-temp-macbook-pro  # On the original Mac: jakobs-goated-inngest-macbook
sudo darwin-rebuild switch --flake "path:$HOME/dotfiles#$host"
```

This rebuilds everything: system packages, Homebrew, shell config, and dotfile symlinks.
Shared changes apply to either Mac on its next rebuild. Settings in
`hosts/darwin/jakob-temp-macbook-pro.nix` apply only to the new Mac target.

Karabiner's entire `~/.config/karabiner` directory is linked to the tracked
directory because Karabiner does not support linking `karabiner.json` by itself.
On the first rebuild after adopting this layout, the previous directory and its
automatic backups are retained at `~/.config/karabiner.before-home-manager`.

Raycast's launcher hotkey, window mode, appearance, icon choice, Notes format
bar, and Screenshots search preference are declared in `darwin.nix`. Raycast's
extensions, quicklinks, snippets, notes, and credentials live in its encrypted
data store and must be restored with Raycast's encrypted Settings & Data export
or Cloud Sync rather than committed to this repository.

After editing any Odin `.nix` file:

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#odin
```

### Updating Odin AI CLI Packages

Claude Code, Codex, Grok, and OpenCode are locally pinned for Odin so they
can track upstream releases without waiting for nixpkgs. To update all four with the
flake-provided updater app and verify that each changed package builds:

```bash
nix run .#update-ai-tools
```

Compatibility wrappers are also available under `scripts/`, so this is
equivalent:

```bash
scripts/update-ai-tools.sh
```

The individual updater apps are available when you need to update or rebuild one
package:

```bash
nix run .#update-claude-code -- [latest|VERSION] [--force]
nix run .#update-codex -- [latest|VERSION] [--force]
nix run .#update-grok -- [latest|VERSION] [--force]
nix run .#update-opencode -- [latest|VERSION] [--force]
```

After committing/pushing the updated pins, apply them on Odin:

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#odin
```

### Adding a Homebrew package

Add it to `darwin.nix` under `brews` (formulae) or `casks` (GUI apps), then rebuild:

```bash
# Edit darwin.nix, then:
host=jakob-temp-macbook-pro  # On the original Mac: jakobs-goated-inngest-macbook
sudo darwin-rebuild switch --flake "path:$HOME/dotfiles#$host"
```

`cleanup = "none"` preserves packages installed outside this configuration. Add
machine-specific packages in `hosts/darwin/` and shared Mac packages in `darwin.nix`.

## Rollback

```bash
# List previous generations
darwin-rebuild --list-generations

# Roll back to a specific generation
sudo darwin-rebuild switch --switch-generation <number>
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
