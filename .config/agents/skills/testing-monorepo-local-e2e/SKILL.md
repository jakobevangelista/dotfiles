---
name: testing-monorepo-local-e2e
description: "Runs a real local Inngest Cloud end-to-end test with a selected monorepo revision and a local SDK app on Jakob's MacBook. Use for App API, Event API, executor, queue, sysop, migration, Serve, or Connect behavior; use the Simcity E2E skills instead for node, KVM, rootfs, or sandbox-runtime validation."
---

# Testing the Monorepo Locally End to End

Run the requested behavior through the real local control plane and a real SDK
app. Adapt the test to the feature; do not turn every invocation into a fixed
smoke suite.

This workflow requires SSH access to Jakob's MacBook, OrbStack or Docker, jj,
the Inngest Cloud monorepo, and a compatible local Inngest SDK app.

```text
local Inngest app
  |-- HTTP Serve endpoint, or
  `-- Connect WebSocket worker
            |
            v
MacBook Docker/OrbStack monorepo services
            |
            v
Postgres / ClickHouse / queue state
```

## Definition of done

Prove the smallest meaningful end-to-end path for the requested behavior:

1. The services under test use the intended monorepo revision.
2. Required migrations complete and relevant containers become healthy.
3. The SDK app registers or connects through the intended local endpoint.
4. The requested action or state transition occurs through the real service
   path, not by directly writing the expected final state.
5. Verify the outcome at the durable source of truth and, when useful, at one
   intermediate boundary such as logs, ClickHouse, or the queue.

Report the monorepo revision, app mode, relevant timestamps/counts, assertions,
and what was deliberately left running. Do not claim success from container
liveness alone.

## Current MacBook topology

Treat these as defaults and verify them before changing anything:

| Role | Address or path |
|---|---|
| MacBook | `100.107.110.76` over Tailscale SSH |
| Canonical monorepo | `/Users/jakobevangelista/inngest-work/monorepo` |
| Reusable SDK app | `/Users/jakobevangelista/inngest-work/inngest-test-app` |
| Compose project | `inngest` |
| App API | `http://127.0.0.1:8090` |
| Event API | `http://127.0.0.1:9999` |
| Connect gateway | `ws://127.0.0.1:8100/v0/connect` |
| Test app Serve endpoint | `http://127.0.0.1:3939/api/inngest` |

Start with a read-only inventory:

```sh
ssh -o BatchMode=yes 100.107.110.76 'hostname; whoami'
ssh -o BatchMode=yes 100.107.110.76 \
  'docker compose ls; docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"'
ssh -o BatchMode=yes 100.107.110.76 \
  'cd /Users/jakobevangelista/inngest-work/monorepo && jj status && jj workspace list'
```

If Docker is unavailable, check whether OrbStack is merely stopped. Starting
OrbStack is appropriate when the user asked to run this local E2E; do not
replace or delete existing Compose projects just to free ports.

```sh
ssh 100.107.110.76 'open -a OrbStack'
```

Poll `docker info` with a short bound. Inventory again because OrbStack may
resume an existing `inngest` project automatically.

## Select and build the monorepo revision

This repository uses `jj`. Never test an ambiguous dirty feature workspace.
Resolve the requested revision and create a disposable workspace beside the
canonical repo when the existing workspace is dirty or used for other work:

```sh
jj -R /Users/jakobevangelista/inngest-work/monorepo git fetch
jj -R /Users/jakobevangelista/inngest-work/monorepo log \
  -r '<revision>' --no-graph \
  -T 'commit_id.short(12) ++ " " ++ bookmarks ++ " " ++ description.first_line() ++ "\n"'
jj -R /Users/jakobevangelista/inngest-work/monorepo workspace add \
  --name '<unique-e2e-name>' -r '<revision>' \
  /Users/jakobevangelista/inngest-work/'<unique-e2e-name>'
```

