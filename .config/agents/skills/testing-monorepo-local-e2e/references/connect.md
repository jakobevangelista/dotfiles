# Connect worker mode

Read this reference only when the local SDK app should run as a Connect worker.

## Local defaults

The reusable app exports `inngest` and `functions` from `./inngest`. Its
installed JavaScript SDK includes `inngest/connect`.

The local test identity currently uses:

```text
account:   00000000-0000-1111-0000-000000000000
workspace: 72652407-0476-48dd-b1c0-e4ddeb22d8ec
```

Verify these from Postgres rather than assuming they are unchanged.

## Authentication and entitlement

`POST /v0/connect/start` requires a signing key even in local development. A
running local sysop container normally has the test workspace key. Pass it
directly to the child process; never print it or write it to a tracked file:

```sh
e2e_signing_key=$(docker exec inngest-sysop-1 printenv INNGEST_SIGNING_KEY)
```

The account also needs the boolean `connect` entitlement. Inspect the effective
plan/account rows first. A plan can have a positive
`connect_worker_connections` limit while `connect` itself remains disabled.
The gateway then reports `ConnectionAllowed:false` even though a feature flag
is enabled.

For an authorized local test, add a scoped temporary override by joining on the
entitlement name rather than assuming its UUID:

```sql
INSERT INTO account_entitlements
  (account_id, entitlement_id, value, override_strategy, comment)
SELECT
  '00000000-0000-1111-0000-000000000000', id, 1, 'set',
  'temporary local Connect E2E override'
FROM entitlements
WHERE name = 'connect'
ON CONFLICT (account_id, entitlement_id) DO UPDATE SET
  value = EXCLUDED.value,
  override_strategy = EXCLUDED.override_strategy,
  comment = EXCLUDED.comment,
  updated_at = now();
```

Local entitlement caches expire quickly. Prefer waiting for the bounded local
TTL; if the test requires immediate invalidation, inspect the cache container
and delete only this account's entitlement key.

## Start the reusable worker

The gateway override is a full WebSocket endpoint. Omitting `/v0/connect`
causes a successful HTTP start request followed by an opaque SDK reconnect
loop.

From `/Users/jakobevangelista/inngest-work/inngest-test-app`, start:

```sh
INNGEST_DEV=1 \
INNGEST_API_BASE_URL=http://127.0.0.1:8090 \
INNGEST_CONNECT_GATEWAY_URL=ws://127.0.0.1:8100/v0/connect \
INNGEST_CONNECT_ISOLATE_EXECUTION=false \
INNGEST_SIGNING_KEY="$e2e_signing_key" \
node -r ts-node/register -r dotenv/config -e '
const { connect } = require("inngest/connect");
const { inngest, functions } = require("./inngest");

(async () => {
  const conn = await connect({
    apps: [{ client: inngest, functions }],
    isolateExecution: false,
  });
  console.log(JSON.stringify({
    marker: "CONNECTED",
    connectionId: conn.connectionId,
    state: conn.state,
  }));
  await conn.closed;
  console.log(JSON.stringify({ marker: "CLOSED" }));
})().catch((err) => {
  console.error("CONNECT_FATAL", err?.stack || err);
  process.exit(1);
});
'
```

Run it under an identifiable background PID/log only when the test must
continue across tool calls. Capture the PID at launch and terminate that exact
PID later.

## Verify readiness and lifecycle state

Do not rely on the SDK's `CONNECTED` line alone. Identify the app in Postgres
and prove ClickHouse has a recent READY connection:

```sql
SELECT id, workspace_id, external_id, name, method, archived_at
FROM apps
WHERE workspace_id = '72652407-0476-48dd-b1c0-e4ddeb22d8ec'
ORDER BY updated_at DESC;
```

```sh
docker exec inngest-clickhouse-1 clickhouse-client --query "
SELECT app_id, app_name, id, status, connected_at, last_heartbeat_at,
       disconnected_at, disconnect_reason, function_count
FROM inngest.connect_worker_connections_app FINAL
WHERE app_id = toUUID('<app-id>')
ORDER BY recorded_at DESC
FORMAT TSVWithNames"
```

For this schema, status `1` is READY and status `4` is DISCONNECTED. Treat a
READY row as active only when its heartbeat is recent enough for the behavior
under test.

After sending `SIGTERM`, wait for the SDK to log its drain/close sequence, then
confirm the same connection becomes DISCONNECTED in ClickHouse. Connection
history is batch-flushed, so allow a short bounded delay.

For queue or sysop tests, verify the final workflow state in Postgres as well
as the enqueue/reconciliation logs. Source-aware pause tests should assert both
`paused_at` and `pause_source` before and after the transition.

## Common failure boundaries

| Symptom | Likely boundary |
|---|---|
| `/v0/connect/start` returns 401 | missing or wrong signing key |
| Start returns 200, gateway says `ConnectionAllowed:false` | `connect` entitlement disabled or connection limit reached |
| Start returns 200, SDK endlessly reconnects, gateway sees nothing | gateway URL missing `/v0/connect` or wrong exposed port |
| SDK says active, ClickHouse has no row yet | wait for the gateway's short batch flush and verify the app ID |
| App is online but cron action does not happen | inspect schedule time, source-aware state, feature flag, and durable queue handler separately |

Keep the worker online after an unpause test unless the user wants to test a
subsequent disconnect; stopping it can legitimately make the functions pause
again on the next reconciliation cycle.
