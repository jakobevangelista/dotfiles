# Adding a production Simcity node

Use this path for inspecting and provisioning a new host. Reading a host and
preparing inventory changes are separate from initializing its disk, rebooting,
and enrolling it. Honor authorization already given in the conversation; an
investigation request alone does not authorize those mutations.

## Establish access and inspect without provisioning

Use the stable Mac-forwarded SSH agent described in `../SKILL.md`, explicitly
setting `SSH_AUTH_SOCK` for every SSH or Ansible call. Connect using the account
the provider actually supplied; a root-only fresh host may not have `ubuntu`.
Disable onward agent forwarding with `ssh -a`. Preserve host-key verification.
For an explicitly supplied new address, record first-use trust and the observed
fingerprint if using `StrictHostKeyChecking=accept-new`; this is not independent
identity verification. Resolve a changed key through a trusted source, and do
not use `StrictHostKeyChecking=no`.

Collect only nonsecret facts, with ordinary read-only commands:

- `hostname`, `/etc/os-release`, `uname -r`, uptime, and `/etc/machine-id`.
  The definitive enrollment ID comes from `simcity-node ... machine-id` after
  installation; do not invent it from the hostname or IP.
- `lscpu`: CPU model/vendor, sockets, physical cores, threads, virtualization
  flags; `/sys/devices/system/cpu/smt/{active,control}`; `/dev/kvm`;
  `/sys/fs/cgroup/cgroup.controllers`; `free -m`.
- `findmnt -n -o SOURCE /`, `lsblk -b -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL`,
  and `/dev/disk/by-id` links. Trace root-device ancestry, including RAID/LVM,
  before identifying a data disk. Use `wipefs -n` only to inspect signatures.
  Inspect existing ZFS pools if ZFS tools are installed; never import or wipe
  storage during discovery.
- `ip -br address`, `ip -4 route`, `ip -d link`, driver/firmware and channel
  counts with `ethtool -i`/`ethtool -l`, existing XDP attachments, resolver,
  firewall, and MTU. Record missing tools; do not install them for inspection.
- Simcity/Cloud Hypervisor service presence, versions/hashes, credential-file
  existence and permissions (never contents), existing workload counts, mounts,
  and failed units. Do not infer freshness solely from the hostname or uptime.
- Provider, physical location, intended inventory name, and functioning console
  access. An IP address alone does not establish a datacenter or provider.

Also inventory the existing fleet's live profiles, capacity, artifact hashes,
CPU classes, heartbeat/connection state, and workloads. Compare with the
production inventory in a current, identified revision; old rollout workspaces
may contain stale code or modified artifacts. Do not drain existing nodes merely
to inspect or add capacity.

**Do not use `--tags preflight` or `--tags validate` as read-only inspection.**
In the current bundle, every selected phase except `deploy` includes kernel
management, which can install packages and reboot before the named phase. The
preflight phase also installs packages and loads modules. Read the task list in
the selected revision before executing any playbook.

## Hardware and configuration decisions

Verify current `infra/ansible/README.md`, role defaults, and task files. At
Simcity revision `6061b3f6`, the supported baseline is:

- Ubuntu 24.04 x86-64, KVM, active SMT, cgroup v2 memory control, running host
  kernel >= 6.18 (the role installs the signed Ubuntu HWE kernel).
- An OS NVMe and a separate unused NVMe >= 268435456000 bytes (250 GiB).
  Pin the chosen data disk by `/dev/disk/by-id/`. Multiple eligible disks,
  provider RAID, or existing filesystems require a reviewed layout decision.
