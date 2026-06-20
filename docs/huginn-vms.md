# Huginn VMs

This is the canonical plan and operating guide for Huginn VMs on Odin.

Huginn uses Nix to build one reusable guest base artifact and a small Go CLI to do runtime VM lifecycle work. Runtime `huginn create` does not call Nix, generate flakes, update lock files, or build per-VM runners.

## Status

Current implementation: barebones root-run VM lifecycle CLI.

Implemented:

- Nix-built `huginn-base` guest system
- Nix-built `huginn-base-manifest.json`
- Go `huginn` CLI package
- direct Cloud Hypervisor launch
- direct `virtiofsd` launch
- dynamic VM IDs, TAPs, MACs, metadata, state JSON, and logs
- host-side DHCP lease polling
- host-side Prometheus file-SD target registration
- persistent per-instance SSH host keys
- read-only host `/nix/store` share with guest tmpfs writable overlay

Not implemented yet:

- long-running `huginnd` daemon
- reconciliation after host reboot or CLI crash
- Cloud Hypervisor API-based graceful shutdown
- concurrent operation locking
- persistent guest data disks
- snapshot/restore or warm pool support
- dynamic SSH key injection from guest metadata

## Why This Replaces `microvm.nix`

The earlier `microvm.nix` pool was Nix-native and worked, but each VM was a concrete predeclared runner:

```text
huginn-a1b2 runner has hostname/TAP/MAC baked in
huginn-b2c3 runner has hostname/TAP/MAC baked in
huginn-c3d4 runner has hostname/TAP/MAC baked in
```

That model is good for fixed capacity. It is not a generic runtime template.

The new model is:

```text
one Huginn base artifact
many runtime instances with dynamic IDs/TAPs/MACs/metadata
```

Nix still owns reproducibility. Go owns orchestration.

## Architecture

```text
                        Nix flake build
                              |
                              v
                 huginn-base-manifest.json
                 kernel / initrd / system / cmdline
                              |
                              v
Odin host
  huginn CLI
    - reads /etc/huginn/base-manifest.json
    - allocates instance IDs
    - creates TAP interfaces
    - starts virtiofsd processes
    - starts cloud-hypervisor
    - polls dnsmasq leases for IPs
    - writes Prometheus targets

  virbr0 10.88.0.1/24
    th-<id> TAP interfaces

  /nix/store                  -> guest /nix/.ro-store via read-only virtiofs
  /var/lib/huginn/instances   -> persistent host-side instance state
  /run/huginn/<id>            -> runtime sockets
  /var/lib/prometheus-targets -> host-side Prometheus file-SD targets
```

## Repository Layout

- `flake.nix` exposes the Huginn package, base manifest, and `nixosConfigurations.huginn-base`.
- `hosts/huginn-base/default.nix` defines the generic NixOS guest.
- `hosts/nixos/odin/huginn-vms.nix` defines Odin host VM networking and directories.
- `pkgs/huginn/` contains the Go CLI package.
- `docs/huginn-vms.md` is this master plan and operating guide.

## Nix Responsibilities

Nix builds one generic guest base and one manifest.

The manifest is installed on Odin at:

```text
/etc/huginn/base-manifest.json
```

Shape:

```json
{
  "kernel": "/nix/store/.../bzImage",
  "initrd": "/nix/store/.../initrd",
  "system": "/nix/store/...-nixos-system-huginn-base",
  "cmdline": "console=ttyS0 reboot=t panic=-1 init=/nix/store/...-nixos-system-huginn-base/init"
}
```

The base guest config includes:

- tmpfs `/` with `size=4G`
- read-only host store mounted at `/nix/.ro-store`
- tmpfs writable store upper/work dirs at `/nix/.rw-store`
- overlayfs mounted at `/nix/store`
- metadata mount at `/run/huginn/metadata`
- DHCP networking with systemd-networkd
- SSH server for user `jakob`
- public-key authentication only
- per-instance Ed25519 SSH host key from metadata
- no passwordless sudo
- node exporter on `:9100`

## Go Responsibilities

The `huginn` CLI owns runtime VM state and process lifecycle.

Commands:

```text
sudo huginn create [id]
sudo huginn start <id>
huginn list
huginn status <id>
sudo huginn stop <id>
sudo huginn destroy <id>
huginn logs <id> [serial|cloud-hypervisor|virtiofsd-store|virtiofsd-metadata]
```

`create` flow:

1. Read `/etc/huginn/base-manifest.json`.
2. Allocate or validate the instance ID.
3. Generate a locally administered MAC.
4. Create `/var/lib/huginn/instances/<id>` and `/run/huginn/<id>`.
5. Write metadata files.
6. Create TAP interface `th-<id>` and attach it to `virbr0`.
7. Start `virtiofsd` for host `/nix/store` as read-only.
8. Start `virtiofsd` for per-instance metadata.
9. Start Cloud Hypervisor from the manifest.
10. Wait for the Cloud Hypervisor API socket.
11. Poll the dnsmasq lease file for the VM IP.
12. Write the Prometheus target file.

`start` reuses an existing stopped VM's ID, name, MAC, TAP, metadata, and logs. It refreshes the base manifest from `/etc/huginn/base-manifest.json`, removes stale runtime artifacts, recreates the runtime sockets and TAP, starts `virtiofsd` and Cloud Hypervisor, then waits for DHCP again.

No Nix command runs in this flow.

## Host Networking

Odin keeps NetworkManager for `enp1s0`. VM-side networking is managed separately.

- bridge: `virbr0`
- bridge address: `10.88.0.1/24`
- TAP pattern: `th-*`
- DHCP range: `10.88.0.100` through `10.88.0.250`
- DHCP lease file: `/var/lib/huginn/dnsmasq.leases`
- outbound NAT: `virbr0` to `enp1s0`
- firewall on `virbr0`: UDP `53`, UDP `67`, TCP `53`

## Nix Store Overlay

The guest store layout is:

```text
host /nix/store      -> guest /nix/.ro-store  read-only virtiofs
guest tmpfs          -> guest /nix/.rw-store  writable upper/work
overlayfs            -> guest /nix/store      writable view
```

Reads for existing base-system store paths come from Odin's host store. Writes to `/nix/store` go to the guest tmpfs upper layer, so they are VM-local and disappear when the VM stops.

This is the equivalent of the useful `microvm.nix` behavior where the guest can read the host store but keeps writes isolated.

## Cloud Hypervisor Invocation

The Go CLI launches Cloud Hypervisor directly.

Important detail: the packaged Cloud Hypervisor accepts one `--fs` flag with multiple values. Do not pass `--fs` multiple times.

Approximate shape:

```sh
cloud-hypervisor \
  --kernel /nix/store/.../bzImage \
  --initramfs /nix/store/.../initrd \
  --cmdline "console=ttyS0 reboot=t panic=-1 init=/nix/store/.../init" \
  --cpus boot=2 \
  --memory size=6144M,shared=on \
  --fs tag=ro-store,socket=/run/huginn/<id>/ro-store.sock tag=metadata,socket=/run/huginn/<id>/metadata.sock \
  --net tap=th-<id>,mac=<mac> \
  --api-socket path=/run/huginn/<id>/ch.sock \
  --serial file=/var/lib/huginn/instances/<id>/logs/serial.log \
  --console off \
  --seccomp true \
  --watchdog
```

`shared=on` is required for Cloud Hypervisor with `virtiofs`.

## virtiofsd Invocation

Store share:

```sh
virtiofsd \
  --shared-dir /nix/store \
  --socket-path /run/huginn/<id>/ro-store.sock \
  --cache auto \
  --posix-acl \
  --xattr \
  --readonly
```

Metadata share:

```sh
virtiofsd \
  --shared-dir /var/lib/huginn/instances/<id>/metadata \
  --socket-path /run/huginn/<id>/metadata.sock \
  --cache auto \
  --posix-acl \
  --xattr
```

## Runtime State

Persistent state:

```text
/var/lib/huginn/
  dnsmasq.leases
  instances/
    <id>/
      state.json
      metadata/
        instance-id
        hostname
        mac
        tap
        ssh-authorized-keys
        ssh_host_ed25519_key
        ssh_host_ed25519_key.pub
      logs/
        serial.log
        cloud-hypervisor.log
        cloud-hypervisor.stderr.log
        virtiofsd-store.log
        virtiofsd-metadata.log
```

Runtime sockets:

```text
/run/huginn/<id>/
  ch.sock
  ro-store.sock
  metadata.sock
```

Prometheus target:

```text
/var/lib/prometheus-targets/huginn-<id>.json
```

Target shape:

```json
[
  {
    "targets": ["10.88.0.123:9100"],
    "labels": {
      "job": "huginn",
      "instance": "huginn-<id>"
    }
  }
]
```

