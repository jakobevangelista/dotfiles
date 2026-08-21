---
name: testing-simcity-staging-e2e
description: "Deploys and tests Simcity candidates on staging bare-metal nodes through the Simcity repository's Ansible bundle and the staging Inngest API. Use for staging validation of Simcity node, boot bundle, rootfs, networking, packages, SDK, or REST changes."
compatibility: "Requires a Simcity checkout with infra/ansible, SSH through Jakob's MacBook, staging credentials, a local inngest-js checkout on the Mac, and kubectl access to staging EKS."
---

# Testing Simcity Against Staging

Test the real staging path:

```text
local SDK tarball on MacBook
            │
            ▼
https://api.inngest.net
            │ Iroh
            ▼
staging Simcity node ──▶ Cloud Hypervisor/KVM guest
```

Use the Simcity repository's `infra/ansible` bundle for node deployment. Do
not hand-copy binaries, rewrite `/etc/simcity/node.yaml`, or manually replace
systemd units when the bundle supports the change. This is not a general
Ansible workflow: the repository bundle owns Simcity artifacts, inventories,
configuration, service lifecycle, checksums, and validation.

## Topology

Verify all values before use.

| Role | Address/path |
|---|---|
| MacBook jump/test host | `100.107.110.76` |
| Latitude staging node | `ubuntu@103.106.59.67` (`latitude-compute-1`) |
| OVH staging node | `ubuntu@51.222.46.206` (`ovh-compute-1`) |
| Dev box in staging inventory | `ubuntu@51.222.105.190` (`ovh-local-1`) |
| Staging Kubernetes context | `arn:aws:eks:us-east-2:909933634258:cluster/main` |
| Staging namespace | `inngest` |
| Staging API | `https://api.inngest.net` |
| Staging ingest | `https://stage.inn.gs` |
| Simcity deployment bundle | `<simcity-checkout>/infra/ansible` |
| Mac SDK checkouts | `/Users/jakobevangelista/inngest-work/inngest-js*` |

The node SSH keys live on the Mac. Reach nodes through it:

```sh
ssh -o BatchMode=yes 100.107.110.76 'hostname; whoami'
ssh 100.107.110.76 "ssh -o BatchMode=yes ubuntu@103.106.59.67 'hostname'"
ssh 100.107.110.76 "ssh -o BatchMode=yes ubuntu@51.222.46.206 'hostname'"
```

## Safety boundaries

- Start read-only. Inventory Kubernetes and every staging node before rollout.
- The staging inventory also contains the dev box. **Always pass an explicit
  `--limit latitude-compute-1` or `--limit ovh-compute-1`.** Never deploy to
  the unscoped `simcity_nodes` group.
- Get explicit approval before any play that restarts a node, swaps artifacts,
  clears runtime state, changes networking/storage, or reboots a host.
- Roll out one node at a time. Confirm no active workloads immediately before
  each candidate deployment.
- Preserve `/var/lib/simcity-node/control-plane-credentials.json`; routine
  updates do not require re-enrollment.
- Never set `simcity_force_enrollment`, `simcity_storage_initialize`,
  `simcity_kernel_upgrade_drained`, or
  `simcity_cloud_hypervisor_upgrade_drained` unless that exact operation is
  intended, investigated, and approved.
- Do not run the full untagged playbook for a node/image candidate. It owns
  kernel, storage, networking, access, Cloud Hypervisor, and enrollment.
- Never print signing keys, bootstrap tokens, SOPS values, or AWS credentials.
- Build and deploy from the intended clean Simcity revision. This repo uses
  `jj`; use a dedicated workspace when the current checkout has other work.

## 1. Inspect the candidate and deployment bundle

From the intended Simcity checkout:

```sh
jj status
jj log -r '@ | @-' --no-graph -n 2
cd infra/ansible
sed -n '1,180p' inventories/staging/hosts.yml
ansible-playbook -i inventories/staging/hosts.yml site.yml --syntax-check
tests/check.sh
```

