---
name: using-muninn
description: "Operate and troubleshoot Odin's persistent Muninn Cloud Hypervisor workstation. Use for lifecycle, SSH and 1Password agent forwarding, work-tailnet and cloud CLI access, shared worktrees, resources, storage, or recovery. For production Kubernetes workload operations use using-inngest-prod-kubernetes; excludes disposable Huginn and Simcity E2E guests."
---

# Use the Muninn Workstation

Run `hostname` first. The agent may already be inside Muninn. Run the `muninn`
lifecycle helper on **Odin**; run work-network and cloud commands inside
**Muninn**. Muninn is a singleton persistent workstation with shared host
worktrees and a host-side resource boundary.

Read the relevant runbook instead of repeating initial setup:

- [Work access and verified activation state](/home/jakob/dotfiles/docs/muninn-work-access.md): cloud logins, 1Password reconnect, selected manifest, and live activation details.
- [Temporary jump-box resources](/home/jakob/dotfiles/docs/muninn-jumpbox-2026-09-24.md): current limits and host runtime overrides.
- [Workstation design and recovery](/home/jakob/dotfiles/docs/muninn-workstation.md): storage, shares, deployment, and baseline resources.
- [Kubernetes access](/home/jakob/dotfiles/.config/agents/skills/using-inngest-prod-kubernetes/references/muninn.md): EKS and Ashburn contexts, OIDC, and routes. Use `using-inngest-prod-kubernetes` for cluster operations.

Guest and host configuration live in `hosts/muninn/default.nix` and
`hosts/nixos/odin/muninn-vm.nix` under `/home/jakob/dotfiles`; work access lives
in `modules/home/muninn-work.nix` and `pkgs/work/`. Read them before changing
their configuration.

## Verified state, 2026-09-26

- Muninn runs with **2 vCPUs / 4 GiB RAM**, host `MemoryHigh=5G`,
  `MemoryMax=6G`, `MemorySwapMax=1G`, and `CPUQuota=200%`. The declarative
  workstation baseline is 12 vCPUs / 20 GiB with a 23 GiB host cap. Jakob
  deferred resource increases; do not restore the baseline automatically.
  Runtime resource overrides survive a Muninn restart but disappear on an
  **Odin reboot**. Inspect the host overrides before starting afterward.
- The guest uses the work tailnet `inngest.com`, suffix `tail2dd48.ts.net`,
  with subnet routes accepted. Odin and the Mac stay on the personal tailnet.
  The independent Odin-to-guest SSH path remains `10.88.0.10`.
- Home Manager is active and `work doctor` passed all checks: AWS, GCP logs,
  Datadog, PlanetScale, EKS, NetActuate, Rackspace, network, and bastion SSH.
  Both PgBouncer SSH aliases authenticated; their services reported active.
  These are dated access observations, not a continuing health guarantee.
- The user environment was activated live and a new guest manifest selected
  on Odin. The full guest system was **not** switched or rebooted. A restart
  persistence check remains outstanding; do not restart merely to inspect
  access. The exact selected manifest and GC roots are in the work runbook.
- The existing private state disk is provisioned. Docker service/socket are
  stopped, but boot configuration still enables Docker. Muninn remains
  manual-start after an Odin reboot.

## Understand the boundary

Cloud Hypervisor and its nine `virtiofsd` helpers run in `muninn.slice`.
Inspect both guest resources and host slice limits; neither alone describes
the VM's full resource boundary. Odin and the guest also have zram.

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

Build guest manifests on **Odin**, where full builds were last verified.
Muninn previously encountered `ENOMEM` reading shared Nix-store directories;
flake evaluation now passes outside the agent sandbox. For a guest
configuration change, validate and build without activation or lock-file updates:

```sh
cd /home/jakob/dotfiles
nix flake check --no-build --no-update-lock-file "path:$PWD"
nix build --no-link --print-out-paths --no-update-lock-file --max-jobs 1 --cores 2 "path:$PWD#muninn-manifest"
```

Only build/switch the full Odin configuration when the task needs host
changes and activation is authorized. Inspect unrelated pending edits first:

