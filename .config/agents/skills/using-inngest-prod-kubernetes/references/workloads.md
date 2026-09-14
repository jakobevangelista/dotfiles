# Production workload and Kafka lag checks

## Match the consumer to the live workload

These NetActuate mappings were verified on 2026-09-24. Read live Deployment
`envFrom` references and the relevant ConfigMap keys before reusing them;
Kustomize adds changing hashes to ConfigMap names.

| Consumer group | Deployment in `inngest` | Backend observed |
| --- | --- | --- |
| `trace-clickhouse-sink` | `runs-ingestor` | `run-span-ingester`; verify live Kafka broker/topic configuration |
| `inbound-event-clickhouse-sink` | `events-ingestor-2` | `inbound-events` on `ceph-main-kafka-bootstrap.kafka-ceph-main.svc.cluster.local:9092` |
| `inbound-event-clickhouse-sink` | `events-ingestor` | `inbound-events` on the older `main-kafka-brokers.kafka-main.svc.cluster.local:9092` |

The two event deployments use the **same consumer-group name on different
Kafka clusters**. At that time the lagging cluster was `ceph-main`; the older
`main` cluster had zero lag and `events-ingestor` had zero replicas. The target
was therefore `events-ingestor-2`. Do not select a workload solely from a
consumer-group name or from the word "events".

Inspect only needed configuration fields; do not dump Secrets or all container
environment values. Useful ConfigMap keys for events are
`INGESTER_EVENT_KAFKA_BROKERS`, `INGESTER_EVENT_KAFKA_TOPICS`, and
`INGESTER_EVENT_KAFKA_CONSUMER_GROUP`. For runs, inspect the matching
`INGESTER_KAFKA_*` keys. Compare with the checked-out overlay, but prefer live
values when answering what currently runs.

## Pup on the Mac

The verified CLI was `/opt/homebrew/bin/pup` on the Mac; it was not installed
in Odin's current PATH. Inspect command availability and `pup --help` first.
Use the SSH route in [connections.md](connections.md) if operating from Odin.

Pup's default macOS Keychain backend returned `User interaction is not allowed`
over SSH. An **existing** file-storage session worked and refreshed itself:

```sh
DD_TOKEN_STORAGE=file pup --read-only auth status --site datadoghq.com
DD_TOKEN_STORAGE=file pup --read-only dashboards get uad-d5t-k8v
```

Use `DD_TOKEN_STORAGE=file` on each invocation when that is the working
backend. Do not print token files or invoke `pup auth token` into tool output.
Do not copy Mac credentials to Odin. If neither existing backend works, have
the user complete `pup auth login --read-only --site datadoghq.com` locally on
the Mac. If choosing file storage for SSH use, explain that choice and use the
same `DD_TOKEN_STORAGE=file` setting at login and at query time. The backend
stores credentials in permission-restricted files on the Mac.

Dashboard `uad-d5t-k8v` is **Kafka consumer lag**. Widget `4889276348723226`
used this query when inspected:

```text
sum:kafka_consumergroup_lag{cluster:*,service:kafka-*,$consumergroup,$dc} by {consumergroup,partition,dc}
```

Read the current dashboard definition instead of assuming that query is fixed.
Substitute the URL's template variables explicitly. Dashboard URL times are
milliseconds; the CLI accepts Unix seconds. URLs can include both a paused
dashboard range and a different fullscreen range. State which interval was
queried, and query recent data separately when assessing a current scale-up.

Split by Kafka cluster before choosing a workload:

```sh
DD_TOKEN_STORAGE=file pup --read-only metrics query \
  --query 'sum:kafka_consumergroup_lag{cluster:*,service:kafka-*,consumergroup:inbound-event-clickhouse-sink,dc:na-ashburn} by {cluster,dc,topic}' \
  --from 15m --to now
```

For skew, query the affected cluster by `partition` as well. The observed Pup
1.21 response used top-level `series[].tag_set` and `series[].pointlist`, even
though the command help described the v2 API. Inspect the response shape;
summarize points rather than dumping the full time series into tool output.

Do not turn missing samples into zeros or sum duplicate reporting series.
The dashboard exposed both `dc:na-ashburn` and a dual-tagged
`dc:ashburn,dc:na-ashburn` series; grouping by Kafka cluster clarified which
backlog each series represented. Report timestamps, observed trend, and any
remaining uncertainty. Falling lag alone does not prove downstream health or
that the scale-up caused the change.

## Scale an authorized target

Use the exact verified context, credential entry, namespace, and Deployment.
On the Mac, define a convenience function scoped to this shell if useful:

```sh
kprod_na() { kubectl --context k8s-oidc --user=na-ashburn -n inngest "$@"; }
kprod_na get deployment events-ingestor-2
kprod_na get hpa -o json | jq '[.items[] |
  select(.spec.scaleTargetRef.name == "events-ingestor-2") |
  {name: .metadata.name, spec: .spec, status: .status}]'
```

If an HPA or another reconciler owns replicas, inspect that before changing
the desired count. Record the current count and use a precondition so another
operator's intervening change is not overwritten. Set the following variables
only from the live count and the user's authorized target:

```sh
kprod_na scale deployment/events-ingestor-2 \
  --current-replicas="${original_replicas:?read the live count first}" \
  --replicas="${target_replicas:?use the authorized target}"
kprod_na rollout status deployment/events-ingestor-2 --timeout=120s
kprod_na get deployment events-ingestor-2
kprod_na get pods -l type=events-2
```

Use the actual selector from the Deployment for other workloads. The shared
`app=ingestor,type=runs` labels also matched `spans-flatten-ingestor` during this
session; filter by owning ReplicaSet when inspecting just `runs-ingestor`.

If pods stay Pending, inspect their scheduling conditions and current capacity:

```sh
kprod_na get pods -l type=events-2 -o json | jq '[.items[] |
  select(.status.phase == "Pending") |
  {name: .metadata.name, node: .spec.nodeName, conditions: .status.conditions}]'
kubectl --context k8s-oidc --user=na-ashburn top nodes
```

An unscheduled pod is not processing work. Lowering the desired count to the
already-running count removes pending demand but does not reduce the existing
running workload's CPU use. Scheduler capacity is based on resource requests;
`kubectl top` reports actual use, so the two can differ. Also check restarts,
node pressure conditions, and downstream symptoms before declaring a busy
cluster healthy. Replica readiness does not prove Kafka lag has recovered.

End with the original and requested counts, ready/available counts, any pending
pods and their blocker, and a verified Mac command. A live scale is not a
persisted Kustomize change; report that distinction if persistence matters.
Do not change the repository's replica defaults or deploy it unless requested.

## Historical example, not target defaults

On 2026-09-24, NetActuate `runs-ingestor` changed **12 → 24**.
`events-ingestor-2` changed **4 → desired 24**, but only **16** could schedule;
the other eight had insufficient CPU/memory. With the user's revised target,
it was set to **16/16 ready, zero Pending**. Some nodes were at 93–96% CPU.
This is not a permanent capacity limit or a recommended default replica count.

AWS `runs-ingestor` was restored to its original **5**, and Rackspace
`runs-ingestor` to its original **1**, after incorrect initial cluster choices.
Those mistakes are why endpoint verification and distinguishing context names
from credential names are required before mutations.