Confirm the inventory maps only the expected candidate hosts and uses:

```text
simcity_control_plane_url: https://api.inngest.net/
simcity_node_local_path: <checkout>/bin/simcity-node-amd64
simcity_guest_probe_local_path: <checkout>/bin/guest-ebpf-probe
simcity_local_image_paths: [<checkout>/artifacts/overlay.erofs]
simcity_default_image_url: file:///var/lib/simcity/images/overlay.erofs
```

Inspect `site.yml`, `roles/simcity/tasks/node.yml`, and the `deploy` task list.
The deploy tag must only discover the uplink and update/validate the node,
guest probe, EROFS images, node config, and service unit:

```sh
ansible-playbook -i inventories/staging/hosts.yml site.yml \
  --tags deploy --limit latitude-compute-1 --list-tasks
```

Stop if kernel, storage, host networking, Cloud Hypervisor, access, or forced
enrollment tasks appear.

## 2. Inspect staging before changes

If later SSH sessions need staging AWS credentials, ask Jakob to run this on
the Mac without exposing values:

```sh
aws-vault exec stage -- sh -c '
  umask 077
  env | grep "^AWS_" > /tmp/amp-stage-aws.env
  aws sts get-caller-identity >/dev/null
'
```

Then inspect staging health:

```sh
ssh 100.107.110.76 '
  set -a; . /tmp/amp-stage-aws.env; set +a
  kubectl --context arn:aws:eks:us-east-2:909933634258:cluster/main \
    -n inngest get deploy,statefulset,pods -o wide
'
```

On each real staging node, record:

```sh
sudo systemctl is-active simcity-node
sudo /usr/local/bin/simcity-node client list --json
sudo /usr/local/bin/simcity-node --config /etc/simcity/node.yaml machine-id
readlink -f /usr/local/bin/simcity-node
sudo sha256sum /usr/local/bin/simcity-node /usr/local/bin/guest-ebpf-probe
sudo sha256sum /var/lib/simcity/images/overlay.erofs
sudo zpool status -x simcity
sudo journalctl -u simcity-node -n 100 --no-pager
```

Treat `client list --json` as the workload source of truth. Correlate any old
entries with journald before deciding whether they are stale. Do not infer a
drained node solely from `ps`.

## 3. Build and validate a matched artifact set

Do not deploy repository-stored artifacts or run `make build-amd64` alone.
Despite older README wording, `build-amd64` only builds the node and guest
probe; it does not rebuild the boot bundle, rootfs, or kernel. A new node binary
with an old embedded initramfs can pass unit tests but fail every real guest
boot because the host and guest directive contracts differ.

From the candidate Simcity checkout, always prepare the complete candidate in
this order:

```sh
make artifacts-amd64 build-amd64
sha256sum \
  artifacts/initramfs.cpio.gz \
  artifacts/overlay.erofs \
  artifacts/vmlinux \
  bin/simcity-node-amd64 \
  bin/guest-ebpf-probe
nix shell nixpkgs#erofs-utils -c fsck.erofs artifacts/overlay.erofs
go test ./cmd/simcity-init ./cmd/simcity-node/internal/checks ./pkg/runner/...
```

Record the Simcity commit and all five hashes. `simcity-node-amd64` embeds the
kernel and initramfs, so those two artifacts must exist before building the
node. If the artifacts are built on one machine and Ansible runs on another,
transfer all three files under `artifacts/`, verify their hashes on the
controller, and rerun `make build-amd64` there so the final binary embeds the
verified kernel and initramfs with the intended build tag.

Before deploying, compare the candidate hashes with every target. Understand
every difference:

- Host/node Go-only changes normally change the node binary and perhaps probe.
- Guest `simcity-init`, boot-bundle, or kernel changes require a new embedded
  boot bundle and node binary.
