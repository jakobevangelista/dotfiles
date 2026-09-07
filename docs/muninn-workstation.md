# Muninn Workstation VM

Muninn is Odin's large, persistent development VM. In Norse mythology,
Huginn is "thought" and Muninn is "memory"; the name reflects the intended
split between disposable Huginn workers and the workstation that remembers its
state.

## Status

The NixOS guest, Odin systemd services, lifecycle CLI, persistent state disk,
networking, and live project shares are implemented. The configuration is
manual-start by design: rebuilding Odin installs it but does not create the
state disk or start the VM.

Runtime validation completed on 2026-09-07. A stop/start preserved private
home state, the guest Nix database, an imported 371-session OpenCode database,
and a Docker volume. Docker containers resolved DNS and reached HTTPS while
their veth remained unmanaged by systemd-networkd. A Codex transcript created
on Odin resumed successfully inside Muninn, and a guest-root write to a live
worktree was squashed to host user `jakob`. Odin remained online with the
Muninn slice limits active and no XDP or TC hook on `enp6s0`. The MacBook's
`ssh muninn` path was also verified through the Odin `ProxyJump`.

Tailscale enrollment was validated on 2026-09-10. Muninn retained device ID
`ngT9z9JAQP11CNTRL` and address `100.71.114.56` across a full stop/start with
no new login. Direct MacBook SSH by tailnet IP and FQDN worked, as did the
existing ProxyJump path. The restart exposed the upstream MagicDNS bug
described below. The backport passed its upstream regression tests and a live
guest test that added and removed a temporary dummy interface; MagicDNS kept
resolving the MacBook correctly through each link change. Odin's IPv4/IPv6
HTTPS, SSH, and Tailscale remained healthy throughout.
The patched manifest was subsequently activated on Odin and booted in Muninn.
That full restart retained the same authenticated device identity, and
MagicDNS, direct MacBook SSH by IP/FQDN, and the ProxyJump fallback all passed
again without manual DNS repair.

## Boundary

Muninn gets:

- 20 GiB guest RAM and 12 vCPUs
- a 5 GiB compressed zram device inside the guest
- an 80 GiB fully allocated persistent ext4 state disk
- its own Docker daemon, where `jakob` may use Docker and passwordless sudo
- outbound networking through a TAP on Odin's `virbr0` bridge
- the same Home Manager environment, portable Codex sessions, and selected
  coding-agent histories as Odin

The complete host-side VM stack lives in `muninn.slice`, including Cloud
Hypervisor and its nine `virtiofsd` helpers:

- `MemoryHigh=21G`
- `MemoryMax=23G`
- `MemorySwapMax=8G`
- `AllowedCPUs=2-7,10-15`, reserving physical cores 0 and 1 for Odin
- systemd-oomd monitoring at 70% memory pressure

Odin also gets an 8 GiB logical zram swap device (25% of its 32 GiB RAM) to
absorb abrupt host pressure while the cgroup and oomd protections react. Zram
uses compressed memory on demand; it does not permanently reserve 8 GiB.

If development workloads exhaust memory, the guest or the Muninn slice can be
killed without exhausting all of Odin. This protects the host, not every
process inside the guest: a workload can still OOM Muninn itself.

Muninn does **not** receive Odin's Docker socket, `/dev` tree, BPF filesystem,
root filesystem, physical NIC, or host network namespace. Root in the VM may
reconfigure only its virtual NIC and cannot attach XDP to `enp6s0`.

## Storage and Sharing

| Guest path | Backing | Persistence | Semantics |
| --- | --- | --- | --- |
| `/` | 8 GiB tmpfs | No | Declarative OS state |
| `/nix/store` | read-only Odin store plus state-disk overlay | Yes for guest writes | Host store cannot be changed |
| `/nix/var/nix` | state disk | Yes | Guest Nix database and profiles |
| `/home/jakob` | state disk | Yes | Workstation-local home state |
| `/persist/etc-ssh/ssh_host_ed25519_key` | state disk | Yes | Stable SSH host identity |
| `/var/lib/docker` | state disk | Yes | Images, volumes, and containers |
| `/var/lib/tailscale` | state disk (`/persist/var-lib-tailscale`) | Yes | Private tailnet identity and authentication |
| `/home/jakob/inngest-work` | Odin live directory | Host-owned | Same files on both systems |
| `/home/jakob/personal` | Odin live directory | Host-owned | Same files on both systems |
| `/home/jakob/dotfiles` | Odin live directory | Host-owned | Same files on both systems |
| `/home/jakob/.codex` | state disk plus selected Odin files | Mixed | Private SQLite state; live sessions, configuration, and authentication |
| `/home/jakob/.claude` | Odin live directory | Host-owned | Claude Code sessions and authentication |
| `/home/jakob/.local/share/opencode` | state disk | Yes | Private OpenCode database, initially imported from Odin |
| `/home/jakob/.local/share/amp` | Odin live directory | Host-owned | Amp sessions and authentication |
| `/run/muninn-host/opencode` | read-only Odin directory | Host-owned | OpenCode one-time import source |

