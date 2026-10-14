# Control-plane setup for either topology

Run these services and the SDK on the selected control-plane host. In default
mode that is the dev-box VM; in Odin mode it is Odin. Source builds may happen
on Odin in both modes. Variables below are per-run values, not global defaults.

## Package the selected revision

Build in the clean monorepo workspace using its Nix environment (the validated
baseline has `nix develop .#ci`). Build before starting Compose, which can
create root-owned bind-mount files that interfere with later Nix source scans:

```sh
go build -o "$BUNDLE/all-in-one" ./cmd/all-in-one
go build -o "$BUNDLE/sdkgateway" ./cmd/sdkgateway
go build -o "$BUNDLE/setup-account" ./scripts/test
```

Use the repository's normal container builds when suitable. The validated fast
path uses these binaries in a `postgres:17.8` runtime container, retaining the
original service entrypoints (`/bin/main api`, `/bin/main simcityd`, etc.).
This image is a runtime carrier; it does not replace the selected application
source. Bind the correct binary to `/bin/main`, mount `/nix/store` read-only,
provide a working curl at `/usr/bin/curl` for health checks, and mount the host
CA file at `/etc/ssl/certs/ca-certificates.crt` with `SSL_CERT_FILE` set to it.
Missing CA roots can break Iroh even when the binary starts.

For the VM, copy the binaries' Nix runtime closure before starting containers.
Use `ldd`/`readelf` to identify library and interpreter store roots, then
`nix-store --query --requisites` on those roots plus Node, curl, SeaweedFS, and
any helpers. Archive those store paths relative to `/` and extract inside the
VM at the identical `/nix/store/...` paths. Do not copy store hashes from an old
run. A Nix daemon is not needed merely to execute this copied runtime closure.
Verify the library/interpreter paths inside the VM and in the runtime image.
Alternatively build in the VM with the selected repository's Nix environment;
account for the additional disk/memory cost.

Copy the selected SDK tarball into the test app and install with `file:` in
`package.json`. Include the Node runtime closure when executing that Node build
inside the VM. Record the tarball hash and SDK source revision.

## Render an isolated Compose project

Start from the selected repository's `compose-base.yml` and `compose-local.yml`,
with an empty ignored `env.local` when needed. Select `api`, `simcityd`,
`sdkgateway`, `ingest`, `clickhouse`, and their transitive dependencies. Add
services required by the particular test: event-driven functions also need
their executor path, state-store proxy, and both constraint APIs from `extra`.
Do not assume the direct-sandbox subset exercises function execution.

Render JSON once, then adapt its bind mounts, service images, ports, and bounds.
For example, run `docker compose -p <run-project> -f compose-base.yml -f
compose-local.yml --profile min config --format json` in the selected workspace.
For the VM, copy required source configuration directories into a run bundle
such as `/opt/simcity-e2e/monorepo` and rewrite binds to paths inside the VM.
Do not retain binds to Odin workspaces. Preserve dependency conditions and
authored restart/logging settings. Keep static Valkey addresses consistent with
the Compose network (the validated baseline uses `10.30.0.0/16`).

Use container DNS for internal URLs (`api:8080`, `ingest:8080`,
`simcityd:8080`). Bind published ports to the VM private IP in default mode or
loopback on Odin. Example endpoints:

| Service | VM mode | Odin alternative |
|---|---|---|
| API | `10.231.75.2:28175` | `127.0.0.1:28090` |
| h2c enrollment proxy | `10.231.75.2:28176` | `127.0.0.1:28091` |
| ingest | `10.231.75.2:29975` | `127.0.0.1:29999` |
| SDK gateway | `10.231.75.2:18075` | `127.0.0.1:18099` |
| simcityd HTTP | `10.231.75.2:18076` | `127.0.0.1:18080` |
| S3 | `10.231.75.2:19000` | choose ports per the Odin reference |

Generate a fresh Iroh identity using the selected monorepo's dependency:

```go
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
```

