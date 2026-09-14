---
name: using-huginn
description: "Operate and troubleshoot Odin's disposable Huginn Cloud Hypervisor VMs. Use for creating, listing, inspecting, connecting to, stopping, restarting, destroying, or diagnosing Huginn instances; do not use for the persistent Muninn workstation or Simcity sandbox E2Es."
---

# Use Huginn VMs

Operate Huginn from Odin with the installed `huginn` CLI. Huginn instances are
small disposable Cloud Hypervisor guests, not persistent workstations.

## Choose the right environment

- Use Huginn for short-lived generic NixOS guests whose filesystem changes may
  disappear.
- Use `$using-muninn` when the work needs persistent Docker/Nix/home state or
  live access to Odin's project directories.
- Use the relevant Simcity E2E skill for Simcity node, KVM guest, rootfs,
  sandbox-runtime, AF_XDP, staging, or production validation.

The canonical implementation details are in
`/home/jakob/dotfiles/docs/huginn-vms.md` and
`/home/jakob/dotfiles/pkgs/huginn/README.md`. Read them before changing the
runtime, recovering inconsistent state manually, or relying on an
implementation detail not covered here.

## Inventory before mutation

Run lifecycle commands only on Odin. Begin with read-only checks:

```sh
hostname
huginn list
systemctl is-active huginn-dnsmasq.service
ip -4 addr show virbr0
free -h
```

For an existing instance, inspect it before stopping, starting, or destroying
it:

```sh
huginn status <id>
huginn logs <id> serial
```

IDs must match `[a-z0-9][a-z0-9-]{0,11}`. Use a descriptive ID when the user
provided one; otherwise `create` can generate one. Do not operate on a target
resolved only by a broad process-name match.

## Lifecycle

Creating an instance starts it immediately and requires sudo:

```sh
sudo huginn create <id>
huginn status <id>
```

Record the ID and IP printed by `create` or `status`. Connect from Odin using
the guest's IP:

```sh
ssh jakob@<vm-ip>
curl http://<vm-ip>:9100/metrics
```

The guest uses DHCP on `virbr0`. A successful process launch without an IP is
not proof of a healthy boot; inspect status, the serial log, and dnsmasq.

Stop and restart a known instance with:

```sh
sudo huginn stop <id>
sudo huginn start <id>
```

`stop` retains the instance ID, MAC, metadata, logs, and SSH host identity, but
the guest root and writable Nix-store overlay are tmpfs. Filesystem changes
inside the guest do not survive stop/start.

Destroying is irreversible for the retained instance state and logs:

```sh
huginn status <id>
sudo huginn destroy <id>
```

Only destroy when the user's request includes removing that exact instance.
Do not infer permission to destroy from a general request to clean up or retry.

## Current safety limits

Huginn's current runtime is intentionally barebones:

- Lifecycle operations run as root.
- Cloud Hypervisor and `virtiofsd` are launched directly rather than supervised
  by a long-running daemon.
- There is no lifecycle locking, reconciliation after reboot, persistent guest
  disk, or per-instance CPU/memory cgroup limit.
- The only host filesystem share is the read-only Nix store plus instance
  metadata. Huginn does not expose Odin's live worktrees.

Avoid concurrent lifecycle commands. Keep the number of instances bounded,
check host memory before creation, and stop instances when they are no longer
needed. Never attach a Huginn guest or container to `enp6s0`, the host network
namespace, `/sys/fs/bpf`, or Odin's Docker socket.

## Troubleshoot without broad cleanup

Use bounded, instance-specific inspection:

```sh
huginn status <id>
huginn logs <id> serial
huginn logs <id> cloud-hypervisor
huginn logs <id> virtiofsd-store
huginn logs <id> virtiofsd-metadata
journalctl -u huginn-dnsmasq.service -n 100 --no-pager
ip -d link show dev th-<id>
```

Persistent state is under `/var/lib/huginn/instances/<id>` and runtime sockets
are under `/run/huginn/<id>`. Treat saved PIDs and `state.json` as evidence, not
as the sole source of truth after a crash or reboot. Check live processes,
sockets, TAPs, and logs before recovery.

Prefer the CLI's exact-target cleanup. Do not manually remove state directories,
TAPs, sockets, Prometheus targets, or processes unless the CLI cannot recover
and the user has authorized that specific cleanup.

## Change and validate the implementation

Runtime `huginn create` must not run Nix. When changing Huginn itself, validate
from `/home/jakob/dotfiles`:

```sh
nix build --no-link .#huginn
nix build --no-link .#huginn-base-manifest
nix build --no-link .#nixosConfigurations.odin.config.system.build.toplevel
nix flake check
```

Building is non-activating. Run `sudo nixos-rebuild switch --flake
~/dotfiles#odin` only when applying the Odin configuration is within the user's
request.

Report the instance ID, observed status/IP, checks performed, and whether the
instance was left running, stopped, or destroyed.