Jakob's canonical Mac working copy may contain uncommitted ARM compatibility
fixes. Inspect its diff before using them. When needed, apply only the relevant
changes to the disposable workspace, typically:

```text
build.sh
cmd/all-in-one/Dockerfile
cmd/all-in-one/Dockerfile-dev
cmd/sysop/Dockerfile
```

The important invariants are native `linux/arm64` builds and the matching
FoundationDB client package selected through `TARGETARCH`. Do not copy the
entire canonical diff: `.env.local` and `compose-local.yml` can contain
unrelated settings or credentials. Only mutate a feature workspace when the
user authorized applying these compatibility changes.

Build the service images that contain the code under test. Most control-plane
and migration changes require `all-in-one`; sysop changes also require
`sysop`:

```sh
./build.sh all-in-one --arm
./build.sh sysop --arm
```

`jj` workspaces may not expose Git metadata to the build script. Record the
resolved source commit independently and record the resulting image digest and
architecture rather than trusting an empty image label.

## Start or refresh the stack

Use the existing project only after confirming it is the local `inngest`
stack. Build images from the selected workspace. The canonical Mac compose
working copy currently carries ARM-compatible FoundationDB service settings,
so it can be used to launch those images after its diff has been inspected:

```sh
cd /Users/jakobevangelista/inngest-work/monorepo
make up
```

Use `make up-min` only when the feature does not require extra-profile
services. Do not run `make down`, delete volumes, or recreate an unrelated
Compose project without explicit authorization.

Verify the relevant services and migrations. Typical containers include:

```text
inngest-api-1
inngest-event-api-1
inngest-executor-1
inngest-sysop-1
inngest-connect-gateway-1
inngest-metadata-1
inngest-db-1
inngest-clickhouse-1
```

Use bounded, filtered logs. A useful Postgres entry point is:

```sh
docker exec inngest-db-1 psql -U postgres -d postgres -P pager=off
```

Do not print environment files, signing keys, LaunchDarkly credentials, admin
credentials, or unredacted container environments.

## Start the SDK app

Inspect the app before choosing a mode. Confirm its package manager, installed
SDK source/version, exported client/functions, and startup script. Do not
silently substitute a registry SDK when the feature requires a local SDK
revision.

For the reusable HTTP app, `pnpm dev:local` starts Express on port `3939` and
serves `/api/inngest`. Point it at the local API and pass credentials without
echoing them. Treat its self-registration message as preliminary; verify the
app and workflows in Postgres or through the API.

For a Connect worker, read
[references/connect.md](references/connect.md) before starting it. Connect has
additional auth, entitlement, endpoint-path, ClickHouse, and graceful-shutdown
requirements.

Keep long-running app processes identifiable with a unique log path and PID.
Prefer graceful termination so lifecycle records are emitted. Never kill a
process found only by a broad name match.

## Make feature-specific assertions

Choose boundaries that establish causality. Examples:

- registration: app method, sync, function count, and archive state;
- execution: event receipt, queue/run creation, worker request, and terminal
  run output;
- sysop reconciliation: source history, grace interval, scheduled run,
  enqueued action, and persisted mutation;
- migrations: schema shape plus a real read/write path using the new field;
- feature flags: prove evaluation through behavior or a scoped log/counter;
  do not infer it merely because the user toggled a flag.

For time-based behavior, record timestamps and poll at short bounded intervals.
Test just before and just after the boundary when that distinction matters.
Avoid one long blind sleep.

Prefer aggregate queries before inspecting individual rows. Filter logs by
app, workflow, run, or connection ID so normal local-stack noise does not flood
the result.

## Handoff and cleanup

Cleanup depends on the user's next step. If another phase will use the state,
leave the stack/app in the required state and say so. Otherwise gracefully stop
only the app process created for the test.

Do not delete the Compose project's volumes, discard a jj workspace, remove
account entitlement overrides, or erase test data without explicit authority.
If temporary state remains, report its exact scope so a later invocation can
resume or clean it safely.
