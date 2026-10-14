# Simcity dev-box node

Use this for the real node in either control-plane topology. Inspect the live
host before reusing values: NIC, gateway, CPU count, ZFS, and existing VM
ownership are host-specific. Only replace an existing node/NIC owner when the
user has already authorized that replacement; otherwise ask before stopping it.

## Inventory and sizing

Inspect services/configs, all Cloud Hypervisor processes with full arguments,
`ip addr`, `ip route`, `ip neigh`, `bpftool net show`, `zfs list`, and the current
host RAM/CPU budget. Verify `/dev/kvm` and the node's machine ID. Old orphan
Cloud Hypervisor processes can coexist on this box; do not treat them as yours.

Use independent per-run directories for node state, snapshot data, BPF pins,
runtime sockets, cgroups, binary, and config. Create a child ZFS dataset for
this run. The lifecycle test needed a **100-GiB dataset quota**: 60 GiB was too
small for concurrent logical snapshot/clone reservations even when actual
physical data was small. Never use or destroy the parent `simcity/volumes`
dataset as disposable test storage.

Account for the control-plane VM when sizing node reserves. In the validated
128773-MiB, 24-physical-core host, an 8-vCPU/20-GiB control-plane VM required
reducing the old node RAM reserve from 98304 to 81920 MiB. With that VM present,
the old reserve rejected warm-template startup. Derive a budget from current
host availability; do not universally copy either reserve.

For the clone/resume pressure test, `vcpu_per_physical_core=1` and
`vcpu_reserve=20` on that 24-core host gave a 4-vCPU governed budget. Two warm
2-vCPU/2048-MiB guests filled it. This is a deliberate test condition, not a
production sizing recommendation or a requirement for unrelated E2Es.

## Configuration shape

Example from that pressure test, with generic owned paths. Replace every
namespace consistently for the run and verify the base CID/socket ports are
unused. In Odin mode change only the control-plane URL to the selected reverse
tunnel endpoint; use sizing appropriate to that topology.

```yaml
hostname: sandbox-node-e2e
node_agent:
  listen: "127.0.0.1:7446"
  control_plane_url: "http://10.231.75.2:28176"
  public_ipv4: "51.222.105.190"
  bootstrap_token_file: /var/lib/simcity-node-e2e/bootstrap-token
  heartbeat_interval_seconds: 5
  state_dir: /var/lib/simcity-node-e2e/state
  restart_mode: stop
  capacity:
    memory_reserve_mb: 81920
    vcpu_per_physical_core: 1
    vcpu_reserve: 20
  runtime:
    gomaxprocs: 4
    gomemlimit_mb: 2048
  network:
    backend: afxdp
    afxdp:
      uplink_iface: enp97s0f0
      underlay_ipv4: "51.222.105.190"
      underlay_peer_mac: "00:00:0c:9f:f0:01"
      bpffs_root: /sys/fs/bpf/simcity-node-e2e
      vhost_socket_dir: /run/simcity-node-e2e/vhost
      vxlan_port: 4789
      mtu: 1450
      force_xdp_replace: false
      force_xdp_copy: false
      nat_port_start: 16384
      nat_port_end: 65535
      nat_max_flows_per_workload: 1024
      egress_private_allow_cidrs: []
  vmm:
    backend: cloudhypervisor
    cloudhypervisor:
      binary: /usr/local/bin/cloud-hypervisor
      socket_dir: /run/simcity-node-e2e/cloud-hypervisor
      cgroup_root: /sys/fs/cgroup/simcity-node-e2e-vms
  storage:
    backend: zfs
    default_image_url: "file:///var/lib/simcity-node-e2e/overlay.erofs"
    zfs:
      volumes_dataset: simcity/node-e2e-volumes
  snapshots:
    root: /var/lib/simcity-node-e2e/snapshots
    ttl_seconds: 3600
  pool:
    kernel_image: "file:///var/lib/simcity-node-e2e/vmlinux"
    initramfs: "file:///var/lib/simcity-node-e2e/initramfs.cpio.gz"
    snapshot_root: /run/simcity-node-e2e/pool
    vsock_socket_dir: /run/simcity-node-e2e/vsock
    template_build_concurrency: 1
    base_cid: 14000
  profiles:
    - name: 2vcpu
      vcpu: 2
      memory_mb: 2048
      disk_mb: 10240
      slots: 2
      warm_target: 2
```

