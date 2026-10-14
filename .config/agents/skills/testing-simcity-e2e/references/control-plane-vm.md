# Default: control-plane VM on the dev box

This runs the control plane and SDK in a separate OS on the dev box. The node
and sandbox KVM guests remain on the bare-metal host; no nested KVM is needed.
SSH is for management/transfers, not enrollment, S3, or SDK traffic. Iroh still
uses its normal discovery/relay behavior and may need internet access.

## Inventory and allocate the namespace

On the dev box, inspect `free -h`, `df -h /`, `zfs list`, `ip -brief addr`,
`ip route`, `nft list ruleset`, `bpftool net show`, and existing Simcity/Cloud
Hypervisor processes and services. Verify `/dev/kvm`, `/dev/vhost-net`, and the
installed Cloud Hypervisor's options. The proven version was v53.0 with qcow2
and firmware support. Do not stop unrelated VMs or replace an occupied NIC.

Choose and save run values in a protected manifest. Example host-shell values:

```sh
E2E_ID=$(date -u +%m%d%H%M%S)
VM_UNIT="simcity-cp-vm-$E2E_ID"
VM_ROOT="/var/lib/$VM_UNIT"
TAP="sc-$E2E_ID"                     # Linux interface names: at most 15 bytes
NFT_TABLE="simcity_cp_vm_$E2E_ID"
HOST_CIDR=10.231.75.1/30
VM_IP=10.231.75.2
VM_MAC=02:75:00:14:00:02
UPLINK=enp97s0f0
```

These addresses/MAC/uplink are examples from the successful run. Verify the
subnet, route, MAC, names, and ports are unused. Also check the VM's Docker
subnet does not conflict. Use a different subnet consistently when needed.

The validated VM had 8 vCPUs, 20 GiB RAM, and a sparse 100-GiB qcow2 disk.
Its host cgroup had `MemoryMax=24G`, `MemorySwapMax=0`, and `CPUQuota=800%`.
Leave host RAM/CPU for the sandbox node and existing processes. Recalculate
the node's reserve after adding this VM; see [node sizing](dev-box.md).

Create the owned VM directory with mode `0700`, owned by the dev-box login
user. Before networking changes, save `sysctl -n net.ipv4.ip_forward` in
`$VM_ROOT/original-ip-forward` and capture the current routes/nftables state.
Prepare a scoped cleanup script on the host before launching anything, following
the cleanup section below. A partial setup failure also needs that cleanup.

## Prepare the boot disk and cloud-init seed

On Odin, obtain an Ubuntu 24.04 amd64 cloud image from
`https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`.
Verify it against that publication's `SHA256SUMS` and record the actual hash;
`current` is mutable. The tested UEFI firmware came from Cloud Hypervisor's
EDK2 release `ch-97eeb7b09`:

```text
https://github.com/cloud-hypervisor/edk2/releases/download/ch-97eeb7b09/CLOUDHV.fd
sha256: dc2fc8f0e43b96712d9fccc52a3a590769606412b3e1bc911d217addd3bef624
```

Create a per-run copy named `root.qcow2`, then use `qemu-img resize root.qcow2
100G`. `nix shell nixpkgs#qemu-utils nixpkgs#cdrtools` provides the preparation
tools on Odin; they need not be installed on the bare-metal host.

Generate a disposable Ed25519 key on the dev box inside `$VM_ROOT` with an
empty passphrase. Its private half stays there. Transfer only its public key
to Odin for the seed. Do not copy/forward the Mac 1Password key or agent.

Create these three seed files with the selected run values. Substitute the
generated **public** key into `user-data`:

```yaml
#cloud-config
hostname: simcity-control-e2e
users:
  - name: ubuntu
    groups: [adm, sudo, docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - GENERATED_DISPOSABLE_SSH_PUBLIC_KEY
ssh_pwauth: false
package_update: true
packages: [docker.io, docker-compose-v2, ca-certificates, curl, jq]
write_files:
  - path: /etc/systemd/system/docker.service.d/e2e-limits.conf
    content: |
      [Service]
      MemoryMax=20G
      MemorySwapMax=0
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, docker]
  - [touch, /var/lib/control-e2e-ready]
```

`network-config` for the example subnet:

```yaml
version: 2
ethernets:
  eth0:
    match:
      macaddress: "02:75:00:14:00:02"
    set-name: eth0
    addresses: [10.231.75.2/30]
    routes:
      - to: default
        via: 10.231.75.1
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
```

`meta-data` must have a unique `instance-id` for this run and the intended
`local-hostname`. Build the seed:

```sh
mkisofs -output seed.iso -volid cidata -joliet -rock \
  user-data meta-data network-config
```

Transfer `root.qcow2`, `seed.iso`, and `CLOUDHV.fd` into the owned VM directory.
Check transfer hashes. Do not reuse another run's disk or SSH private key.