## Usage

Apply the Odin config:

```sh
sudo nixos-rebuild switch --flake ~/dotfiles#odin
```

Create a VM:

```sh
sudo huginn create test1
```

Inspect it:

```sh
huginn list
huginn status test1
huginn logs test1 serial
huginn logs test1 cloud-hypervisor
```

Connect to it:

```sh
ssh jakob@<vm-ip>
```

Check node exporter:

```sh
curl http://<vm-ip>:9100/metrics
```

Stop and start it again:

```sh
sudo huginn stop test1
sudo huginn start test1
```

Destroy it:

```sh
sudo huginn destroy test1
```

IDs may be 1-12 lowercase letters, digits, or hyphens. This keeps TAP names within Linux's 15-character interface limit because TAP names are `th-<id>`.

## Validation

Build checks:

```sh
nix build .#huginn
nix build .#huginn-base-manifest
nix build .#nixosConfigurations.huginn-base.config.system.build.toplevel
nix build .#nixosConfigurations.odin.config.system.build.toplevel
nix flake check
```

Runtime checks after switching Odin:

```sh
sudo huginn create test1
huginn status test1
curl http://<vm-ip>:9100/metrics
ssh jakob@<vm-ip>
sudo huginn stop test1
sudo huginn start test1
sudo huginn destroy test1
```

Inside the guest, verify the store overlay:

```sh
findmnt /nix/.ro-store /nix/.rw-store /nix/store
```

Expected shape:

```text
/nix/.ro-store  virtiofs  ro
/nix/.rw-store  tmpfs     rw
/nix/store      overlay   rw
```

## Troubleshooting

If create fails before an IP appears, inspect logs:

```sh
huginn logs <id> cloud-hypervisor
huginn logs <id> serial
huginn logs <id> virtiofsd-store
huginn logs <id> virtiofsd-metadata
```

Check host services and networking:

```sh
systemctl status huginn-dnsmasq --no-pager
journalctl -u huginn-dnsmasq -n 100 --no-pager
ip -4 addr show virbr0
ip -d link show dev th-<id>
```

If a failed VM left stale state:

```sh
sudo huginn destroy <id>
```

If the old `microvm.nix` experiment left state behind, it is separate from the new CLI:

```sh
systemctl list-units 'microvm@*.service' --all
sudo rm -rf /var/lib/microvms/huginn-a1b2 /var/lib/microvms/huginn-b2c3 /var/lib/microvms/huginn-c3d4 /var/lib/microvms/huginn-d4e5
sudo rm -rf /var/lib/huginn-vms/specs/huginn-a1b2
sudo rm -f /var/lib/prometheus-targets/huginn-*.json
```

## Security Model

The first implementation runs as root because it creates TAP interfaces and launches KVM processes.

Hardening steps later:

- run Cloud Hypervisor as a dedicated unprivileged user
- isolate helper privileges or capabilities
- keep the host store share read-only
- restrict per-instance metadata permissions
- use cgroups for resource accounting
- keep Cloud Hypervisor seccomp enabled

## Production Readiness Gaps

The current implementation is intentionally barebones. These are the missing pieces before treating Huginn as a production-grade VM orchestration layer.

### Process Supervision

- Add a long-running `huginnd` daemon instead of letting a root CLI own process launch and cleanup.
- Keep Cloud Hypervisor and `virtiofsd` children supervised by the daemon.
- Reap child processes reliably so exited VMs do not leave stale PID state.
- Add restart policy decisions for failed helper processes and failed VMs.
- Make VM process state derived from live processes and API sockets, not only saved PIDs.

### Reconciliation

- Reconcile `/var/lib/huginn/instances/*` against live processes after host reboot, daemon restart, or CLI crash.
- Detect stale TAP devices, stale sockets, stale Prometheus target files, and orphaned `virtiofsd` processes.
- Implement idempotent cleanup for partially failed `create`, `start`, `stop`, and `destroy` flows.
- Mark instances as `failed`, `stopped`, or `running` based on observed state.

### Concurrency

- Add host-level locking so two lifecycle commands cannot race.
- Add per-instance locking around lifecycle operations.
- Prevent duplicate TAP names, MACs, runtime sockets, and state directories under concurrent operations.
- Make state writes transactional enough that interrupted commands cannot leave corrupt JSON.

### Graceful Lifecycle

