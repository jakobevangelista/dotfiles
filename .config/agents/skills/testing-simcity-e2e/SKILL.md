---
name: testing-simcity-e2e
description: "Runs real full-stack Simcity sandbox E2Es with the monorepo control plane and JavaScript SDK in a VM on the Ubuntu KVM dev box, with Odin-hosted control plane available as an alternative. Use for Simcity node, rootfs, sandbox REST v2, networking, or SDK validation."
---

# Testing Simcity End to End

## Choose the topology

**Default: control-plane VM on the dev box.** Run the monorepo services, SDK
test, h2c enrollment proxy, and disposable S3 store inside that VM. Run
`simcity-node` and its real KVM sandbox guests on the bare-metal host. Odin
orchestrates SSH and may build/package artifacts; it is not a runtime dependency.
Use [the control-plane VM procedure](references/control-plane-vm.md).

**Alternative: control plane on Odin.** Use this whenever the user prefers it,
for a cross-host network test, resource constraints, troubleshooting, or any
other practical reason. State the choice and use
[the Odin procedure](references/odin-control-plane.md). No extra confirmation is
needed just to choose this mode within an authorized E2E. A failure in the VM
mode remains part of the result even if the Odin run passes.

```text
Dev box
  control-plane VM: SDK -> App API -> simcityd + local S3
                            ^             ^
                            | enrollment  | authenticated Iroh
  bare-metal host:          +------ simcity-node
                                        |
                                KVM sandbox guests
```

The VM supplies a separate kernel and network boundary. It shares hardware and
uplink with the node; do not call it full production/WAN parity. Iroh may select
a relay. Report the observed transport without assuming same-host means direct
UDP. Default mode has no SSH tunnels carrying application traffic.

## Access and ownership

| Role | Default |
|---|---|
| Odin controller/build host | `jakob@100.118.239.121` |
| Simcity dev box | `ubuntu@51.222.105.190`, hostname `local-compute-01` |
| Dev-box machine ID | `d65f25f351114245be681fc3b1380b3d`; verify live |
| Source repositories | `/home/jakob/inngest-work/{monorepo,simcity,inngest-js}` |
| Default VM network | host `10.231.75.1/30`, VM `10.231.75.2/30`; verify unused |

Use the forwarded MacBook 1Password agent for Odin-to-dev-box SSH. Explicitly
set the stable socket in every shell tool call using SSH/SCP/Ansible:

```sh
export SSH_AUTH_SOCK=/home/jakob/.ssh/mac-forwarded-agent.sock
test -S "$SSH_AUTH_SOCK"
ssh -o BatchMode=yes ubuntu@51.222.105.190 'hostname; whoami'
```

If the socket is missing or authentication fails, ask the user to reconnect
from their Mac using `ssh -A jakob@100.118.239.121`, run
`ln -sfn "$SSH_AUTH_SOCK" "$HOME/.ssh/mac-forwarded-agent.sock"` in that session,
and leave it open. Do not search `/tmp` for alternative agent sockets, copy
1Password private keys, or forward that agent onward to the dev box. The
control-plane VM uses a separate disposable SSH key generated on the dev box.

Before changes, inventory both hosts' memory/disk, services, Cloud Hypervisor
processes, NIC/BPF ownership, routes, and ZFS datasets. Use fresh names for the
VM, node, Compose project, TAP, nftables table, cgroups, and storage. Do not
replace an active node/NIC owner without existing authorization; ask only when
that replacement is actually needed. Preserve unrelated services and files.

## Select and build compatible sources

Use `jj` where `.jj` exists. Start with the requested revision and inspect its
monorepo/Simcity/SDK compatibility; do not independently select the newest
revision of all three. Fetch current refs when the task calls for current code.
Relevant protocol surfaces include:

```text
monorepo/protobuf/simcity/** and pkg/protobuf/simcity/**
monorepo/pkg/compute/** and cmd/all-in-one/simcityd/**
simcity/proto/** and cmd/simcity-node/internal/nodeapp/**
inngest-js/packages/inngest/src/components/sandbox/**
```

Create disposable clean workspaces rather than building from dirty feature
workspaces. Normal `jj workspace add` checks out files; do not use
`--ignore-working-copy` for that operation.

```sh
jj -R "$MONOREPO_SOURCE" workspace add --name "$MONOREPO_WORKSPACE_NAME" \
  -r "$MONOREPO_REV" "$MONOREPO_WORKSPACE"
jj -R "$SIMCITY_SOURCE" workspace add --name "$SIMCITY_WORKSPACE_NAME" \
  -r "$SIMCITY_REV" "$SIMCITY_WORKSPACE"
```

Read the selected monorepo's `local-e2e.md` and
`scripts/local-simcity-full-stack-e2e.sh` when present for current service
requirements. Use their real-node path, not a fake-node shortcut.

