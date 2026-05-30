# Huginn CLI

`huginn` is the barebones runtime CLI for Huginn VMs on Odin.

It starts Cloud Hypervisor VMs from the Nix-built `huginn-base` manifest. It does not evaluate Nix, generate flakes, or build VM runners during `create`.

## Install Path

Odin installs this package through `flake.nix`:

```nix
environment.systemPackages = [ self.packages.x86_64-linux.huginn ];
```

The base manifest is installed at:

```text
/etc/huginn/base-manifest.json
```

## Commands

```text
sudo huginn create [id]
huginn list
huginn status <id>
sudo huginn stop <id>
sudo huginn destroy <id>
huginn logs <id> [serial|cloud-hypervisor|virtiofsd-store|virtiofsd-metadata]
```

Root is required for lifecycle operations because the CLI creates TAP interfaces and starts KVM-related processes.

## Lifecycle

`create` does the runtime orchestration:

1. Read `/etc/huginn/base-manifest.json`.
2. Create `/var/lib/huginn/instances/<id>` and `/run/huginn/<id>`.
3. Write metadata files.
4. Create `th-<id>` and attach it to `virbr0`.
5. Start `virtiofsd` for `/nix/store` and metadata.
6. Start `cloud-hypervisor` with kernel, initrd, cmdline, TAP, and virtiofs args.
7. Poll `/var/lib/huginn/dnsmasq.leases` for the VM IP.
8. Write `/var/lib/prometheus-targets/huginn-<id>.json`.

`destroy` stops the processes, removes the TAP, removes runtime sockets, and removes persistent instance state.

## State

Persistent instance state:

```text
/var/lib/huginn/instances/<id>/
  state.json
  metadata/
  logs/
```

Runtime sockets:

```text
/run/huginn/<id>/
  ch.sock
  ro-store.sock
  metadata.sock
```

## Guest Store

The host `/nix/store` is shared read-only into the guest. The guest mounts it at `/nix/.ro-store` and overlays a tmpfs writable layer at `/nix/store`.

Guest writes to `/nix/store` are VM-local and ephemeral.

## Development

Build the CLI:

```sh
nix build .#huginn
```

Run help without installing:

```sh
nix run .#huginn -- help
```

Run flake checks:

```sh
nix flake check
```

Apply to Odin:

```sh
sudo nixos-rebuild switch --flake ~/dotfiles#odin
```

The broader architecture and roadmap live in `docs/huginn-vms.md`.
