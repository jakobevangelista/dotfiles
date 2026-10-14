---
name: using-buildkite-runners
description: Access Inngest's OVH Buildkite runner hosts and VMs from Odin using the forwarded 1Password inngest-key. Use for SSH access, locating runner hosts, and basic libvirt or guest inspection. Excludes Simcity hosts and general Docker BuildKit usage.
---

# Access Buildkite runners

Connect directly from Odin to the Ubuntu bare-metal hosts. Each host runs Buildkite runner VMs under libvirt/KVM. Use SSH user `ubuntu` and passwordless `sudo -n`; root SSH is disabled. Muninn is not needed.

## Forward the work key from the Mac

First try the existing forwarded agent. Only if it is missing or unresponsive, ask the user to run this on their Mac with 1Password unlocked and leave the session open:

```sh
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh -A -S none odin
```

On Odin, use that session's `SSH_AUTH_SOCK`. A separate Codex shell may need to discover the forwarded socket under `~/.ssh/agent/s.*.sshd.*` or, on older OpenSSH versions, `/tmp/ssh-*/agent.*`. Export the live socket path, then check it with:

```sh
timeout 10s ssh-add -l
```

Select **`inngest-key`**, not the default personal identity. Its observed comment is `jakob-goated-macbook inngest key` and its SHA256 fingerprint is `Ue9fVeyyNxSM5BbpwsngfOtELaunfJ1vLG15kDfbl1Q`. Extract only its public key from the agent so SSH can select it explicitly:

```sh
bk_pubkey=$(mktemp /tmp/buildkite-work-key.XXXXXX)
timeout 10s ssh-add -L | while IFS= read -r key; do
  if printf '%s\n' "$key" | ssh-keygen -lf - | rg -q -F 'SHA256:Ue9fVeyyNxSM5BbpwsngfOtELaunfJ1vLG15kDfbl1Q'; then
    printf '%s\n' "$key"
    break
  fi
done > "$bk_pubkey"
test -s "$bk_pubkey" && ssh-keygen -lf "$bk_pubkey"
```

If the file is empty, resolve the missing work identity before connecting. Never export the private key. With the public key selected, connect using the forwarded agent for signing:

```sh
timeout 45s ssh \
  -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 \
  -o StrictHostKeyChecking=yes -o ForwardAgent=no \
  -o IdentityAgent="$SSH_AUTH_SOCK" -o IdentitiesOnly=yes \
  -i "$bk_pubkey" ubuntu@51.222.249.132 \
  'sudo -n virsh list --all'
```

Reuse the socket and public-key file for subsequent commands in this task. Remove the temporary public-key file when finished.

## Locate the hosts

The canonical inventory on Odin is `/home/jakob/inngest-work/ansible/inventories/sites/ovh/buildkite-runners` (an INI file). Prefer it over this snapshot if it changes:

| Inventory name | Public IP | OVH label |
| --- | --- | --- |
| ovh-buildkite-xl-01 | 51.222.249.132 | cloud-ci-xl-01 |
| ovh-buildkite-xl-02 | 148.113.206.144 | cloud-ci-xl-02 |
| ovh-buildkite-xl-03 | 15.235.117.42 | cloud-ci-xl-03 |
| ovh-buildkite-xl-04 | 72.251.11.2 | cloud-ci-xl-04 |
| ovh-buildkite-xl-05 | 148.113.212.196 | cloud-ci-xl-05 |
| ovh-buildkite-xl-06 | 148.113.212.58 | ns5026060.ip-148-113-212.net |
| ovh-buildkite-xl-07 | 148.113.212.20 | ns5026948.ip-148-113-212.net |

Exclude the `dev-simcity`, `staging-simcity`, and `simcity-ci` hosts. OS hostnames may differ from inventory names. VM names follow `ovh-buildkite-xl-NN-vm-MM`; discover actual names with `virsh list --all`.

## Inspect a runner VM

Run these on the physical host, substituting a discovered VM name:

```sh
sudo -n virsh domstate ovh-buildkite-xl-01-vm-01
sudo -n virsh domblkerror ovh-buildkite-xl-01-vm-01
sudo -n virsh qemu-agent-command ovh-buildkite-xl-01-vm-01 \
  '{"execute":"guest-ping"}' --timeout 10
```

QEMU guest-agent commands provide root access inside a running VM without guest SSH keys. For example, inspect guest disk space:

```sh
sudo -n virsh qemu-agent-command ovh-buildkite-xl-01-vm-01 \
  '{"execute":"guest-exec","arguments":{"path":"/usr/bin/df","arg":["-h","/"],"capture-output":true}}' --timeout 10
```

This returns a `pid`. Poll `guest-exec-status` with that PID until `exited` is true, then base64-decode `out-data` (and `err-data` if present). The request is `{"execute":"guest-exec-status","arguments":{"pid":123}}`, replacing `123`. Inside the VM, the service is `buildkite-agent.service` and its health endpoint is `http://127.0.0.1:34321/agent/1`.

## Access troubleshooting

- `ssh-add` hangs: the forwarded socket is stale or 1Password is unavailable. Reconnect the Mac session and select its new socket.
- SSH accepts the public key but stalls: check for a pending signing prompt on the Mac and unlock 1Password. Listing keys alone does not prove signing works.
- Permission denied: verify `ubuntu`, the work-key fingerprint, and `IdentitiesOnly=yes` before treating the host as unavailable.
- Preserve host-key verification; investigate an unknown or changed host key before accepting it.

For operations beyond access, consult `/home/jakob/inngest-work/ansible/docs/ovh-buildkite-runners.md` and the current user request. This skill does not prescribe cleanup, image pruning, or cache deletion.