The project, Claude, and Amp shares are direct virtiofs mounts, not Huginn's
tmpfs overlay. Changes made on either side are immediately visible on the
other side. That also means deletion or corruption in Muninn affects the real
host files in those directories; version control and backups remain important.

Codex is split deliberately: its WAL-mode SQLite databases remain private to
each machine, while its portable session transcripts are live and writable at
the same path. Selected configuration and authentication files point into the
Odin share. This lets `codex resume` discover and continue an Odin session
without trying to operate SQLite over virtiofs.

OpenCode also uses a WAL-mode SQLite database, so its entire state directory is
not live-mounted. Close OpenCode on both systems and run `muninn
import-opencode` once, before first using OpenCode in Muninn. The command
refuses to overwrite a non-empty guest state directory and leaves an
interrupted staging directory for inspection.

The identical worktree paths preserve directory-scoped session lookup. Shared
agent state also exposes credentials to Muninn, which is intentional for this
trusted workstation. Never open the same conversation concurrently on Odin
and Muninn; hand it off by exiting the first agent process before resuming on
the other system.

Each writable `virtiofsd` runs as host user `jakob`. Guest UIDs and GIDs are
squashed to host UID 1000 and GID 100, so even guest root cannot create
host-root-owned files. The service's mount namespace exposes only its assigned
work directory and hides the rest of `/home`.

The state disk lives at:

```text
/var/lib/muninn/muninn-state.raw
```

Its 80 GiB is reserved on the host before it is formatted. This prevents the
guest's Docker or Nix storage from unexpectedly filling Odin's filesystem. The
first start requires 100 GiB free: 80 GiB for the disk plus 20 GiB retained as
host headroom. No lifecycle command deletes or recreates an existing disk.

The live project and portable agent-state shares are not covered by that
reservation. Muninn can consume host space by writing into those directories
just as Jakob can on Odin, so they still require normal free-space monitoring.

At every boot, Muninn registers the manifest's complete system closure in its
persistent Nix database before starting the Nix daemon or Home Manager. This
keeps the guest database consistent with the read-only Odin store view while
allowing guest-installed Nix packages and profiles to persist on the state
disk.

Odin's Git configuration rewrites GitHub HTTPS URLs to SSH. Muninn removes
only that rewrite because the guest deliberately has no outbound private key,
allowing public bootstrap tools and dependency managers to use HTTPS. It also
pins GitHub's published Ed25519 host key system-wide for deliberate SSH
connections without an unverified first-contact prompt.

Neovim's configuration is read-only through Home Manager. Lazy seeds the
tracked `lazy-lock.json` into each machine's persistent runtime state, keeping
the checked-in versions as the baseline while allowing `:Lazy update` to write
its active lockfile.

## Network

- address: `10.88.0.10/24`
- gateway and DNS: `10.88.0.1`
- TAP: `mn-muninn`
- MAC: `02:4d:55:4e:49:4e`
- guest inbound service: SSH on port 22 (Tailscale identity on the tailnet;
  OpenSSH keys on the private address)
- Tailscale: independent `muninn` tailnet device, UDP 41641 for direct peers

Odin's existing `virbr0` NAT supplies outbound access. A failed or hostile
guest cannot alter Odin's physical interface because it has only the TAP-backed
virtio NIC.

Tailscale runs inside Muninn using its virtual NIC. It does not advertise an
exit node or subnet routes, and does not accept subnet routes. MagicDNS is
accepted through the guest's existing systemd-resolved. Tailscale SSH handles
connections to Muninn's Tailscale IP and authenticates using tailnet identity
and the tailnet's SSH access policy. Client SSH keys are not required for
that path. The private address and ProxyJump fallback still use key-only
OpenSSH. Tailscale netfilter management is disabled so the guest's NixOS
firewall remains responsible for other inbound host services.

