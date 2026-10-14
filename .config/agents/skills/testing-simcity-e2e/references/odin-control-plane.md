# Alternative: control plane on Odin

Use this mode whenever requested or useful, including real cross-host network
coverage, dev-box resource pressure, or troubleshooting the VM setup. It remains
a supported alternative; the default is the control-plane VM. State the choice
and preserve any failure evidence from an earlier mode.

## Start the bounded stack on Odin

Follow the shared source/build guidance in `SKILL.md` and
[control-plane setup](control-plane.md). Here the SDK, Compose services, local
S3, and h2c proxy run on Odin. No control-plane VM or TAP is needed on the dev
box. The real node and sandbox guests still run there.

Before startup, check Odin's memory, `/` disk headroom, and unrelated Docker
projects. Hard-cap the user Docker service:

```sh
systemctl --user set-property --runtime docker.service \
  MemoryMax=20G MemorySwapMax=0
systemctl --user show docker.service -p MemoryMax -p MemorySwapMax
```

Use fresh project/state paths, per-container bounds, and the shared
ClickHouse-only safety filter. Existing overlays under
`/home/jakob/inngest-work/.snapshot-e2e/` can help, but verify source provenance,
ports, and bind paths and replace old Iroh/signing credentials. Do not copy a
previously rendered stack unchanged.

Example local ports are API `28090`, ingest `29999`, SDK gateway `18099`, and
simcityd HTTP `18080`. Run the h2c helper on `127.0.0.1:28091` targeting the API
on `127.0.0.1:28090`, as a 128-MiB/no-swap user service.

## Enrollment and storage tunnels

Choose unused dev-box ports after inspecting listeners. With the explicit
forwarded socket, open a reverse enrollment tunnel and record its PID/owner:

```sh
export SSH_AUTH_SOCK=/home/jakob/.ssh/mac-forwarded-agent.sock
ssh -fNT -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -R 127.0.0.1:18094:127.0.0.1:28091 ubuntu@51.222.105.190
```

Set the node's `control_plane_url` to `http://127.0.0.1:18094`. That forwards to
Odin's h2c proxy, then to its HTTP/1.1 API. A raw tunnel directly to the API
does not fix the h2c mismatch. Iroh carries node/control-plane RPC traffic.

For disposable local S3, ensure the **same URL embedded in presigned requests**
is reachable by the node and simcityd. The validated Odin setup exposed S3 on
Odin port `39075`, reverse-forwarded dev-box `127.0.0.1:19000` to it, and
made `127.0.0.1:19000` reach S3 inside simcityd's network namespace too. Adapt
the exact ports/routes to the stack; container loopback is not Odin loopback.
An alternative is an explicit address reachable from both machines. Verify
signed Put/Get requests from both sides before running snapshots; do not
rewrite a presigned URL's host after signing it.

Cloud S3 with an isolated test prefix is another option when that integration
is part of the requested test. AWS login is not intrinsically required by
Odin mode; use local S3 when cloud behavior is irrelevant.

Issue a fresh bootstrap token using the shared procedure, transfer it from
Odin to the owned node state path, compare hashes, and remove transfer copies.
Deploy the node per [the dev-box reference](dev-box.md). Run the local SDK
tarball's assertions on Odin with the current API signing key and local URL.

## Cleanup and optional retention

Destroy test workloads/snapshots and clean the owned node first. Kill only the
SSH tunnel PIDs identified by the exact run's reverse-port arguments. Stop the
owned h2c/S3 bridge processes and tear down the exact Compose project and its
volumes. Verify no matching listeners, containers, volumes, node guests, or
tokens remain. Leave unrelated Odin services untouched.

For explicit post-test retention, retain only the bounded Odin control plane;
remove the node, guests, tunnels, and tokens first. Keep the rendered config
mode `0600` and install a verified user timer, for example:

```sh
systemd-run --user --unit="$EXPIRY_UNIT" --on-active=6h --collect \
  "$(command -v docker)" compose -p "$COMPOSE_PROJECT" \
  -f "$RUN_DIR/compose.json" down -v --remove-orphans
systemctl --user is-active "$EXPIRY_UNIT.timer"
```

Report the UTC expiry and exact cleanup command. Renewal requires an explicit
request and a fresh resource check. Cancel the timer after manual cleanup.
