---
name: using-muninn
description: "Operate and troubleshoot Odin's persistent, resource-bounded Muninn Cloud Hypervisor workstation. Use for deployment, startup, SSH access, shutdown, shared-worktree use, resource inspection, storage preparation, or Muninn recovery; do not use for disposable Huginn or Simcity E2E guests."
---

# Use the Muninn Workstation

Operate Muninn from Odin with the installed `muninn` helper. Muninn is a
singleton persistent workstation with explicitly shared host worktrees and a
host-side resource boundary.

The canonical design and current first-start requirements are in
`/home/jakob/dotfiles/docs/muninn-workstation.md`. The guest and host source of
truth are `/home/jakob/dotfiles/hosts/muninn/default.nix` and
`/home/jakob/dotfiles/hosts/nixos/odin/muninn-vm.nix`. Read them before storage
changes, first deployment, or recovery that goes beyond the commands here.

## Understand the boundary

Muninn currently has 20 GiB guest RAM and 12 vCPUs. Cloud Hypervisor and its
nine `virtiofsd` helpers run in `muninn.slice`, with `MemoryHigh=21G`,
`MemoryMax=23G`, CPU affinity that leaves two physical cores to Odin, and
systemd-oomd monitoring. Odin and the guest also have zram.

The guest has no access to Odin's physical NIC, host network namespace, Docker
socket, BPF filesystem, raw host root, or general device tree. Do not weaken
those exclusions to make a workload convenient.

Muninn combines private state with live shares:

- Persistent private state: the non-shared parts of `/home/jakob`,
  `/nix/var/nix`, the writable Nix store overlay, `/var/lib/docker`, and the SSH
  host key.
- Live Odin worktrees: `/home/jakob/inngest-work`, `/home/jakob/personal`, and
  `/home/jakob/dotfiles` at the same guest paths.
- Portable Codex transcripts plus selected config/auth files are shared;
  Codex SQLite databases remain private to each machine.
- Claude and Amp state are live shares.
- OpenCode state is private and can be imported once from Odin with `muninn
  import-opencode` after closing OpenCode on both systems.

The live directories are not copies or overlays. Guest changes immediately
change Odin's files. Guest UIDs are squashed to host user `jakob`, which blocks
host-root ownership but does not prevent deletion or corruption of the shared
files. Inspect version-control state before risky edits and do not treat a VM
reset as a rollback for shared worktrees.

The agent-state mounts make Odin's portable sessions and credentials available
inside Muninn. Do not mount live Codex or OpenCode SQLite files into their
normal data paths: WAL-mode SQLite returns I/O errors over virtiofs. Exit an
agent conversation on one system before resuming it on the other, and do not
run the same conversation concurrently from both systems.

## First deployment and storage gate

Start with read-only checks on Odin:

```sh
hostname
systemctl status muninn.service --no-pager
test -e /var/lib/muninn/muninn-state.raw && ls -lh /var/lib/muninn/muninn-state.raw
df -h /var/lib/muninn /home/jakob
ip link show mn-muninn
```

The current file-backed design reserves an 80 GiB state disk and requires 100
GiB free before first start. Do not bypass that check or replace an incomplete
`.creating` disk without inspection. Odin's disk layout may instead use a
dedicated partition; confirm the current repository design and exact block
device before any partitioning or formatting. Partitioning, formatting, disk
replacement, and deletion always require explicit user authorization.

Build the guest and host without activating them:

```sh
cd /home/jakob/dotfiles
nix build --no-link .#muninn-manifest
nix build --no-link .#nixosConfigurations.odin.config.system.build.toplevel
nix flake check
```

Apply only when requested:

```sh
sudo nixos-rebuild switch --flake ~/dotfiles#odin
```

The rebuild installs the guest manifest, systemd units, and CLI but does not
start Muninn or create its state disk.

## Lifecycle on Odin

Use the wrapper rather than launching Cloud Hypervisor or `virtiofsd` by hand:

```sh
muninn start
muninn status
muninn ssh
muninn stop
```

`start` prompts through sudo, starts the supervised unit stack, and waits up to
60 seconds for SSH at `10.88.0.10`. The first successful start prepares the
state disk. `stop` asks the guest to power off, then stops the VMM, share
helpers, sockets, and TAP while preserving guest state.

Additional commands:

```sh
muninn restart
muninn import-opencode
muninn logs
muninn serial
muninn ip
```

Muninn is manual-start and remains off after an Odin reboot. A host rebuild
updates the manifest for the next boot; coordinate a deliberate stop/start if
the running guest must pick up a new configuration.

Run `muninn import-opencode` only for the initial Odin-to-Muninn handoff. It
requires no OpenCode process on either machine, checks guest free space, copies
through a staging directory, and refuses to replace existing Muninn state.

## Connect from the MacBook

On Odin, `muninn ssh` connects directly. From Jakob's MacBook, use the `muninn`
SSH host configured with Odin as `ProxyJump`:

```sh
ssh muninn
```

Both Odin and Muninn declaratively trust Jakob's MacBook Ed25519 key. Keep an
existing Odin session open when first verifying key access, and do not disable
Odin's password authentication until a fresh second key-authenticated session
succeeds.

## Inspect health and resource pressure

`muninn status` shows the main service. Inspect the entire VM stack through its
slice when diagnosing memory pressure:

```sh
systemctl show muninn.slice \
  -p MemoryCurrent -p MemoryPeak -p MemoryHigh -p MemoryMax \
  -p MemorySwapCurrent -p MemorySwapMax -p CPUUsageNSec -p TasksCurrent
sudo journalctl -u muninn.service -n 200 --no-pager
sudo journalctl -u 'muninn-virtiofs-*' -n 100 --no-pager
sudo tail -n 200 /var/lib/muninn/logs/serial.log
journalctl -k -g 'oom|Out of memory|Killed process' -n 100 --no-pager
```

If Muninn OOMs, distinguish guest OOM evidence in the serial log from a host
cgroup/oomd kill in Odin's journal. The intended failure boundary is that the
guest or `muninn.slice` stops while Odin and SSH remain available.

For startup failures, inspect `muninn-prepare.service`, all nine virtiofs units,
the exact `mn-muninn` TAP, the state-disk filesystem/label, and serial log. Do
not attach test programs to `enp6s0`, delete the state disk, remove a stale TAP,
or replace sockets until ownership and live processes have been established.

## Completion

Report whether the host configuration was only built or also activated,
whether a first-start disk was created, Muninn's final service and SSH status,
resource observations, and whether it was left running or stopped. Explicitly
call out any live worktree changes because they also changed Odin's files.