Derive explicit underlay IP/gateway MAC from live route/address/neighbour data,
not from another machine. Preserve the actual NIC/VMM backend and inspect the
selected source's config schema before adapting newer/older fields.

## Install and verify

Transfer the rebuilt node, guest probe, kernel, initramfs, and EROFS compressed
from Odin to a run-scoped staging directory; verify all five hashes there before
installation. Install the binary/probe executable, images readable, and config
and fresh bootstrap token mode `0600`. Compare token hashes without printing
the token, then remove transfer copies. Do not overwrite production-shaped
paths such as `/etc/simcity/node.yaml`.

Create the owned ZFS child dataset with the selected quota. Start a transient
service with run-specific paths, for example:

```sh
sudo systemd-run --unit="$NODE_UNIT" \
  --property=Restart=on-failure --property=RestartSec=5s \
  --property=TimeoutStopSec=30s \
  "$NODE_BINARY" --config "$NODE_CONFIG" serve
```

Verify journald shows node registration, enrollment, and connection to the
intended Iroh control plane. Record transport selection and public fingerprints
only. A transient initial heartbeat before the Iroh session exists can retry;
require actual fresh successful heartbeats, not merely an active systemd unit.

From the control-plane runtime host, inspect Postgres:

```sql
SELECT machine_id, status, last_seen,
       governed_total_vcpu, governed_used_vcpu, governed_available_vcpu,
       warm_available_vcpu, warm_capacity
FROM nodes
WHERE machine_id = 'd65f25f351114245be681fc3b1380b3d';
```

Wait for `ready` and the intended warm capacity. If an older schema uses
`warm_vcpu`, inspect `\d nodes` before adapting the query. For the 4-vCPU
pressure test, initially require total=used=4, free=0, warm=4 and fresh
heartbeat timestamps. Distinguish warm capacity from free governed capacity.

## Boundary troubleshooting

| Symptom | Check |
|---|---|
| h2c frame error | Node URL must reach the h2c proxy, not HTTP/1.1 API directly |
| Enrollment timeout in VM mode | VM health, TAP route, private-IP listener, proxy/backend health |
| Enrollment timeout in Odin mode | Exact reverse tunnel and Odin proxy listeners |
| No intended Iroh session / unauthorized peer | Fresh matching keys, CA roots, token ownership, and both services' logs |
| Pool startup rejects memory | Host availability minus reserve must cover the guest; include the control-plane VM |
| IPv4 underlay preflight failure | Verify physical NIC address/default route; stop a restart loop and inspect recovery before changing config |
| Ready node but placement fails | Warm pool, governed free/reclaimable resources, requested profile, and heartbeat freshness |
| SDK 401 or 403 | Current signing key, account overrides, positive billing-plan sandbox eligibility, entitlement cache |
| Snapshot upload fails | S3 Put/Delete readiness from the real callers, URL reachability, volume count, dataset logical quota |
| Guest DNS/HTTPS fails | Guest interface/routes and AF_XDP/NAT; do not automatically hide it with manual DHCP |
| Host pressure | VM plus container bounds, scoped log growth, disk headroom, and unrelated workload load |
| ZFS removal fails | Remaining owned guests, snapshot-export clones, allocation clones, then templates |

## Scoped node cleanup

1. Destroy SDK-created sandboxes in `finally`, delete test snapshots, and verify
   terminal/deleted records in the disposable database.
2. Stop the exact node service while its control plane is still available.
3. Stop only owned Cloud Hypervisor guests. Enumerate the node's recorded
   cgroup and runtime/config paths; match full command lines, not the truncated
   process name. Verify no owned guest remains before deleting storage.
4. If a pinned XDP link remains, detach only the link under this run's BPF root
   (for example `programs/simcity_xdp_link`), then remove owned pins. Do not
   detach unrelated programs or force-replace the uplink's owner.
5. Destroy owned `snapshot-export-*` clones, then `allocation-*` clones, then
   templates and the run's child dataset. Never destroy the parent pool.
6. Remove token copies, staging files, node config/binary/state, runtime
   sockets, and empty owned cgroups. Verify node service/guest/dataset/pin
   absence and intact physical NIC addressing.
7. Tear down the selected control plane using its topology reference. In VM
   mode this includes the VM/disk/key/TAP/NAT and saved forwarding state; in
   Odin mode it includes the exact tunnels and local Compose project.

Do not restart a service the user explicitly retired. Restore a temporarily
replaced service only when the agreed test plan calls for restoration. Preserve
other services, VMs, datasets, routes, and firewall rules throughout cleanup.