```sh
nix build --no-link --no-update-lock-file "path:$PWD#nixosConfigurations.odin.config.system.build.toplevel"
sudo nixos-rebuild switch --flake "path:$PWD#odin" --no-update-lock-file
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

On Odin, `muninn ssh` connects directly. From the Mac, the `muninn` SSH alias
should use Odin as `ProxyJump`. If the alias hangs, use the verified explicit
route below. Do not change either machine's tailnet to repair this SSH path.

For production SSH, forward Jakob's existing **1Password work key** from the
Mac. The private key stays in 1Password. Run in the Mac's local terminal:

```sh
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh -A -S none -J odin -o HostKeyAlias=muninn -o StrictHostKeyChecking=yes -o ConnectTimeout=10 jakob@10.88.0.10
```

The verified Muninn host fingerprint is
`SHA256:JS4C1XYuevKAN6vU+4qqKH1R76YfjHqJvBID/+XK0tI`. It was pinned on the Mac
after the initial connection stopped at host-key verification. If verification
fails later, compare the guest's current public host key through the trusted
Odin path; do not disable checking or blindly replace a pin.

Inside that newly connected Muninn shell, run `ssh-add -l`. Confirm the work
fingerprint `SHA256:Ue9fVeyyNxSM5BbpwsngfOtELaunfJ1vLG15kDfbl1Q`, then bind
the live forwarded socket for existing Muninn terminals and agent sessions:

```sh
test -S "$SSH_AUTH_SOCK" && ln -sfn "$SSH_AUTH_SOCK" ~/.ssh/1password-agent.sock
```

Leave the Mac session open and approve 1Password signing prompts there.
Reconnect and refresh the link after disconnection; rebinding is not automatic.
OpenSSH 10.3 used `~/.ssh/agent/s.*.sshd.*` here, so searching only `/tmp/ssh-*`
misses the socket. An older terminal may have no `SSH_AUTH_SOCK` despite a
working forwarded session; prefer the new session's variable.

`prod-bastion`, `pgbouncer-b`, and `pgbouncer-c` select the public key in
`~/.ssh/id_ed25519_work.pub` and the stable socket via `~/.ssh/config.local`.
Preserve the existing `simcity-macbook` block there. These production aliases
disable onward agent forwarding and require pinned host keys. Read-only
verification uses `id -un`, `hostname`, and optionally
`systemctl is-active pgbouncer`; no service restart is needed.

## Check and refresh work access

Inside a fresh Muninn login shell, start with `work doctor`. It checks access
using bounded read probes and suppresses credentials and API payloads; it
does not establish production service health. `--profile staging` changes
AWS/EKS only; the other service checks still target production.

Cloud credentials live in Muninn's private persistent home and do not depend
on the Mac's forwarded SSH agent. Native CLIs retain their account privileges;
diagnostic helpers do not enforce read-only IAM or Kubernetes roles.

- AWS profiles `prod`, `stage`, `staging`, `sandbox`, `operations`, and
  `SystemAdministrator-836356947314` share `sso-session inngest`. `stage` and
  `staging` are aliases for the staging account. Authenticate once with
  `work login aws`; periodic SSO browser reauthentication is still required.
- `work login gcp`, `work login dd`, and `work login pscale` reuse usable
  guest-local sessions. GCP uses `jakob@inngest.com` and project
  `peerless-truck-309218`. Datadog uses `DD_TOKEN_STORAGE=file` and read-only
  OAuth; its browser callback needs a Mac-to-**Muninn loopback** port 8000
  tunnel. Follow the work runbook for exact login and callback commands.
- The imported `~/.kube/config` remains private and comes first in the fresh
  shell's merged `KUBECONFIG`. Optional `work-prod`, `work-stage`, and
  `work-staging` files need not exist; diagnosis must not rewrite the imported
  config. Ashburn uses its own OIDC login and accepted work-tailnet IPv6 routes.

Do not copy cloud token caches or private keys from the Mac/Odin, print them,
or put them in shared worktrees or the Nix store. Give browser codes to the
requesting terminal, not chat. Enroll Tailscale only when needed with
`work login tailscale` **inside Muninn**; ordinary cloud login does not change
tailnets.

Before asking for another login, distinguish network/routing, host-key
verification, SSH identity, and expired cloud sessions. Agent sandboxing can
block private credential refresh or report SSH `Bad owner or permissions`
for normally valid root-owned configuration. Recheck through approved
execution outside the sandbox before changing file ownership or SSH config.
Do not copy/chown Nix-store files to work around that symptom.

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

Report relevant verified facts and remaining limitations. Distinguish built
artifacts, Odin's selected next-boot manifest, live user-environment activation,
and a full guest reboot. State which access checks passed and any remaining
user action. For lifecycle changes, include disk/resource changes and whether
Muninn was left running. Shared worktree edits also change Odin's files.
