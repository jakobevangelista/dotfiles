# Simcity Dev-Box Reference

Read this reference before configuring or cleaning up the remote node. These
values were proven on `local-compute-01`; inspect the live host before reusing
them because NIC, ZFS, and capacity details are machine-specific.

## Known-working node configuration shape

The 2026-08-07 Git/rootfs E2E used this redacted shape. Use new E2E-specific
paths and the current tunnel port. Never copy a bootstrap-token value into the
YAML.

```yaml
hostname: "remote-e2e-node"
node_agent:
  listen: "127.0.0.1:7443"
  control_plane_url: "http://127.0.0.1:18094"
  bootstrap_token_file: /run/simcity-remote-e2e/bootstrap-token
  heartbeat_interval_seconds: 5
  state_dir: /var/lib/simcity-remote-e2e/state
  restart_mode: recover
  capacity:
    memory_reserve_mb: 12288
    vcpu_per_physical_core: 4
    vcpu_reserve: 8
  runtime:
    gomaxprocs: 4
    gomemlimit_mb: 8192
  network:
    backend: afxdp
    afxdp:
      uplink_iface: "enp97s0f0"
      bpffs_root: /sys/fs/bpf/simcity-remote-e2e
      vhost_socket_dir: /run/simcity-remote-e2e/vhost
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
      socket_dir: /run/simcity-remote-e2e/cloud-hypervisor
      cgroup_root: /sys/fs/cgroup/simcity-remote-e2e-vms
  storage:
    backend: zfs
    default_image_url: "file:///var/lib/simcity/images/remote-e2e-overlay.erofs"
    zfs:
      volumes_dataset: simcity/volumes
  snapshots:
    root: /var/lib/simcity-remote-e2e/snapshots
    ttl_seconds: 3600
  pool:
    kernel_image: "file:///var/lib/simcity-e2e/boot/vmlinux"
    initramfs: "file:///var/lib/simcity-e2e/boot/initramfs.cpio.gz"
    snapshot_root: /run/simcity-remote-e2e/pool
    vsock_socket_dir: /run/simcity-remote-e2e/vsock
    template_build_concurrency: 1
    base_cid: 3000
  profiles:
    - name: "2vcpu"
      vcpu: 2
      memory_mb: 2048
      disk_mb: 10240
      slots: 1
      warm_target: 1
```

The first Git-image run briefly failed because AF_XDP autodetection did not
find an IPv4 default route through `enp97s0f0`. If that recurs, derive and set
the config's explicit `underlay_ipv4` and `underlay_peer_mac` fields from
`ip route`, `ip addr`, and `ip neigh`. Do not copy those values from another
host.

## Boundary troubleshooting

| Symptom | Likely cause | Focused fix |
|---|---|---|
| `http2: frame too large` during handshake | Node h2c client reached HTTP/1.1 API directly | Route through the h2c bridge |
| Handshake timeout | Broken reverse tunnel or h2c proxy | Check listeners on Linux, Mac, and dev box |
| No intended Iroh session | Wrong key, global key collision, or simcityd offline | Use a fresh matching secret/public pair and inspect both ends |
| `unauthorized peer` | Node credentials belong to another control plane/key | Issue a fresh token and clear only E2E node state |
| Node is ready but placement fails | Warm template is not ready | Inspect `warm_vcpu`, `warm_capacity`, and pool logs |
| `No user exists for uid 0` | Rootfs lacks UID/GID 0 identity metadata | Add conventional `/etc/passwd`, `/etc/group`, and `/root` |
| `Could not resolve host`, and guest has no routes | `eth0` is down; DNS alone is insufficient | Run `udhcpc`; track automatic networking separately |
| SDK gets 401 | Stale/missing signing key | Source it from the current API container |
| Event accepted but function never runs | Missing constraint APIs, state proxy, or app network | Start `extra` services and run app on `inngest_internal` |
| ZFS template cannot be removed | It still has allocation clones | Destroy E2E allocation clones before the E2E template |
| Host approaches OOM | Missing limits or unrelated large workload | Check every `mem_limit`, Docker `MemoryMax`, and host memory |

## Scoped cleanup

1. Destroy each SDK-created sandbox in `finally`.
2. Stop `simcity-remote-e2e.service` before the local control plane.
3. Stop only Cloud Hypervisor processes belonging to the E2E node. Use
   `pgrep -f '^/usr/local/bin/cloud-hypervisor '` because the process name is
   longer than 15 characters; identify ownership before killing anything.
4. Remove E2E allocation clones before E2E templates. Never destroy
   `simcity/volumes` wholesale.
5. Remove every bootstrap-token transfer/install copy.
6. Find both SSH tunnel PIDs by the exact chosen reverse-port arguments and
   kill only those PIDs.
7. Stop `simcity-remote-h2c-proxy.service`.
8. Tear down only the `simcity-remote-e2e` Compose project and its volumes.
9. Remove or explicitly report retained remote image/config/binary/state.
10. Forget disposable clean `jj` workspaces only after checking for changes.

Compose teardown, run from the temporary monorepo workspace:

```sh
docker compose -p simcity-remote-e2e \
  --env-file /tmp/simcity-remote-iroh.env \
  -f compose-base.yml -f compose-local.yml --profile min \
  -f /home/jakob/inngest-work/.snapshot-e2e/app/compose-e2e.yml \
  -f /home/jakob/inngest-work/.snapshot-e2e/app/compose-state-proxy-e2e.yml \
  -f /home/jakob/inngest-work/.snapshot-e2e/compose-memory-cap.yml \
  -f /tmp/simcity-remote-iroh.yml \
  down -v --remove-orphans

systemctl --user stop simcity-remote-h2c-proxy.service
rm -f /tmp/simcity-remote-iroh.env /tmp/simcity-remote-iroh.yml
```

If root-owned bind-mount files prevent workspace removal, remove only those
files with a container rather than broad `sudo rm`:

```sh
docker run --rm -v /path/to/workspace:/target debian:trixie-slim \
  rm -rf /target/tmp
```

Final checks:

```sh
docker ps -a --format '{{.Names}}' | grep '^simcity-remote-e2e' || true
docker volume ls --format '{{.Name}}' | grep '^simcity-remote-e2e' || true
ss -ltnp | grep -E '28091|18094' || true
docker compose ls
free -h
```

On the dev box, require the E2E service inactive, no matching listener, and no
matching Cloud Hypervisor process. Leave unrelated node services and Compose
projects in their prior state.