- Use the Cloud Hypervisor API socket for graceful shutdown before killing processes.
- Add timeouts and explicit lifecycle states such as `creating`, `running`, `stopping`, `stopped`, `failed`, and `destroyed`.
- Separate `stop` from `destroy` clearly once persistent disks exist.
- Add `restart` and possibly `force-stop` commands.
- Preserve enough failure detail in state for postmortem debugging.

### Networking

- Replace DHCP lease polling with a more robust IP discovery path, such as dnsmasq lease events, netlink neighbor events, or a guest metadata report.
- Reconcile stale leases and stale Prometheus targets when a VM exits unexpectedly.
- Validate that `virbr0`, NAT, dnsmasq, and firewall rules are available before starting VMs.
- Decide whether bridge and dnsmasq stay Nix-managed or move into `huginnd`.
- Add explicit handling for MAC/IP conflicts.

### Storage

- Add optional persistent data disks for workloads that need state beyond VM lifetime.
- Decide whether the `/nix/store` overlay upper layer stays tmpfs-only or can be backed by a persistent disk.
- Add disk creation, attachment, resizing, and deletion lifecycle.
- Add snapshot and restore support if fast cloning or rollback becomes important.
- Document garbage collection expectations for base system closures and runtime state.

### Metadata And Guest Agent

- Move SSH authorized keys fully into metadata instead of baking them into the base guest.
- Add a small guest metadata agent for hostname, authorized keys, project bootstrap, and optional health reporting.
- Decide whether metadata is read-only or read-write from the guest.
- Version the metadata schema so future changes are explicit.
- Add a guest-to-host signal for boot completion and IP reporting if DHCP lease polling remains unreliable.

### Security

- Run Cloud Hypervisor as a dedicated unprivileged user where practical.
- Minimize root-only operations to small helpers or capability-scoped paths.
- Restrict permissions on `/var/lib/huginn/instances/<id>/metadata` and runtime sockets.
- Add cgroup limits and accounting for CPU, memory, PIDs, and IO.
- Audit host paths exposed through `virtiofsd` and keep `/nix/store` read-only.
- Keep Cloud Hypervisor seccomp enabled and document any required exceptions.

### Observability

- Add structured logs for lifecycle events.
- Expose host-side metrics for VM count, create duration, failures, process state, and IP assignment latency.
- Include Cloud Hypervisor exit status and stderr summary in `huginn status`.
- Add `huginn events <id>` or equivalent if lifecycle history becomes useful.
- Make Prometheus target registration reconciliation explicit, not only best-effort during create/destroy.

### Testing

- Add unit tests for ID validation, MAC generation, state parsing, lease parsing, and command argument handling.
- Add integration tests for failed Cloud Hypervisor launch cleanup.
- Add integration tests for stop/destroy idempotency.
- Add a VM boot smoke test that verifies DHCP, SSH, node exporter, and the `/nix/store` overlay.
- Add regression tests for Cloud Hypervisor argument generation, especially `--fs` syntax.

### Operations

- Add clear recovery commands for stale instances and orphaned processes.
- Add `huginn doctor` to validate host prerequisites and report common problems.
- Add `huginn prune` for stopped instances, stale targets, and old logs.
- Add configurable defaults for vCPUs, memory, bridge, DHCP lease path, and target directory.
- Add a migration path for old state schema versions.

## Roadmap

Next practical improvements:

1. Add host-level and per-instance locking.
2. Use the Cloud Hypervisor API socket for graceful shutdown before killing processes.
3. Add `huginn doctor` for host prerequisite checks and common failure diagnostics.
4. Add a `huginnd` daemon that owns process supervision and reconciliation.
5. Reconcile stale state after host reboot or daemon restart.
6. Move SSH authorized keys fully into metadata rather than baking them into the base guest.
7. Add optional persistent data disks.
8. Add structured lifecycle logs and host-side metrics.
9. Add warm pool or snapshot/restore if VM boot time becomes a problem.

## Success Criteria

- `huginn create` does not run Nix.
- `huginn create` starts a VM from one prebuilt base artifact.
- `huginn start` boots a stopped VM from its saved identity and the current base manifest.
- Guest reads Odin's host `/nix/store` through read-only `virtiofs`.
- Guest writes to a VM-local `/nix/store` overlay upper layer.
- Guest gets DHCP on `virbr0`.
- Host writes a Prometheus target file for the VM.
- `huginn destroy` stops processes, deletes the TAP, removes runtime sockets, and removes persistent instance state.
