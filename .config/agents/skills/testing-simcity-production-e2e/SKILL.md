---
name: testing-simcity-production-e2e
description: "Safely rolls out and tests Simcity candidates on production bare-metal nodes through the Simcity repository's Ansible bundle and the production Inngest API. Use for production Simcity rollout inspection, canary deployment, SDK E2E validation, networking, rootfs, package, or node changes."
compatibility: "Requires Odin with Linux, Nix, Ansible Core, SOPS, the pinned Ansible collections, Simcity and inngest-js checkouts, production AWS SSO and kubectl access, and a 1Password SSH agent forwarded from Jakob's MacBook."
---

# Testing Simcity Against Production

Use this workflow for production rollout and real SDK validation:

```text
MacBook 1Password agent ──ssh -A──▶ Odin controller
                                      ├── Ansible/SSH ──▶ production Simcity node
                                      ├── SDK ──▶ https://api.inngest.com
                                      └── AWS CLI/kubectl ──▶ production EKS

https://api.inngest.com ──Iroh──▶ production Simcity node
                                      │
                                      ▼
                             Cloud Hypervisor/KVM guest
```

The Simcity repository's `infra/ansible` bundle is the source of truth for
production node artifacts, config, systemd lifecycle, inventories, checksums,
and validation. Do not manually recreate the rollout with `scp`, ad hoc
symlink swaps, or rewritten configuration when the bundle supports it.

## Topology

Verify these values before each operation.

| Role | Address/path |
|---|---|
| Odin build/Ansible/test controller | `jakob@100.118.239.121` |
| MacBook SSH-agent source | `jakob@100.75.136.81` |
| Production node 1 | `ubuntu@67.213.115.17` (`prod-sandbox-lat-iad-1`) |
| Production node 2 | `ubuntu@45.250.254.57` (`prod-sandbox-lat-iad-2`) |
| Node 1 machine ID | `fd355cbb62214c27bbab4337a9d970da` |
| Node 2 machine ID | `425a613b96d6404481c2f493f8002a84` |
| Production Kubernetes context | `arn:aws:eks:us-east-2:836356947314:cluster/main` |
| Production API | `https://api.inngest.com` |
| Simcity deployment bundle | `<simcity-checkout>/infra/ansible` |
| Odin SDK checkouts | `/home/jakob/inngest-work/inngest-js*` |

Private node keys stay in the MacBook's 1Password SSH agent. Start the
controller session from the Mac and keep it open:

```sh
ssh -A jakob@100.118.239.121
```

In that forwarded Odin shell, publish the session's ephemeral agent socket at
a stable path. Repeat this after every Mac-to-Odin reconnect because OpenSSH
creates a new socket for each session:

```sh
forwarded_sock=$SSH_AUTH_SOCK
stable_sock=$HOME/.ssh/mac-forwarded-agent.sock
test -S "$forwarded_sock"
test "$forwarded_sock" != "$stable_sock"
install -d -m 700 "$HOME/.ssh"
ln -sfn "$forwarded_sock" "$stable_sock"
SSH_AUTH_SOCK="$stable_sock" ssh-add -l
```

Codex may have started before agent forwarding, so never rely on its inherited
`SSH_AUTH_SOCK`. Every shell tool call that runs `ssh`, `scp`, or Ansible must
set the stable socket explicitly; exports from one tool call do not carry into
the next:

```sh
stable_sock=/home/jakob/.ssh/mac-forwarded-agent.sock
test "$(hostname)" = odin
test -S "$stable_sock"
command -v ansible-playbook sops aws kubectl
SSH_AUTH_SOCK="$stable_sock" ssh -o BatchMode=yes \
  ubuntu@67.213.115.17 'hostname; whoami'
SSH_AUTH_SOCK="$stable_sock" ssh -o BatchMode=yes \
  ubuntu@45.250.254.57 'hostname; whoami'
```

Run the rest of this workflow on Odin. Also verify `hostname`, required tools,
and direct node connectivity before using Ansible. If `test -S` fails, stop
and ask Jakob to reconnect with `ssh -A` and refresh the stable link. Do not
search `/tmp` for agent sockets. Do not copy private keys to Odin, install
1Password there, or forward the agent onward to a node.

## Non-negotiable safety rules

- Production starts read-only. Inventory both nodes, control-plane health,
  active workloads, and artifact hashes before proposing commands.
- Never stop/restart a service, deploy artifacts, destroy a workload, clear a
  pool, or alter production configuration without explicit user approval.
- Approval for inspection is not approval for deployment. Approval for one
  node is not approval for the second.
- Deploy one node at a time with an explicit `--limit`. The playbook is
  `serial: 1`, but the limit prevents accidental scope expansion.