Redirect its output to a mode-`0600` env file, never the console. Apply the fresh
values to the participating services and give API/simcityd a matching fresh
`SIMCITY_CONTROL_PLANE_SIGNING_ROOT_KEY` (32 random bytes, base64 encoded in the
validated revision). Check the selected revision's configuration schema. Never
reuse a checked-in/shared Iroh identity or blindly replay a rendered old config.

Set `mem_limit`, `memswap_limit` equal to it (no swap), and consistent deploy
memory limits on every service, including init/migration containers. The
validated 21-service stack used about 9 GiB of aggregate limits:

| Service | MiB |
|---|---:|
| API, simcityd, db, kafka | 768 each |
| ClickHouse | 1024 |
| Scylla | 600 |
| FDB coordinator | 256 |
| FDB server 1 and 2 | 384 each |
| FDB init and kafka init | 128 each |
| migrations and snapshot S3 | 512 each |
| ingest, metadata, nats, redis-cache, sdkgateway, each Valkey node | 256 each |

Use these as a baseline, adjusting for the chosen source/services. Verify total
limits fit beneath the control-plane host's memory budget with OS headroom.
Keep Docker capped at 20 GiB/no swap: system `docker.service` inside the VM,
user `docker.service` on Odin. This daemon limit does not replace container caps.

Apply the existing ClickHouse-only filter after all other adaptations:

```sh
jq -f "$SKILL_DIR/scripts/clickhouse-safety-overlay.jq" \
  "$RUN_DIR/compose-base.json" > "$RUN_DIR/clickhouse-overlay.json"
jq -s '.[0] * .[1]' "$RUN_DIR/compose-base.json" \
  "$RUN_DIR/clickhouse-overlay.json" > "$RUN_DIR/compose.json"
jq -e --slurpfile base "$RUN_DIR/compose-base.json" '
  ([.services[].mem_limit | tonumber] | add) < (20 * 1024 * 1024 * 1024) and
  all(.services[]; (.mem_limit | tonumber) > 0 and .memswap_limit == .mem_limit) and
  .services.clickhouse.restart == "no" and
  .services.clickhouse.logging.driver == "local" and
  .services.clickhouse.logging.options["max-size"] == "20m" and
  .services.clickhouse.logging.options["max-file"] == "3" and
  ((.services | del(.clickhouse)) == ($base[0].services | del(.clickhouse)))
' "$RUN_DIR/compose.json"
```

This bounds ClickHouse error-loop logs without changing other service restart
behavior. Verify these same properties on actual containers using `docker
inspect`, not just the input JSON. Keep rendered files mode `0600`.

Pull/load the recorded dependency images before startup, then use `up -d --pull
never`. Cached Odin images can be transferred with `docker image save`, zstd,
and `docker load` in the VM; this does not start an Odin control plane. If the
selected subset omits Valkey's init service, start its three nodes and explicitly
run `sh /opt/valkey/init.sh` in node 1 before waiting on cluster health. The
validated NATS config required `--config /etc/nats/server.conf -m 8222`.
Wait for migrations/init jobs to exit successfully and API `/ready` to return
200. Check `simcityd` logs for `Iroh control plane online`.

## Disposable S3 for lifecycle tests

Use a separate SeaweedFS S3 container in the control plane by default; no AWS
login is required. SeaweedFS 4.19 was validated with its Nix `weed` executable
and runtime closure mounted into the same carrier image. Use a project-scoped
data volume, generated test credentials, and a mode-`0600` config:

```json
{"identities":[{"name":"e2e","credentials":[{"accessKey":"GENERATED_ACCESS_KEY","secretKey":"GENERATED_SECRET"}],"actions":["Admin","Read","List","Tagging","Write"]}]}
```

Run `weed server` with:

```text
-dir=/data -ip=127.0.0.1 -ip.bind=127.0.0.1
-s3 -s3.port=19000 -s3.config=/etc/weed/s3.json -s3.ip.bind=0.0.0.0
-volume.max=8 -master.volumeSizeLimitMB=4096 -volume.port=8088 -s3.iam=false
```

