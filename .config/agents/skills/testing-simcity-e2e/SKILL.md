---
name: testing-simcity-e2e
description: "Runs a real full-stack Simcity sandbox E2E with a local monorepo control plane and local JavaScript SDK against the remote Ubuntu KVM node reached through Jakob's MacBook. Use when validating Simcity node, rootfs, sandbox REST v2, networking, or SDK changes end to end."
compatibility: "Requires Linux, Docker, Nix, jj, pnpm, SSH access to Jakob's MacBook and the Ubuntu Simcity dev box, plus enough local memory for a stack capped below 20 GiB."
---

# Testing Simcity End to End

Run the real path from a local SDK through a local monorepo control plane to a
remote Simcity node and KVM guest. Do not substitute a fake node when the goal
is to validate a base image, guest behavior, AF_XDP, ZFS, or Cloud Hypervisor.

```text
local JS SDK
    |
    v
local App API -> local simcityd
                       ^
                       | Iroh (node-initiated)
                       |
              remote simcity-node
                       |
                       v
             Cloud Hypervisor/KVM guest
```

## Definition of done

At minimum, prove all of the following:

1. The local API and `simcityd` use the intended monorepo revision.
2. The remote node uses a Simcity revision compatible with that control plane.
3. The remote node enrolls through the local public handshake endpoint.
4. The node connects to the intended local `simcityd` over Iroh and heartbeats
   as `ready` with warm capacity.
5. A local JavaScript SDK build creates a real sandbox on that node.
6. The requested commands run inside the KVM guest and return asserted output.
7. The sandbox is destroyed and temporary local/remote infrastructure is
   cleaned up.

Capture revisions, artifact hashes, command output, node status, memory limits,
and cleanup state in the final report.

## Machine defaults

These are defaults for Jakob's current development topology. Verify them before
making changes; do not assume stale host state is safe.

| Role | Address/path | Notes |
|---|---|---|
| Local Linux host | current machine | Runs monorepo, SDK test, Docker, h2c bridge |
| MacBook jump host | `100.107.110.76` | Tailscale host `jakobs-goated-inngest-macbook-513` |
| Simcity dev box | `ubuntu@51.222.105.190` | Reach from the MacBook; hostname `local-compute-01` |
| Dev-box machine ID | `d65f25f351114245be681fc3b1380b3d` | Verify from node logs/state before issuing a token |
| Monorepo root | `/home/jakob/inngest-work/monorepo` | Many feature workspaces may exist beside it |
| Simcity root | `/home/jakob/inngest-work/simcity` | Use a clean workspace for the revision under test |
| JS SDK root | `/home/jakob/inngest-work/inngest-js` | Use a compatible local package, never a registry package |

Connectivity checks:

```sh
ssh -o BatchMode=yes 100.107.110.76 'hostname; whoami'
ssh -o BatchMode=yes 100.107.110.76 \
  "ssh -o BatchMode=yes ubuntu@51.222.105.190 'hostname; whoami'"
```

Normal `ssh` through the Mac is intentional. A direct `ProxyJump` from the
Linux host may fail because the dev-box key exists on the Mac, not locally.

## Safety rules

- This repo uses `jj`; use `jj` whenever `.jj` is present.
- Never run the test from a dirty feature workspace. Create a disposable clean
  `jj workspace` at the chosen revision.
- Inspect existing services, VMs, ZFS datasets, configs, and images before
  replacement. Only stop or remove them when the user has approved replacing
  the dev-box node/stack.
- Never touch unrelated Compose projects such as `music-sync`.
- Hard-cap the Docker user service at 20 GiB with no swap before stack startup.
- Give every local `simcityd` a unique Iroh identity. The checked-in shared key
  can route a node to another developer's control plane through global Iroh
  discovery.
- Do not print signing keys, admin credentials, bootstrap tokens, or credential
  bundles. Print byte counts or truncated hashes instead.
- Do not commit generated EROFS artifacts. GitHub rejects the current image
  size and the image must remain reproducible from Nix.
- Prefer a new E2E service/config/state namespace over overwriting production-
  shaped paths. Preserve existing config before destructive replacement.

## 1. Select a compatible source set

Protocol drift across the monorepo, Simcity, and SDK is the most common source
of misleading failures. Do not independently choose the newest revision of
each repository.

Inspect candidate workspaces:

```sh
find /home/jakob/inngest-work -maxdepth 1 -type d \
  \( -name 'monorepo*' -o -name 'simcity*' -o -name 'inngest-js*' \) \
  -print | sort

jj -R /path/to/monorepo log -r '@ | develop@origin' -n 6 --no-graph \
  -T 'commit_id.short(12) ++ " " ++ bookmarks ++ " " ++ description.first_line() ++ "\n"'
jj -R /path/to/simcity log -r '@ | main@origin' -n 6 --no-graph \
  -T 'commit_id.short(12) ++ " " ++ bookmarks ++ " " ++ description.first_line() ++ "\n"'
jj -R /path/to/inngest-js log -r '@ | main@origin' -n 6 --no-graph \
  -T 'commit_id.short(12) ++ " " ++ bookmarks ++ " " ++ description.first_line() ++ "\n"'
```

Select revisions that share the same protobuf contracts and feature lineage.
Check changes to these surfaces first:

```text
monorepo/protobuf/simcity/**
monorepo/pkg/protobuf/simcity/**
monorepo/pkg/compute/**
monorepo/cmd/all-in-one/simcityd/**
simcity/proto/simcity/**
simcity/proto/gen/simcity/**
simcity/cmd/simcity-node/internal/nodeapp/**
inngest-js/packages/inngest/src/components/sandbox/**
```

Known historical fallback, validated for real sandbox create/exec on this box:

```text
monorepo: 36447181543665a077f033682d14d21fdddce078
Simcity:  96f5cb9827e18f31751bc0ec0243d84f32bec88f
SDK tar:  /home/jakob/inngest-work/.snapshot-e2e/app/inngest-refactor.tgz
```

Use those only as a compatibility fallback. Prefer a newer pair that has
already passed focused protocol tests when testing newer behavior.

Create clean workspaces, for example:

```sh
jj -R /path/to/monorepo-source workspace add \
  --name monorepo-simcity-e2e -r "$MONOREPO_REV" \
  /home/jakob/inngest-work/monorepo-simcity-e2e

jj -R /path/to/simcity-source workspace add \
  --name simcity-remote-e2e -r "$SIMCITY_REV" \
  /home/jakob/inngest-work/simcity-remote-e2e
```

Also read `local-e2e.md` and `scripts/local-simcity-full-stack-e2e.sh`. The
script is the canonical same-host real-node test; this skill adapts its node
half to the remote dev box.

## 2. Inventory the local host and remote node

Confirm the local cap and avoid OOMs:

```sh
free -h
docker compose ls
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
systemctl --user show docker.service \
  -p MemoryCurrent -p MemoryPeak -p MemoryMax -p MemorySwapMax

systemctl --user set-property --runtime docker.service \
  MemoryMax=20G MemorySwapMax=0
```

Inventory the dev box before changing it:

```sh
ssh 100.107.110.76 "ssh ubuntu@51.222.105.190 '
  sudo systemctl list-units --all --type=service "simcity*" --no-pager
  sudo systemctl cat simcity-node 2>/dev/null || true
  sudo find /etc/simcity -maxdepth 2 -type f -print
  sudo find /var/lib/simcity -maxdepth 3 -type f -printf "%p %s bytes\\n"
  sudo zfs list -o name,used,avail,mountpoint
  sudo ls -l /dev/kvm
  ip -brief addr
  ip route
  ps auxww | grep -E "[s]imcity|[c]loud-hypervisor" || true
'"
```

Record checksums for any binary, config, image, and state that may be replaced.

## 3. Build the artifacts under test

Build the EROFS from the Simcity source under test:

```sh
make overlay-rootfs
sha256sum artifacts/overlay.erofs
ls -lh artifacts/overlay.erofs
nix shell nixpkgs#erofs-utils -c fsck.erofs artifacts/overlay.erofs
```

Build a matching static node binary when node code or protocol compatibility
matters:

```sh
make build-amd64
sha256sum bin/simcity-node-amd64
```

The dev box can normally reuse its existing kernel, initramfs, Cloud Hypervisor,
AF_XDP setup, and ZFS pool. Rebuild/deploy `kernel-amd64` and
`boot-bundle-amd64` only when those layers are under test or incompatible.

For package/rootfs tests, deploy the new EROFS while keeping the known-compatible
node/control-plane binary pair.

## 4. Start the bounded local monorepo stack

Reusable local overlays may exist here:

```text
/home/jakob/inngest-work/.snapshot-e2e/app/compose-e2e.yml
/home/jakob/inngest-work/.snapshot-e2e/app/compose-state-proxy-e2e.yml
/home/jakob/inngest-work/.snapshot-e2e/compose-memory-cap.yml
/home/jakob/inngest-work/.snapshot-e2e/bin/all-in-one
```

Verify the all-in-one binary was built from the selected source. Rebuild it if
its provenance or protocol is uncertain:

```sh
go build -o /home/jakob/inngest-work/.snapshot-e2e/bin/all-in-one ./cmd/all-in-one
```

The existing memory overlay bind-mounts that binary and `/nix/store`. Create an
empty ignored `env.local` if the clean workspace does not contain one.

Generate a fresh Iroh identity before every independently running stack. The
Compose overlay at `.snapshot-e2e/app/compose-e2e.yml` contains a previously
used identity and must not be used unchanged when another stack could exist:

```sh
cat >/tmp/generate-simcity-iroh-key.go <<'EOF'
package main

import (
	"encoding/hex"
	"fmt"
	"github.com/tmc/go-iroh/key"
)

func main() {
	secret, err := key.GenerateSecretKey()
	if err != nil { panic(err) }
	seed := secret.Bytes()
	fmt.Printf("SIMCITY_CONTROL_PLANE_IROH_SECRET_KEY=%s\n", hex.EncodeToString(seed[:]))
	fmt.Printf("SIMCITY_CONTROL_PLANE_IROH_PUBLIC_KEYS=%s\n", secret.Public().String())
}
EOF
umask 077
go run /tmp/generate-simcity-iroh-key.go >/tmp/simcity-remote-iroh.env
cat >/tmp/simcity-remote-iroh.yml <<'EOF'
services:
  simcityd:
    environment:
      SIMCITY_CONTROL_PLANE_IROH_SECRET_KEY: "${SIMCITY_CONTROL_PLANE_IROH_SECRET_KEY:?}"
      SIMCITY_CONTROL_PLANE_IROH_PUBLIC_KEYS: "${SIMCITY_CONTROL_PLANE_IROH_PUBLIC_KEYS:?}"
EOF
```

Run this from the compatible monorepo whose module contains `go-iroh`. Never
print or commit the generated env file.

Render and verify hard limits before startup:

```sh
docker compose -p simcity-remote-e2e \
  --env-file /tmp/simcity-remote-iroh.env \
  -f compose-base.yml -f compose-local.yml --profile min \
  -f /home/jakob/inngest-work/.snapshot-e2e/app/compose-e2e.yml \
  -f /home/jakob/inngest-work/.snapshot-e2e/app/compose-state-proxy-e2e.yml \
  -f /home/jakob/inngest-work/.snapshot-e2e/compose-memory-cap.yml \
  -f /tmp/simcity-remote-iroh.yml \
  config --format json >/tmp/simcity-remote-e2e-compose.json

jq '{services:(.services|length),
     gib:([.services[].mem_limit|tonumber]|add/1073741824),
     missing:[.services|to_entries[]|
       select((.value.mem_limit//0)==0)|.key]}' \
  /tmp/simcity-remote-e2e-compose.json
```

Require `missing: []` and a total below 20 GiB. Then start without pulling:

```sh
docker compose -p simcity-remote-e2e \
  --env-file /tmp/simcity-remote-iroh.env \
  -f compose-base.yml -f compose-local.yml --profile min \
  -f /home/jakob/inngest-work/.snapshot-e2e/app/compose-e2e.yml \
  -f /home/jakob/inngest-work/.snapshot-e2e/app/compose-state-proxy-e2e.yml \
  -f /home/jakob/inngest-work/.snapshot-e2e/compose-memory-cap.yml \
  -f /tmp/simcity-remote-iroh.yml \
  up -d --pull never
```

Expected host endpoints with the existing overlay:

```text
API:         127.0.0.1:28090
ingest:      127.0.0.1:29999
SDK gateway: 127.0.0.1:18099
simcityd:    127.0.0.1:18080
```

Create the local test account using the remapped ports. `make jwt` hardcodes
the default ports, so call the setup program directly:

```sh
go run ./scripts/test/* \
  -api 127.0.0.1:28090 -ingest 127.0.0.1:29999 -n 0
```

If the SDK runs an event-driven function, also start the state-store proxy and
both constraint APIs from the `extra` profile. Direct sandbox REST calls do not
normally need those services.

## 5. Start the h2c enrollment bridge

Confirm the local `simcityd` startup log says `Iroh control plane online` and
record only its public-key fingerprint.