Build the matched Simcity boot bundle before the node binary:

```sh
make artifacts-amd64 build-amd64
sha256sum artifacts/initramfs.cpio.gz artifacts/overlay.erofs artifacts/vmlinux \
  bin/simcity-node-amd64 bin/guest-ebpf-probe
nix shell nixpkgs#erofs-utils -c fsck.erofs artifacts/overlay.erofs
```

Build the selected monorepo `cmd/all-in-one`, `cmd/sdkgateway`, and account setup
program `./scripts/test` in its Nix development environment. Package a compatible
local SDK and install its tarball in the test app; never silently substitute the
registry package. Run focused tests appropriate to the requested source change.
Record revisions and hashes. Never commit generated EROFS/boot artifacts.

The VM topology was validated on 2026-10-14 with Simcity
`3f033d26a0aed966143fe051e33cf6557d467231` (merged #75), monorepo
`bf29c578c4c9805013214279e194e8e22844eab6`, and SDK
`eb59bd901970f28ea2a15d85a7c2eed1d4ef459a`. These are a historical baseline,
not defaults that override a requested candidate. The retained run evidence is
at `/home/jakob/inngest-work/e2e-results/simcity-control-vm-20261014/`;
its dated setup scripts are evidence, not a substitute for this procedure.

## Start, exercise, and verify

1. Follow the selected topology reference to prepare its runtime host.
2. Use [control-plane setup](references/control-plane.md) for bounded Compose,
   fresh identities, S3, account setup, entitlements, and the bootstrap token.
3. Use [the dev-box reference](references/dev-box.md) to install the matched
   node and boot artifacts in an isolated namespace and verify enrollment,
   Iroh connectivity, fresh heartbeats, and ready warm capacity.
4. Run the SDK test on the control-plane host: inside the VM by default, on
   Odin in alternative mode. Run it as a bounded service so the test does not
   depend on an open management SSH session. Assert real guest output, exit
   codes, and the behavior being tested; destroy sandboxes in `finally`.
5. For snapshot/clone/resume changes, test the complete lifecycle. For capacity
   reclamation, fill the governed budget, prove clone and resume reclaim warm
   capacity, reject a further allocation when all capacity is active, verify
   the active guests survive, and check destroy refills the pool. Do not apply
   the small pressure-test budget to every kind of E2E.

For networking tests, assert guest DNS and HTTPS without manually configuring
the guest first. The validated merged #75 build needed no manual DHCP step. If
an older target requires `udhcpc`, make that an explicit diagnostic workaround;
do not mask a network-initialization regression or report it as automatic.

## Resource bounds, cleanup, and reporting

- Require at least 40 GiB of disk headroom on each host that builds artifacts or
  hosts the full stack. Stop and diagnose a shrinking disposable stack before
  it consumes the host's final 20 GiB. Inspect memory and existing load too.
- Bound the control-plane VM and Docker service. Give every container a memory
  limit and no swap; the aggregate container limits must fit the VM. Apply
  only the ClickHouse-specific restart/logging override documented in the
  control-plane reference. Preserve other services' authored restart policies.
- Each independent control plane needs fresh Iroh credentials and matching
  signing configuration. Keep secrets and rendered configs mode `0600`; do
  not print tokens, signing keys, or credential bundles.
- Ordinary lifecycle tests use disposable S3 in the control plane. Cloud auth
  is needed only when the requested test actually exercises cloud storage.

Cleanup is part of completion: destroy test sandboxes/snapshots; stop the node
and its owned guests; remove its ZFS allocations/templates, BPF pins, state,
token copies, binary, and config; tear down Compose and proxy; then remove the
control-plane VM/disk/key/TAP/nftables table and restore saved forwarding state.
In Odin mode, remove the exact tunnel processes instead of VM resources. Use
the mode-specific cleanup details and leave unrelated resources untouched.

Retain a control plane after the final test only when explicitly requested.
Use a verified, at-most-six-hour renewable teardown timer on the host that owns
it: the dev box for a retained VM, Odin for an Odin stack. It must run without
the Mac SSH agent. Clean sandbox/node resources first. Do not retain a VM with
only an Odin-side timer that depends on future SSH access. Report the lease and
exact cleanup command; if automatic cleanup cannot be verified, tear down.
Permission to keep an environment while testing does not imply final retention.

Check disposable workspaces for changes before forgetting/removing them.
Restore only generated artifacts owned by the test. Retain small, redacted
results and scripts; remove large transfer bundles and temporary credentials.

Report topology, source versions, hashes, asserted output, node capacity,
observed Iroh transport, resource limits/headroom, and cleanup state. Distinguish
build location from runtime location, setup failures from application failures,
and tested paths from untested production behavior.