Publish S3 on the chosen control-plane endpoint. Prefer a separate S3 network
namespace; sharing simcityd's namespace couples their restarts. VM mode needs
no such sharing. If reproducing the Odin loopback bridge, verify its listeners
again after any service restart. Configure `simcityd` with the
generated `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION=us-east-1`,
and, in default VM mode:

```text
SIMCITY_SNAPSHOT_BUCKET_URL=s3://<run-bucket>?awssdk=v2&region=us-east-1&endpoint=http%3A%2F%2F10.231.75.2%3A19000&use_path_style=true
```

The endpoint in presigned URLs must be reachable by both simcityd and the node.
Create the bucket through S3, then assert PutObject/DeleteObject readiness
before the lifecycle test. The default two-volume setup was too small for this
workflow. Use real staging storage instead only when testing that integration,
with an isolated prefix and appropriate auth.

## h2c proxy, account, and enrollment

The tested node bootstrap client uses prior-knowledge h2c; the development API
listener is HTTP/1.1. A raw forward yields `http2: frame too large`. Build
[`scripts/h2c-proxy.go`](../scripts/h2c-proxy.go) using the selected Go toolchain
and run it on the control-plane host with a 128-MiB/no-swap bound:

```sh
go build -o "$BUNDLE/h2c-proxy" "$SKILL_DIR/scripts/h2c-proxy.go"
# VM values; substitute loopback endpoints in Odin mode.
"$BUNDLE/h2c-proxy" -listen 10.231.75.2:28176 -upstream http://10.231.75.2:28175
```

Use system `systemd-run` inside the VM and user `systemd-run --user` on Odin.
The node points directly at the VM proxy by default. Only Odin mode uses a
reverse SSH tunnel to this proxy.

Run `setup-account -api <host:port> -ingest <host:port> -n 0` on the control-plane
host with stdout/stderr redirected to a protected file (it prints a JWT).
`make jwt` hardcodes ports. Verify the seeded account/workspace in Postgres;
the baseline account is `00000000-0000-1111-0000-000000000000`.

For sandbox lifecycle tests, upsert account entitlement overrides by name:
`sandbox_concurrency=10`, `sandbox_duration=3600`; add
`sandbox_snapshot_count=20` and `sandbox_snapshot_storage_mb=100000` for snapshot
tests. Use `override_strategy='set'`. Also give this account's billing plan a
positive `sandbox_concurrency` entry in `billing_plan_entitlements` when the
selected revision gates access on plan eligibility: account overrides alone
did not satisfy that check in the validated baseline. Restrict these writes to
the disposable database, then clear
`cache:db:account-ents:<account-id>` in its Redis cache.

Read runtime `ADMIN_API_USER` and `ADMIN_API_PASS` from the API container without
printing them. POST to
`/admin/v1/compute/nodes/<verified-machine-id>/bootstrap-tokens`; require HTTP 200
and a nonempty `.data.token`. Save it mode `0600`, transfer to the owned node
state directory, compare hashes, and remove transfer copies. In VM mode use
the dev-box-local guest SSH key to retrieve it; no token needs to pass through
Odin. Do not issue tokens until the intended fresh control plane is online.

## SDK assertions and evidence

Read `INNGEST_SIGNING_KEY` from the current API container without printing it.
Use that key and the selected API URL in the local SDK client. Create a sandbox,
wait until `RUNNING`, execute commands with exact output/exit assertions, and
destroy it in `finally`. Run the test as a bounded service (512 MiB/no swap was
sufficient), recording stdout and machine-readable results to owned files.

For lifecycle pressure coverage, the retained validated test is
`/home/jakob/inngest-work/e2e-results/simcity-control-vm-20261014/evidence/app/clone-capacity.mjs`.
Adapt its project, paths, API URL, and capacity target; do not replay dated
credentials. It covers 17 checks including guest HTTPS, clone disk isolation,
503 with all capacity active, active-guest survival, pause/resume identity and
disk preservation, destroy, and warm-pool refill.

Inspect final workload/snapshot states, service health, OOM flags, memory limits,
disk usage, and node capacity. Save redacted evidence before teardown. A failed
create may legitimately leave a terminal `failed` record; require no active
test workloads or retained snapshots, not an empty workload table.