- Immediately before each deployment, require `client list --json` to show no
  active workloads. Investigate workload creation time and most recent state.
  Do not treat age alone as permission to destroy it.
- Preserve `/var/lib/simcity-node/control-plane-credentials.json`; routine
  artifact updates do not require re-enrollment.
- Never set destructive initialization, forced enrollment, kernel drain, or
  Cloud Hypervisor drain variables for a node/image rollout.
- Use only `--tags deploy` for routine candidate artifacts. The full play owns
  kernel, storage, networking, access, Cloud Hypervisor, and enrollment.
- Do not change live config values just to make a candidate work. Compare the
  rendered config with the active config and preserve current behavior unless
  the requested change explicitly requires configuration changes.
- Never print or persist production signing keys, bootstrap tokens, decrypted
  SOPS values, or AWS session values outside mode-0600 temporary files.
- Use a clean dedicated `jj` workspace for the exact candidate revision.

## 1. Inspect production control-plane access from Odin

Authenticate the AWS CLI on Odin. Device authorization may be completed in the
MacBook browser, but credentials and Kubernetes commands remain on Odin:

```sh
aws sso login --profile prod --use-device-code --no-browser
export AWS_PROFILE=prod

account=$(aws sts get-caller-identity --query Account --output text)
test "$account" = 836356947314
```

Use the explicit production context:

```sh
kubectl --context arn:aws:eks:us-east-2:836356947314:cluster/main \
  get pods -A -o wide | grep -Ei 'simcity|app-api|executor' || true
```

If SSO expires, repeat `aws sso login` on Odin. Never export AWS credentials
to a handoff file or send them through SSH.

## 2. Inventory both production nodes

For each node, capture service state, machine ID, workload list, artifact
targets/hashes, ZFS health, relevant processes, and recent lifecycle logs:

```sh
sudo systemctl status simcity-node --no-pager
sudo /usr/local/bin/simcity-node client list --json
sudo /usr/local/bin/simcity-node --config /etc/simcity/node.yaml machine-id
readlink -f /usr/local/bin/simcity-node
readlink -f /usr/local/bin/guest-ebpf-probe
sudo sha256sum /usr/local/bin/simcity-node /usr/local/bin/guest-ebpf-probe
sudo sha256sum /var/lib/simcity/images/overlay.erofs
sudo zpool status -x simcity
sudo zfs list -r simcity
pgrep -af 'simcity-node|cloud-hypervisor' || true
sudo journalctl -u simcity-node -n 200 --no-pager
```

For every listed workload, determine:

- workload/sandbox ID;
- launch/start timestamp from journald or control-plane state;
- current node-reported state;
- most recent lifecycle operation;
- whether Cloud Hypervisor and network processes still exist.

Report this inventory and stop before destructive work. If stale workloads
need cleanup, present exact IDs and evidence and request approval.

## 3. Verify the deployment bundle and candidate

From the intended Simcity checkout:

```sh
jj status
jj log -r '@ | @-' --no-graph -n 2
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

Then validate the Simcity-specific Ansible bundle:

```sh
cd infra/ansible
ansible-galaxy collection install -r requirements.yml
tests/check.sh
ansible-playbook -i inventories/prod/hosts.yml site.yml --syntax-check
ansible-playbook -i inventories/prod/hosts.yml site.yml \
  --tags deploy --limit prod-sandbox-lat-iad-1 --list-tasks
```

The production inventory must map only:

```text
prod-sandbox-lat-iad-1 -> 67.213.115.17
prod-sandbox-lat-iad-2 -> 45.250.254.57
simcity_control_plane_url -> https://api.inngest.com/
```

The deploy task list may discover the active uplink and update the node,
guest probe, EROFS image, config, and unit. Stop if it includes kernel,
storage, host network, Cloud Hypervisor, access, or enrollment tasks.

## 4. Rehearse and deploy the first canary

Run check mode against one host:

```sh
ansible-playbook -i inventories/prod/hosts.yml site.yml \
  --tags deploy \
  --limit prod-sandbox-lat-iad-1 \
  --check --diff
```

Review the diff against the active configuration and recorded hashes. Check
mode is only a rehearsal; it does not prove restart/recovery behavior.

After explicit approval, repeat the workload query. Deploy only if it is still
empty:

```sh
ansible-playbook -i inventories/prod/hosts.yml site.yml \
  --tags deploy \
  --limit prod-sandbox-lat-iad-1