The pinned Tailscale 1.98.0 has an upstream MagicDNS bug: a major interface
change discards local DNS routes, including when Docker's bridge appears at
boot. Muninn's package backports
[Tailscale's fix](https://github.com/tailscale/tailscale/commit/b192880cb4850248ee8d1997b247709eb85c6d56)
and runs its two regression tests during the build. Remove the guest-only
override once nixpkgs is updated to a release containing that fix.

The root-only `/persist/var-lib-tailscale` directory is prepared before its
bind mount on every boot, including on existing state disks. `tailscaled`
requires that mount, so authentication cannot accidentally land on tmpfs.
New state disks also include the directory in their skeleton. No auth key is
stored in the repository; enroll once after deploying and restarting:

```bash
muninn ssh sudo tailscale up --accept-dns=true --accept-routes=false \
  --advertise-exit-node=false --advertise-routes= --ssh=true --netfilter-mode=off
```

Open the printed login URL in a browser. Then check `muninn ssh tailscale
status`, MagicDNS, and direct MacBook SSH to `jakob@<muninn-tailscale-ip>`.
Keep the MacBook's existing `Host muninn` ProxyJump entry as a fallback.
A `muninn restart` must retain the same Tailscale device ID and IP without
another login.

From a device signed into the tailnet, connect as the existing guest user:

```bash
ssh jakob@muninn.tail1d42c.ts.net
# Or use Tailscale's SSH wrapper for automatic host-key verification:
tailscale ssh jakob@muninn
```

Tailscale SSH has a separate host key from the private-address OpenSSH
server. Switching an existing SSH alias from OpenSSH to Tailscale SSH can
therefore produce a host-key-change warning. Verify the new fingerprint
through the authenticated Tailscale control plane (the `tailscale ssh`
wrapper does this automatically) before replacing the old entry. Remove
only the affected alias with `ssh-keygen -R muninn`; retain the private
address's host key for the OpenSSH/ProxyJump fallback.

The source device's local username can differ (for example, `jakobtest` on
the temporary MacBook); explicitly select `jakob`. Enabling the SSH server
does not bypass the tailnet policy: both TCP 22 network access and a Tailscale
SSH rule allowing login as `jakob` are required. An `accept` SSH rule uses the
existing tailnet login; a `check` rule can additionally prompt for browser
reauthentication. Configure these in the Tailscale admin console's Access
controls page. OpenSSH's `AllowUsers` does not govern Tailscale SSH, so scope
the policy's `users` field to `jakob`.

For Jakob's user-owned devices, append this object to the existing `ssh`
array at <https://login.tailscale.com/admin/acls>, preserving other rules:

```json
{
  "action": "accept",
  "src": ["jakobevangelista@gmail.com"],
  "dst": ["autogroup:self"],
  "users": ["jakob"]
}
```

This covers all devices signed in as Jakob, including newly enrolled laptops;
it does not grant other users or tagged service devices access. Tailscale
requires a tagged destination and corresponding rules to support those
sources. The rule also applies to any other Jakob-owned device with Tailscale
SSH enabled and a local `jakob` account.

Tailnet reachability does not provide an outbound SSH credential. To use the
MacBook's key temporarily from Muninn, connect from the MacBook with `ssh -A
muninn` and use that session; no private key is copied into the guest. Agent
forwarding lets processes in the guest request signatures while connected, so
use it only for trusted workstation sessions.

## Build and First Start

From Odin, first build without activating anything:

```bash
cd ~/dotfiles
nix build --no-link .#muninn-manifest
sudo nixos-rebuild build --flake .#odin
```

Apply the host configuration when ready:

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#odin
```

This does not start Muninn. The first explicit start reserves and formats the
state disk, creates the TAP, launches the nine restricted virtiofs
helpers, and boots Cloud Hypervisor:

```bash
muninn start
muninn status
muninn ssh
```

Other lifecycle commands:

```bash
muninn stop
muninn restart
muninn import-opencode
muninn logs
muninn serial
muninn ip
```

`muninn stop` asks the guest to power off before stopping the VMM and helpers.
The state disk and all workstation state remain in place. The service is not
wanted by `multi-user.target`, so it also stays off after an Odin reboot until
explicitly started.

## MacBook SSH Setup

Muninn trusts both Odin's VM-access key and Jakob's MacBook key. The same
MacBook key is provisioned on Odin. Rebuild, then test the key in a second
terminal before disabling Odin's password authentication.

On the MacBook, inspect existing public keys:

```bash
ls -1 ~/.ssh/*.pub
cat ~/.ssh/id_ed25519.pub
```

If there is no suitable Ed25519 key, create one and copy only the `.pub` file:

```bash
ssh-keygen -t ed25519 -C "jakob-macbook"
pbcopy < ~/.ssh/id_ed25519.pub
```

The public line beginning with `ssh-ed25519` is safe to share. Never send
`~/.ssh/id_ed25519` without the `.pub` suffix. The key is configured at:

- `users.users.jakob.openssh.authorizedKeys` in
  `hosts/nixos/odin/default.nix`
- `users.users.jakob.openssh.authorizedKeys` in
  `hosts/muninn/default.nix`

Because `10.88.0.10` is private behind Odin, connect from macOS with an SSH jump
host:

```sshconfig
Host odin
  HostName <odin-lan-or-tailscale-address>
  User jakob
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes

Host muninn
  HostName 10.88.0.10
  User jakob
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  ProxyJump odin
```

Then use:

```bash
ssh muninn
```

Keep the existing Odin SSH session open during the first key-only test. Disable
password and keyboard-interactive login on Odin only after a fresh second
session succeeds.

## Recovery and Inspection

If startup fails, inspect without deleting state:

```bash
muninn status
muninn logs
muninn serial
sudo systemctl status muninn-prepare.service
sudo systemctl status 'muninn-virtiofs-*'
sudo ls -lh /var/lib/muninn/muninn-state.raw
ip link show mn-muninn
```

The preparation service refuses to overwrite a disk with the wrong filesystem
or label, refuses to replace an existing TAP, and leaves an interrupted
`.creating` disk for manual inspection.