The node's bootstrap client uses prior-knowledge h2c for an `http://` control
plane URL. The local API listener is HTTP/1.1. A raw port forward fails with:

```text
http2: frame too large, note that the frame header looked like an HTTP/1.1 header
```

Run an h2c-capable reverse proxy on `127.0.0.1:28091` targeting
`http://127.0.0.1:28090`. A proven helper exists at:

```text
/home/jakob/inngest-work/.snapshot-e2e/h2c-proxy.go
/home/jakob/inngest-work/.snapshot-e2e/bin/h2c-proxy
```

Start it with a bound:

```sh
systemd-run --user --unit=simcity-remote-h2c-proxy \
  --property=MemoryMax=128M --property=MemorySwapMax=0 \
  /home/jakob/inngest-work/.snapshot-e2e/bin/h2c-proxy
```

Choose an unused tunnel port, for example `18094`. Avoid existing ports such as
`18090` or `18093` unless their owners are understood and intentionally removed.

```sh
# Linux host -> MacBook
ssh -fNT -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -R 127.0.0.1:18094:127.0.0.1:28091 \
  100.107.110.76

# MacBook -> dev box
ssh 100.107.110.76 \
  'ssh -fNT -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -R 127.0.0.1:18094:127.0.0.1:18094 \
    ubuntu@51.222.105.190'
```

Result:

```text
dev box 127.0.0.1:18094
  -> Mac 127.0.0.1:18094
  -> Linux 127.0.0.1:28091 h2c bridge
  -> Linux 127.0.0.1:28090 API
```

## 6. Issue and transfer a fresh bootstrap token

Use the API container's runtime admin credentials without printing them:

```sh
machine_id=d65f25f351114245be681fc3b1380b3d
api_container=simcity-remote-e2e-api-1
admin_user=$(docker inspect "$api_container" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' |
  sed -n 's/^ADMIN_API_USER=//p')
admin_pass=$(docker inspect "$api_container" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' |
  sed -n 's/^ADMIN_API_PASS=//p')

response=$(mktemp)
status=$(curl -sS -u "$admin_user:$admin_pass" \
  -o "$response" -w '%{http_code}' -X POST \
  "http://127.0.0.1:28090/admin/v1/compute/nodes/$machine_id/bootstrap-tokens")
test "$status" = 200
jq -je '.data.token | select(length > 0)' "$response" \
  >/tmp/simcity-remote-bootstrap-token
rm -f "$response"
chmod 600 /tmp/simcity-remote-bootstrap-token
```

Transfer local -> Mac -> dev box, compare SHA-256 at each hop, install mode
`0600`, and remove every transfer copy after installation.

## 7. Deploy the remote node and image

Transfer large EROFS files compressed through both SSH hops:

```sh
zstd -T0 -3 -c artifacts/overlay.erofs |
  ssh 100.107.110.76 \
    'ssh ubuntu@51.222.105.190 \
      "zstd -d -c > /tmp/simcity-e2e-overlay.erofs"'
```

Transfer the node binary and token through the Mac with `scp`. Verify all
hashes on the dev box before installation.

Use dedicated paths:

```text
binary: /usr/local/bin/simcity-node-remote-e2e
config: /etc/simcity/node-remote-e2e.yaml
image:  /var/lib/simcity/images/remote-e2e-overlay.erofs
state:  /var/lib/simcity-remote-e2e/state
run:    /run/simcity-remote-e2e
unit:   simcity-remote-e2e.service
```

Before writing the node config, read
[`references/dev-box.md`](references/dev-box.md). Derive the YAML from the live
known-working config, changing only the E2E namespace, image, token, state, and
tunnel values. Preserve its capacity, runtime, AF_XDP, ZFS, and VM settings.

Stop the approved old E2E service before touching the NIC. Stop remaining
Cloud Hypervisor processes and remove only disposable E2E allocations/runtime
state. ZFS clones must be destroyed before their template; do not blindly
destroy the parent pool.

Start the transient service:

```sh
sudo systemd-run --unit=simcity-remote-e2e \
  --property=Restart=on-failure --property=RestartSec=5s \
  --property=TimeoutStopSec=30s \
  /usr/local/bin/simcity-node-remote-e2e \
  --config /etc/simcity/node-remote-e2e.yaml serve
```

Verify the sequence in journald:

```text
registering simcity node with control plane
simcity node enrolled with control plane
connected to control plane over iroh
simcity heartbeat succeeded
```