```

Run the identical command again and require idempotence. Then verify candidate
hashes, active service, Iroh reconnection, READY heartbeat, fresh warm capacity,
and an empty workload list. Preserve logs for any failure before rollback.

Rollback uses the previously recorded complete artifact set and existing
Ansible configuration. Never restore only one component of node/probe/image.

## 5. Roll out the second node

Only after the first node is healthy and any requested canary test passes:

1. Re-inspect workloads on node 2.
2. Run `--check --diff --limit prod-sandbox-lat-iad-2`.
3. Request/confirm approval for node 2.
4. Run `--tags deploy --limit prod-sandbox-lat-iad-2`.
5. Run it again for idempotence.
6. Verify hashes, Iroh, READY, warm capacity, and no workload leak.

Do not change inventory, config, or files between nodes unless investigating a
real host-specific difference.

## 6. Pack the exact SDK revision on Odin

Use the updated local SDK required by the feature, not the latest registry
package by default:

```sh
cd /home/jakob/inngest-work/inngest-js
jj status
jj log -r '@ | @-' --no-graph -n 2
pnpm install --frozen-lockfile
pnpm run local:pack
sha256sum packages/inngest/inngest.tgz
```

Create a disposable app under `/tmp`, copy in the existing SDK E2E app without
its `.git`, `.jj`, `.env`, or `node_modules`, and install the absolute tarball:

```sh
pnpm add /absolute/path/to/packages/inngest/inngest.tgz --save-exact
pnpm why inngest
```

Confirm `pnpm-lock.yaml` uses `file:` and hash the tarball. Package versions can
remain unchanged on a locally packed PR, so version text alone is not proof.

Use the real production client with no staging/dev override:

```ts
new Inngest({
  id: "simcity-production-e2e",
  isDev: false,
  baseUrl: "https://api.inngest.com",
  middleware: [sandboxMiddleware()],
})
```

Store `INNGEST_SIGNING_KEY` in `/tmp/simcity-prod-sdk.env` with mode `0600`.
Ask the user to provide it there if absent; never print it.

## 7. Write a focused production E2E

The test must create a bounded sandbox, assert the requested behavior, and
destroy it in `finally`. Keep unrelated SDK operations out of the critical
path because production can expose independent contract mismatches.

For a networking-before-ready change, make the first guest command an HTTPS
Git clone and do not manually run DHCP:

```ts
const clone = await sandbox.commands.run({
  command: [
    "/bin/sh",
    "-lc",
    "/bin/git clone --depth 1 https://github.com/octocat/Hello-World.git /tmp/hello-world && printf clone-ok",
  ],
  timeout: "60s",
});
```

For base-image validation, execute every expected binary and assert identifying
output. Group package probes into one shell command when command rate limiting
is not under test. Use absolute executable paths if the currently deployed REST
API still rejects bare or relative paths; state clearly that this does not test
path-based exec.

Avoid unrelated file upload calls in a package/network test. A production API
may return `bytesWritten` with a representation unsupported by the candidate
SDK, which should be reported separately rather than masking the requested
Simcity assertions.

## 8. Run and correlate the E2E

Before creating the sandbox, confirm both nodes are healthy and empty. Run on
Odin inside the disposable app:

```sh
set -a
. /tmp/simcity-prod-sdk.env
set +a
export NODE_ENV=production
pnpm exec tsx scripts/simcityProdSdkE2E.ts
```

Capture the sandbox ID and create duration. Search journald on both nodes for
that exact ID to prove placement, launch, guest operations, and cleanup:

```sh
sudo journalctl -u simcity-node --since '15 minutes ago' --no-pager \
  | grep '<sandbox-id>'
```

Require a clean workload teardown (`session ended`, provider teardown, and
vhost-user server stopped as applicable) and no remaining Cloud Hypervisor
process for the sandbox.

Known production behavior to account for, not hide:

- Bursting many command requests can return `429 rate_limited`; consolidate
  independent package probes and rerun only after the rate window resets.
- A failed run still must execute `sandbox.destroy()` in `finally`.
- If the REST path-validation rollout is absent, absolute paths validate
  packages/networking but not execvp-style path lookup.

## 9. Final cleanup and report

Confirm both production nodes are active, connected, READY, and report no
remaining test workloads or sandbox processes. Remove disposable SDK apps,
temporary tarball copies, and `/tmp/simcity-prod-sdk.env` when it is no longer
needed.

Report:

- Simcity commit and node/probe/initramfs/kernel/EROFS hashes;
- SDK commit and tarball hash;
- exact production inventory, tags, and host limits used;
- pre-deploy workload state and approvals;
- nodes changed and idempotence result;
- sandbox ID, placement evidence, assertions, and create duration;
- cleanup evidence on both nodes;
- unrelated API/SDK failures separately;
- any feature not actually covered by the deployed production API.
