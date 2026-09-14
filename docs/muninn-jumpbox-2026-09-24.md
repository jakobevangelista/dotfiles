# Temporary Muninn jump-box resources

Applied and verified on 2026-09-24 at 17:51 UTC for Kubernetes and Datadog
access while the main coding session stays on Odin. The installed launcher
specifies 4 GiB and two vCPUs; the live host cgroup enforces a 6 GiB memory
ceiling, 1 GiB swap ceiling, and a 200% CPU quota. Systemd unit validation
passed. Muninn successfully booted with the corrected network queue setting
and was left running. SSH, two guest CPUs, and 3.8 GiB usable guest memory
were verified at 17:59 UTC.

This profile is for Tailscale, SSH, kubectl, and Pup. As of 2026-09-26, Jakob
has deferred resource increases. The restoration commands below are for a
later requested increase before heavier builds or development stacks.

| Resource | Temporary jump box | Original workstation |
| --- | --- | --- |
| Guest RAM | 4 GiB | 20 GiB |
| Guest vCPUs | 2 | 12 |
| Whole VM stack MemoryHigh | 5 GiB | 21 GiB |
| Whole VM stack MemoryMax | 6 GiB | 23 GiB |
| Whole VM stack MemorySwapMax | 1 GiB | 8 GiB |
| Whole VM stack CPU quota | 200% (two CPUs' time) | No quota |

The existing CPU affinity and supervised VM/share services are retained. Disk
queue count is reduced from four to two. The network retains four queues to
match the existing multiqueue TAP; reducing that to two caused the first boot
attempt to fail before the guest started. Guest disk contents and
authentication state are preserved.

After boot, the old `simcity-image-benchmark` Docker containers automatically
restarted. At Jakob's request, those containers and their unused project
networks were removed. No Docker containers remain; saved images and volumes
were retained on disk. Docker's service and socket were also stopped for this
session; their normal boot configuration is unchanged. To use Docker again,
run `sudo systemctl start docker.socket docker.service` inside Muninn.
After cleanup and stopping Docker, the guest used about 477 MiB RAM with
3.4 GiB available. Odin had about 21 GiB available, the whole VM slice used
about 4.2 GiB, and its memory-pressure/limit/OOM event counters were zero.
These are idle observations, not a workload capacity test.

Work-tailnet enrollment also succeeded: Muninn reported `Running`, online,
and tailnet `inngest.com` / `tail2dd48.ts.net`, with address `100.64.220.44`.
Odin remained on the personal tailnet. SSH through Muninn's private address
`10.88.0.10` continued to work. Subnet-route acceptance was subsequently
enabled to reach the Ashburn IPv6 API networks. After separate guest AWS and
Cognito logins, authenticated deployment reads passed against AWS EKS,
NetActuate, and Rackspace. Odin remained on the personal tailnet.

The guest Nix configuration and login helper enable subnet routes. On
2026-09-24, a guest manifest was built and selected at `/etc/muninn/manifest.json`
with Jakob's sudo command, without activating unrelated Odin changes:

- Selected: `/nix/store/90blq9kasvwrgzpgyrzr4rikr8a0i13s-muninn-manifest.json`
- Previous: `/nix/store/m1ka8iiv4naj95sm0db2waccx0bcgh26-muninn-manifest.json`
- GC root: `/home/jakob/.local/state/muninn/work-access-manifest-2026-09-24`

That selection is historical; see [the work-access activation record](muninn-work-access.md#verified-setup-2026-09-26)
for the newer selected manifest and live user environment.

The running guest received `tailscale set --accept-routes=true` immediately;
the selected manifest supplies that setting on the next VM boot. This boot
selection was verified but a full VM restart was not required or tested in
this session. Future normal Nix deployments derive the manifest from the
updated source. Resource overrides and their restoration remain as below.

## Apply on Odin

Muninn must be stopped. This command installs the resource overrides but does
not start the VM:

```sh
sudo bash /home/jakob/dotfiles/scripts/muninn-jumpbox.sh apply
```

Check the actual settings at any time:

```sh
bash /home/jakob/dotfiles/scripts/muninn-jumpbox.sh status
```

After boot, inspect actual host/guest memory consumption and any automatically
restarted Docker workloads before relying on it as an access machine.

To refresh this profile (including the network-queue correction) and start a
stopped Muninn with one command:

```sh
sudo bash /home/jakob/dotfiles/scripts/muninn-jumpbox.sh start
```

## Restore full workstation resources on Odin

Finish any guest work, then run:

```sh
muninn stop
sudo bash /home/jakob/dotfiles/scripts/muninn-jumpbox.sh restore
muninn start
```

Restoration removes only these runtime overrides. It does not rebuild NixOS
or alter the VM disk. The original allocation is 20 GiB and 12 vCPUs unless
the underlying Nix configuration has since changed.

**An Odin reboot also clears these overrides automatically.** A Muninn
stop/start by itself keeps them. Muninn remains manual-start after host reboot.

## Implementation and verification

Runtime files:

- `/run/muninn-jumpbox/launch`
- `/run/systemd/system/muninn.service.d/90-jumpbox.conf`
- `/run/systemd/system/muninn.slice.d/90-jumpbox.conf`

The script derives the temporary launcher from the installed Nix launcher and
refuses to apply if its expected arguments have changed. It preserves the
existing lifecycle, networking, shares, and state disk. No permanent Nix
resource defaults are changed.
