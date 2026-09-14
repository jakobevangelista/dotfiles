---
name: using-inngest-prod-kubernetes
description: "Access and operate Inngest production Kubernetes across AWS EKS, NetActuate Ashburn, and Rackspace Ashburn from Muninn, Odin, or Jakob's Mac. Use for context selection, AWS/OIDC auth, tailnet and SSH connectivity, workload scaling, and Kafka consumer lag checks. Excludes staging and Simcity host rollouts."
---

# Inngest production Kubernetes

This is the working access runbook observed on 2026-09-24. Context aliases,
LAN addresses, credentials, workloads, and capacity can change: inspect the
current host before using the examples. This skill documents the existing
setup; it does not authorize changing tailnets, kubeconfig aliases, resource
requests, or unrelated infrastructure.

## Identify the production cluster first

There are **three separate production clusters**. Neither "production" nor
"Ashburn" uniquely identifies one. Resolve an ambiguous target before a
mutation; reuse an explicit selection already made in the conversation.

| Intended cluster | Observed context | Cluster entry / endpoint | Authentication |
| --- | --- | --- | --- |
| AWS production, us-east-2 | `arn:aws:eks:us-east-2:836356947314:cluster/main` | EKS account `836356947314`, cluster `main` | `AWS_PROFILE=prod`; EKS role `EKSAdminAccess` |
| NetActuate Ashburn (`na-ashburn`, IAD-NA) | `k8s-oidc` | `kubernetes`; `https://kube-api-1ee4e8d5.infra.inngest.lol:8443`, a CNAME for `iad1-kube.infra.inngest.lol` | Shared Cognito OIDC; verified working override `--user=na-ashburn` |
| Rackspace Ashburn (IAD-RS) | `rs-ashburn` | `rs-ashburn`; `https://iad-rs-kube.infra.inngest.lol:8443` | Shared Cognito OIDC; user entry also named `na-ashburn` |

**A kubeconfig user name is not a cluster identity.** In this setup,
`rs-ashburn` uses credentials named `na-ashburn` while connecting to Rackspace.
On the verified Mac setup, there was no context literally named `na-ashburn`. Scaling `rs-ashburn` does
not scale NetActuate. Do not rename entries just to make a task's wording fit.
These aliases are host-specific. Muninn now has a snapshot of Odin's four
contexts, including the AWS ARN names. Its optional `work kube-config prod`
helper creates a separate AWS EKS context named `prod`.

Inspect contexts and public endpoints on the machine that will run kubectl:

```sh
kubectl config get-contexts
kubectl config view -o json | jq '{
  current: ."current-context",
  contexts: [.contexts[] | {name, context}],
  clusters: [.clusters[] | {name, server: .cluster.server}]
}'
```

For NetActuate, confirm the endpoint and then make a read-only request:

```sh
kubectl config view --context k8s-oidc --minify \
  -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
kubectl --context k8s-oidc --user=na-ashburn -n inngest get deployments
```

Do not use `--raw` with `kubectl config view`: it can expose credentials.
For a tunnel, verify its remote destination as well as the kubeconfig entry.

## Choose the access path

- **AWS EKS:** use Odin's `prod` AWS SSO profile. Verify the account before
  operating. Mac SSH forwarding and work-tailnet access are not prerequisites
  for this route.
- **NetActuate / Rackspace via Muninn:** prefer the VM for work-network access
  so the Mac and Odin can both stay on the personal tailnet. Read
  [muninn.md](references/muninn.md) for direct kubectl and an Odin-to-Muninn
  API tunnel. Authenticated deployment reads from Muninn succeeded against
  all three production clusters on 2026-09-24 after enabling subnet routes
  and completing separate AWS and Cognito logins. Recheck expiring sessions
  before use.
- **Mac fallback:** the previously verified route uses the Mac on the Inngest
  work tailnet and a separate LAN connection to Odin. It requires actual LAN
  reachability; the old Mac address is not usable from every location.
- **Run kubectl on the Mac over LAN SSH** when that route and its OIDC session work.
  This was the simplest working path once SSH agent forwarding was restored.
- **Tunnel only the API connection through the Mac** when OIDC credentials
  live on Odin. Keep credentials on their originating host and preserve TLS
  verification. NetActuate's IPv4 endpoint timed out in this session while its
  IPv6 endpoint worked through the Mac's work tailnet.

Read [connections.md](references/connections.md) for exact auth, agent
forwarding, LAN SSH, and tunnel steps. Do not run a Simcity E2E to obtain
Kubernetes access.

## Operate and verify

Use an explicit context and namespace for agent-issued production commands.
Honor the user's authorized cluster, workload, and target count. Inspection
alone is not authorization to scale. Once the exact change is authorized,
perform it without asking for the same permission again.

Before scaling, read the live Deployment, its relevant non-secret ConfigMap
fields, and any HPA targeting it. Match the service or consumer group to its
actual backend; similar names can point at different Kafka clusters. Read
[workloads.md](references/workloads.md) for consumer mappings, Pup checks,
scale preconditions, and capacity handling.

Record the original count before changing it. A successful `kubectl scale`
only sets the desired count. Verify ready/available replicas, pending pods,
and restarts. Do not report `24/24` when Kubernetes has only accepted a desired
count of 24.

If scheduling is blocked, inspect pod conditions and node capacity. Do not
lower resource requests, remove taints, reduce other services, or add machines
as an implicit extension of replica-scaling authorization. Report the actual
running count and the concrete blocker. Obtain a new target if the user wants
to change the requested count.

Give the user a verification command through the access path actually used,
including the correct context and credential entry. For direct Muninn access,
wrap it in `ssh muninn '...'` from the Mac; for a temporary tunnel, explain
which host and open tunnel it needs. For the Mac fallback, for example:

```sh
kubectl --context k8s-oidc --user=na-ashburn -n inngest \
  get deployment events-ingestor-2
```

If they want a context-free command, explain which current context is needed;
do not silently switch their default context. Do not persist temporary tunnel
addresses in their kubeconfig.

## Sources when the setup changes

- Infra: `/home/jakob/inngest-work/infra/docs/kubernetes.md` for EKS access;
  `prod/aws/route53/infra.inngest.lol/kube.tf` distinguishes IAD-NA and IAD-RS
  DNS endpoints; `prod/netactuate/ashburn/k8s/` and
  `prod/rackspace/ashburn/k8s/` contain site configuration.
- Workloads: `/home/jakob/inngest-work/monorepo/opt/deploy/inngest/`, especially
  `overlays/na-ashburn/kustomization.yaml` and `base/services/ingestor/`.
  Live configuration can differ from the checkout.
- Check the working tree and applicable `AGENTS.md` before repository edits.
  This runbook itself is maintained in the dotfiles skill directory.