Verify database readiness and warm capacity, not merely service liveness:

```sh
docker exec simcity-remote-e2e-db-1 psql -U postgres -tA -c \
  "SELECT machine_id,status,last_seen,warm_vcpu,warm_capacity
   FROM nodes
   WHERE machine_id='d65f25f351114245be681fc3b1380b3d'"
```

Wait for `status=ready` and `warm_vcpu >= 2` before creating a sandbox. Older
compatible revisions may name the aggregate differently; inspect `\d nodes`
rather than guessing when the query does not match that revision's schema.

## 8. Configure sandbox entitlements

The local test account is `00000000-0000-1111-0000-000000000000`. Upsert
temporary `set` overrides for at least:

```text
sandbox_concurrency = 10
sandbox_duration    = 3600
```

Join by entitlement name; do not assume fixed entitlement UUIDs:

```sh
docker exec -i simcity-remote-e2e-db-1 psql -U postgres <<'SQL'
INSERT INTO account_entitlements
  (account_id, entitlement_id, value, override_strategy, comment)
SELECT
  '00000000-0000-1111-0000-000000000000', id,
  CASE name WHEN 'sandbox_concurrency' THEN 10 ELSE 3600 END,
  'set', 'temporary local Simcity E2E override'
FROM entitlements
WHERE name IN ('sandbox_concurrency', 'sandbox_duration')
ON CONFLICT (account_id, entitlement_id) DO UPDATE SET
  value = EXCLUDED.value,
  override_strategy = EXCLUDED.override_strategy,
  comment = EXCLUDED.comment,
  updated_at = now();
SQL
```

Clear the account entitlement Redis cache afterward:

```sh
docker exec simcity-remote-e2e-redis-cache-1 redis-cli DEL \
  cache:db:account-ents:00000000-0000-1111-0000-000000000000
```

Add snapshot count/storage overrides only for snapshot tests.

## 9. Run the local SDK assertion

Build/package the selected local SDK and install its tarball into a disposable
test app. A reusable app may exist at:

```text
/home/jakob/inngest-work/.snapshot-e2e/app
```

Confirm its `package.json` points to a local `file:` tarball. Never silently
fall back to the published `inngest` package.

Source the current API container's signing key without printing it:

```sh
signing_key=$(docker inspect simcity-remote-e2e-api-1 \
  --format '{{range .Config.Env}}{{println .}}{{end}}' |
  sed -n 's/^INNGEST_SIGNING_KEY=//p')

INNGEST_SIGNING_KEY="$signing_key" \
INNGEST_API_BASE_URL=http://127.0.0.1:28090 \
pnpm exec tsx path/to/e2e-script.ts
```

The test should use `inngest.sandboxes.create`, wait until `RUNNING`, call
`sandbox.commands.run`, assert exact stdout/stderr/exit code, and destroy the
sandbox in `finally`.

For a rootfs/tooling smoke test, assert absolute executable resolution, file
operations, and a real HTTPS fetch. Example guest command:

```sh
set -eu
export PATH=/bin:/sbin

# Normal sandbox launch currently writes resolv.conf but does not bring eth0
# up or request DHCP. Explicitly initialize it for network-dependent tests.
udhcpc -f -n -q -t 5 -T 2 \
  -i eth0 -s /usr/share/udhcpc/default.script

git --version
ssh -V 2>&1
ssh -G github.com </dev/null >/tmp/ssh-config
which git
which cp
which rm
which chmod
which touch

touch /tmp/source
chmod 600 /tmp/source
cp /tmp/source /tmp/copied
test -f /tmp/copied
rm /tmp/source /tmp/copied

git clone --depth 1 \
  https://github.com/octocat/Hello-World.git /tmp/hello-world
test -f /tmp/hello-world/README
git -C /tmp/hello-world rev-parse --short HEAD
```

Do not hide the explicit DHCP step in reporting. Automatic guest network
initialization is a separate Simcity runtime concern from package availability.

## 10. Troubleshoot and clean up

Use the boundary-oriented diagnosis table and complete cleanup checklist in
[`references/dev-box.md`](references/dev-box.md). Cleanup is part of the test,
not an optional follow-up. At minimum, destroy the SDK sandbox, stop the remote
E2E node and its VM, remove token copies and both tunnels, stop the h2c bridge,
remove only this Compose project and its volumes, and verify no matching
listener/container/volume/VM remains. Leave unrelated services untouched.