- `shared` networking preserves the host's existing network configuration.
  Confirm the default-route interface and AF_XDP driver behavior. Do not silently
  enable `force_xdp_copy`, replace existing XDP programs, or change the host's
  uplink to bypass a failure. Bonding needs separate network details and a
  working console; the inherited inventory flag is not evidence of console access.
  A provider-configured LACP bond is different from the role's active-backup
  template. `shared` can preserve an existing bond, but that alone does not
  validate AF_XDP packet flow. Linux documents native XDP support for 802.3ad
  ([bonding FAQ](https://www.kernel.org/doc/html/latest/networking/bonding.html#what-bonding-modes-support-native-xdp));
  validate the actual kernel, driver, socket binding, and guest networking before
  admission. Do not change the provider's LACP configuration without resolving
  its switch-side requirements.
- Production defaults to unencrypted ZFS (`none`). Optional `luks-tpm2` needs
  UEFI Secure Boot, TPM2, a protected recovery passphrase and header backup, plus
  a tested console recovery path.

The production inventory enables an OOB password for the existing non-root
`ubuntu` user. The access role checks that the user exists before configuring
it; it does not bootstrap a root-only host. Decide whether to provision the
normal operator account or use another existing non-root account. Keep initial
SSH key access working while testing the operator and console accounts.

## Profiles and capacity

Read `cmd/simcity-node/internal/nodeapp/profiles.go`, `providers.go`, the
production inventory, and the deployed control-plane scheduler before sizing.
At revision `6061b3f6`, the inventory defines:

| Profile | vCPU | Base RAM (MiB) | Disk budget (MiB) | Ratio |
|---|---:|---:|---:|---:|
| `1vcpu` | 1 | 1024 | 10240 | 5 |
| `2vcpu` | 2 | 2048 | 10240 | 1 |
| `4vcpu` | 4 | 4096 | 10240 | 1 |

These ratios divide resource budgets, not VM counts. Default governed CPU is
`physical cores * 4 - 8`; governed RAM is host MiB minus 12288. The allocator
takes 95% of governed CPU, RAM, and available disk, divides each budget by the
profile weights, and sets slots to the smallest whole number supported by its
three shares. Each profile's warm target rounds 95% of its slots. A profile
whose share cannot fit one slot prevents startup.

Profile shares cannot borrow from each other when calculating slots. A
CPU-bound 5:1:1 split therefore approximates 20:2:1 VM counts before rounding.
Actual counts depend on RAM and disk too. The disk input is governed available
capacity, not the raw device size. Use live ZFS/governor data after installation
to verify the estimate.

Discuss the expected workload mix, oversubscription, host memory headroom,
and desired larger shapes before changing weights or shapes. Account for ZFS
ARC, the Go runtime, and template tmpfs when judging the 12 GiB reserve. Base
profile RAM is not necessarily the maximum guest RAM: memory can grow, and the
control plane's warm-profile matching must agree with the node's configuration.
Keep host-specific overrides scoped to the new host unless fleet-wide tuning
is explicitly requested.

Snapshot compatibility hashes include CPU feature class, architecture, Cloud
Hypervisor, kernel, initramfs, and image. Different CPU features may create a
separate snapshot compatibility group even with identical artifacts. Validate
placement/restore eligibility; do not promise cross-node resume just because
new sandbox creation succeeds.

## Access needed by phase

| Phase | Access |
|---|---|
| Inspect hosts | Forwarded 1Password SSH agent, an accepted key for each host, and root or sudo |
| Inspect control plane | Odin `AWS_PROFILE=prod` SSO for account `836356947314` and the explicit production EKS context |
| Provision/recover | Provider console access; OOB password stored in the team password manager |
| Use host SOPS secrets | Production KMS encrypt/decrypt access through `secrets-encryption-role`; SSO login alone does not prove this permission |
| Enroll | Authenticated production Admin API access, or an operator-issued single-use token bound to the new machine ID |
| SDK E2E | Production test-workspace signing key in a mode-0600 temporary file |

The repo's `.sops.yaml` defines production KMS recipients. Verify decryption
without printing plaintext, e.g. redirect `sops --decrypt` to `/dev/null` for an
existing encrypted host file. Do not retrieve unrelated cluster secrets or ask
the user to paste private keys, passwords, signing keys, or bootstrap tokens
into chat.

The monorepo Admin API exposes
`POST /admin/v1/compute/nodes/{machineID}/bootstrap-tokens`, with authenticated
Clerk or Basic admin access. The checked source creates a machine-bound,
single-use token valid for 24 hours. It currently auto-approves valid bootstrap
enrollment; verify the deployed behavior. Token delivery can make the node
eligible for customer placement, so treat enrollment as the admission step.
Do not issue tokens during investigation or request the control-plane signing
root key.

## Prepare and execute onboarding

1. Present observed hardware/layout, exact target disk, provider/console
   status, proposed hostname, profiles, network settings, artifact revision,
   and remaining access gaps. Distinguish confirmed facts from unknowns.
2. Prepare the host entry under `prod` / `simcity_nodes` and its encrypted
   host secrets in a dedicated `jj` workspace. Build or select the exact
   approved complete artifact set; hash it and compare with the existing fleet.
   Validate the bundle, syntax, and task lists locally. These steps do not
   enroll the host.
3. When provisioning is authorized for that host and disk, run the documented
   first-install sequence with explicit `-i inventories/prod/hosts.yml` and
   `--limit <new-host>` on every command: preflight, then storage with
   `simcity_storage_initialize=true`, then the full play without that override.
   Keep the console available across kernel reboot and storage setup. Never
   persist the initialization override in shared inventory.
4. Omit the bootstrap token while preparing the node. With no stored
   credentials, the service waits for `/run/simcity/bootstrap-token`. Review
   validation results accordingly: a waiting service is not proof of readiness.
   First-install offline workload checks, if requested, must run before the
   service's first start; `client check` also creates workloads and needs test
   authorization. Arrange validation/admission order for the chosen revision.
5. Read the installed node's machine ID. Once enrollment is authorized, issue
   the bound token and deliver it through the supported encrypted Ansible
   enrollment path or the documented root-owned mode-0600 runtime token file.
   Verify token deletion and protected stored credentials. Preserve credentials
   on subsequent runs; do not force enrollment.
6. Verify Iroh connection, fresh READY heartbeats, governed capacity, warm
   slots per profile, ZFS/mount health, and artifact hashes. Run the authorized
   bounded SDK E2E and prove placement on the new node. Do not drain unrelated
   nodes just to force test placement. Clean up test workloads and verify the
   host before admitting broader use if an admission gate is available.
7. Verify idempotence and the agreed first-install reboot/recovery check while
   the new node is empty or drained. Recheck before any later full play: its
   kernel/Cloud Hypervisor phases differ from routine `--tags deploy` updates.
   Update fleet documentation with verified address, name, and machine ID only
   after successful enrollment. Record exact progress if auth blocks the work.

## Candidate inspected 2026-10-02

`66.165.235.34` is a candidate, not an enrolled third production node. Recheck
these dated observations before provisioning:

| Item | Observed |
|---|---|
| Login / hostname | `root@66.165.235.34`; `compassionate-austin` |
| OS / kernel | Ubuntu 24.04.4 amd64; `6.8.0-146-generic`, below the role minimum |
| CPU | AMD EPYC 7452; 32 physical cores, 64 threads; SMT on; `/dev/kvm` present |
| Memory | 515629 MiB total (nominal 512 GiB); 8 GiB swap |
| OS disk | `/dev/nvme1n1`, Kingston 4.096 TB, serial `50026B7686CE64A7`; root on partition 3 |
| Proposed data disk | `/dev/disk/by-id/nvme-KINGSTON_SKC3000D4096G_50026B7686CE654F` -> `/dev/nvme0n1`, 4.096 TB; no partitions or `wipefs --no-act` signatures |
| Network | `bond0`, `66.165.235.34/30`, gateway `66.165.235.33`; 802.3ad LACP, layer2+3 hash |
| Members | `enp1s0f0` and `enp1s0f1`, both 10 Gb/s, `ixgbe`, 63 combined queues each |
| DNS | `66.96.80.43`, `66.96.80.194` via systemd-resolved |
| Existing runtime | No Simcity binary, unit, config, credentials, or data directory; no running Simcity/Cloud Hypervisor process |
| Network attachments | No XDP/TC programs reported by `bpftool net show`; UFW inactive; no nftables tables reported |
| Operator account | `ubuntu` exists, but the forwarded key could not log in as `ubuntu`; root key login works |
| Boot issues | `first-boot-custom.service` terminated by SIGTERM; networkd wait-online timed out; causes need review before first reboot |
| Provider / console | ARIN registers the IP range to Hivelocity Ventures Corp; service account/datacenter unconfirmed; user does not currently have console access |

Observed OS machine ID: `efbe6a6f85cf4184b261b4493de31e60`. Confirm with the
installed Simcity CLI before issuing a token. ED25519 host fingerprint accepted
on first use: `SHA256:ojeAWEzpNPjs5gD5wT7Twnk3vRQQ8PQruOSamloL6XE`.
IP registration source: [ARIN RDAP](https://rdap.arin.net/registry/ip/66.165.235.34).
This establishes the network registrant, not the physical datacenter or who
controls the server's provider account.

Both existing production nodes were active and locally READY, with healthy ZFS
and empty workload lists. They use EPYC 7443P CPUs (24 cores, 48 threads),
257589 MiB RAM, kernel `7.0.0-28-generic`, and the 5:1:1 profiles above. Each
reported total slots 59/5/2 and warm slots 56/5/2. Production EKS simcityd-0/1/2
and the inspected App API pods were running. This does not substitute for an
authenticated live Admin API fleet inventory before admission.

With unchanged defaults, the candidate would have 120 governed vCPUs and
503341 MiB governed RAM. Assuming sufficient governed disk space, CPU limits
imply total slots **81/8/4** and warm targets **77/8/4**. This is a sizing estimate,
not a benchmark or guarantee; verify after ZFS setup. Discuss CPU
oversubscription and memory-heavy demand before changing profiles. Its CPU
generation differs from the existing nodes, so snapshot interoperability is
unverified.

The inspected `simcity-production-rollout-70` workspace was based on `6061b3f6`
with modified generated artifacts. Its node and probe matched both live nodes:

```text
node   e9bf91685f12dfa9084348878bc84a6cff93125f56349106b224e79ae8854868
probe  c16b1f78aafce4d4a94c266514fdd711b043c70f48b51620cfdbb50a70cd14cc
CH     448af3d4e59b22c2987f7df94c213ad40fb53a10d437e42b5ee6c4fce7c29ecc
```

However, live EROFS was
`e2c2fb128cf2ebb0a0055711ba132f78448a782cf71b05ef72ca31123d0c6972`, whereas
the local image was
`a96495aba60ca8d251aa7b2e5a58bf59eb2b06caf5630ff1830be416fa38e91b`.
Resolve the complete intended artifact set before onboarding; do not assume
the workspace's image is the one running in production.

Root SSH, Odin production AWS/EKS access, and SOPS decryption of an existing
production host file all worked. Still needed for provisioning/testing: provider
console/rescue access (or an available operator), the new host's OOB secret,
machine-bound enrollment token via the Admin API, and a production test-workspace
signing key (`/tmp/simcity-prod-sdk.env` was absent). Neither provisioning nor
enrollment was performed during this inspection.