## Bring up the routed TAP and VM

On the dev box, ensure the owned TAP/table/unit do not already exist. Create
the TAP and a narrowly scoped outbound NAT rule. **The NAT port range must not
overlap the node's AF_XDP sandbox NAT range** (validated: VM 8000–11999,
sandbox 16384–65535). Otherwise return packets can be claimed by AF_XDP.

```sh
sudo ip tuntap add dev "$TAP" mode tap
sudo ip addr add "$HOST_CIDR" dev "$TAP"
sudo ip link set "$TAP" up
sudo nft -f - <<NFT
table ip $NFT_TABLE {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $VM_IP oifname "$UPLINK" meta l4proto { tcp, udp } masquerade to :8000-11999
    ip saddr $VM_IP oifname "$UPLINK" ip protocol icmp masquerade
  }
}
NFT
sudo sysctl -w net.ipv4.ip_forward=1
```

The explicit TCP/UDP match is required for masquerade with a port range. Keep
existing nftables rules intact; do not flush the ruleset. If an existing forward
policy blocks this subnet, inspect it and add only the scoped rules needed.

```sh
sudo systemd-run --unit="$VM_UNIT" \
  --property=MemoryMax=24G --property=MemorySwapMax=0 \
  --property=CPUQuota=800% --property=TimeoutStopSec=30s \
  /usr/local/bin/cloud-hypervisor --cpus boot=8 --memory size=20G \
  --firmware "$VM_ROOT/CLOUDHV.fd" \
  --disk path="$VM_ROOT/root.qcow2",image_type=qcow2 \
         path="$VM_ROOT/seed.iso",readonly=on,image_type=raw \
  --net tap="$TAP",mac="$VM_MAC" \
  --api-socket "$VM_ROOT/api.sock" --console off \
  --serial file="$VM_ROOT/serial.log"
```

Inspect the serial log if boot fails. From the dev box, connect with the
disposable key and a per-run known-hosts file:

```sh
ssh -i "$VM_ROOT/guest-key" -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$VM_ROOT/known_hosts" "ubuntu@$VM_IP"
```

Verify `cloud-init status` is done, the ready marker exists, Docker/Compose
work, Docker's actual memory/swap limits are set, and DNS/HTTPS work. Record
the host and VM `/proc/sys/kernel/random/boot_id` to prove separate kernels.
Do not silently move the control-plane containers onto the bare-metal host.

## Run the stack and node

Follow [control-plane setup](control-plane.md). Transfer the run bundle and
runtime closures into the VM, typically under `/opt/simcity-e2e` and
`/nix/store`. All Compose bind sources must exist there. Start the control
plane, SDK app, local S3, and h2c proxy inside the VM.

The node's `control_plane_url` is the routed proxy URL, for example
`http://10.231.75.2:28176`. S3 presigned URLs also use the routed VM address.
There is no `ssh -R` for either service. Use the dev-box-local SSH key to move
the fresh bootstrap token from VM to the owned node state directory.

Install/start the node using [the dev-box reference](dev-box.md). Check its
heartbeat/capacity before running SDK assertions. Launch the SDK test with a
bounded VM-local systemd unit, then disconnect the management SSH command and
poll its log/result. Enrollment and test progress must not depend on an SSH
tunnel remaining open. A relay-selected Iroh connection is valid coverage;
do not report a direct path unless you observed one.

## Cleanup and optional retention

Save small redacted evidence on Odin before destroying the VM. Destroy SDK
workloads/snapshots, then clean the node and owned sandbox guests/ZFS/BPF state
per the dev-box reference. Inside the VM, run the exact project's
`docker compose ... down --volumes --remove-orphans`, stop the proxy, and
verify no matching containers/volumes remain.

The host-owned cleanup script should then:

1. Stop the exact `$VM_UNIT` and verify its Cloud Hypervisor process is gone.
2. Delete only the recorded nftables table and TAP, if created.
3. Restore the saved `net.ipv4.ip_forward` value (do not hardcode `0` for a host
   that started at `1`). Preserve unrelated forwarding users/rules.
4. Remove only the owned VM directory, including disk, seed, API socket, and
   disposable SSH private key, after teardown has succeeded.
5. Verify the VM/node services and owned datasets/BPF pins/TAP/table are absent,
   uplink addressing is intact, and memory/disk headroom has returned.

Keep enough ownership state to resume cleanup if it fails partway through.
Remove Odin's temporary transfer bundles and clean source workspaces too.

If the user explicitly retains the control-plane VM, clean the node first and
arm a root systemd timer **on the dev box** for at most six hours. It must call
the already-prepared scoped cleanup script with saved run parameters and work
without the forwarded agent. Verify the timer is active and report UTC expiry,
resources, and cleanup command. Cancel it after earlier manual teardown.