- Rootfs/package changes require a new `overlay.erofs`.
- If no rootfs input changed but `overlay.erofs` differs, stop and investigate
  stale or mismatched artifacts instead of uploading it.

The current inventories configure `overlay.erofs` as both the primary image
and `simcity_smoke_image_local_path`. When its hash changes, the role can upload
the same large file twice. Expect this until the Ansible role is fixed; do not
mistake the duplicate smoke-image transfer for a second required runtime image.

## 4. Deploy one canary with Simcity Ansible

First inspect the exact proposed run:

```sh
cd <simcity-checkout>/infra/ansible
ansible-playbook -i inventories/staging/hosts.yml site.yml \
  --tags deploy \
  --limit latitude-compute-1 \
  --check --diff
```

Review every reported change. Because check mode cannot prove runtime restart
behavior, do not treat it as the deployment.

After explicit approval and a fresh empty workload check, deploy exactly one
node:

```sh
ansible-playbook -i inventories/staging/hosts.yml site.yml \
  --tags deploy \
  --limit latitude-compute-1
```

The playbook is `serial: 1`, hashes controller artifacts before host changes,
verifies destination hashes, renders the existing config shape, restarts the
service when needed, and runs tagged validation.

Run the same command a second time. Require no unexpected changes. Then verify:

```text
active artifact hashes match the candidate
service is active without a restart loop
node reconnects to the staging control plane over Iroh
heartbeats report READY
fresh warm capacity exists
client list reports no leaked workload
```

Do not deploy the second node until the canary passes the real SDK E2E.

## 5. Pack the intended SDK on the Mac

Use the exact SDK revision needed by the change, not a registry package:

```sh
ssh 100.107.110.76 '
  cd /path/to/inngest-js
  jj status
  jj log -r "@ | @-" --no-graph -n 2
  pnpm install --frozen-lockfile
  pnpm run local:pack
  shasum -a 256 packages/inngest/inngest.tgz
'
```

Copy the existing SDK test app to a disposable `/tmp` directory. Install the
tarball with `pnpm add /absolute/path/inngest.tgz --save-exact`, then verify
`pnpm-lock.yaml` and `pnpm why inngest` point to that file tarball.

Configure the real staging client explicitly:

```ts
new Inngest({
  id: "simcity-staging-e2e",
  isDev: false,
  baseUrl: "https://api.inngest.net",
  middleware: [sandboxMiddleware()],
})
```

Keep credentials in a mode-0600 temporary env file. Do not print them.

## 6. Run a focused real E2E

The test must:

1. Create a real sandbox with a bounded `runningTimeout`.
2. Put the behavior under test in the earliest possible guest command.
3. Assert exit code and meaningful stdout/stderr.
4. Prove file effects with SDK download or a second command when relevant.
5. Destroy the sandbox in `finally`.

For automatic networking, make an HTTPS Git clone the first guest command and
do not invoke `udhcpc`; manual DHCP would hide the regression. For rootfs
packages, execute every requested tool. Group probes into one shell command if
the API command-rate limit is not itself under test.

Run from the disposable app:

```sh
set -a
. /tmp/simcity-staging-sdk.env
set +a
export NODE_ENV=production
pnpm exec tsx scripts/simcityStagingSdkE2E.ts
```

Correlate the sandbox ID with candidate-node journald and staging Kubernetes
logs. Prove placement went to the changed node; a pass on the unchanged node
does not validate the candidate.

## 7. Finish rollout and clean up

After the canary passes, repeat inventory, empty-workload check, Ansible deploy,
idempotence run, health checks, and focused E2E for the second staging node.

Always remove disposable SDK apps, credential handoff files, and temporary
logs. Confirm both staging nodes are active, READY, and have no leaked test
workloads. Report retained candidate artifacts explicitly.

Final reporting must include Simcity and SDK commits, artifact/tarball hashes,
Ansible inventory/limits used, nodes changed, placement evidence, assertions,
sandbox IDs, cleanup state, and any layer not validated.
