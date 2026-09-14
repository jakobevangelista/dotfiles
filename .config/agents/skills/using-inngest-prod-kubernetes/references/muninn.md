# Production access through Muninn

Use Muninn for work-network access while the Mac and Odin stay on the personal
tailnet. The path is Mac → Odin → Muninn at `10.88.0.10` → work network.
Changing Muninn's tailnet does not remove its private SSH path from Odin.

## Verified state, 2026-09-26

On 2026-09-24, Muninn booted with 2 vCPUs / 4 GiB RAM and enrolled in
`inngest.com`, MagicDNS suffix `tail2dd48.ts.net`. Private SSH from Odin worked.
The old benchmark containers were removed and Docker stopped. Jakob deferred
resource increases; do not restore the larger baseline automatically. See
[the temporary profile and restore commands](/home/jakob/dotfiles/docs/muninn-jumpbox-2026-09-24.md).
These overrides disappear on an **Odin reboot**, not a Muninn restart.

Authenticated reads passed again against **AWS EKS, NetActuate, and
Rackspace** on 2026-09-26. Home Manager is now active (`Result=success`), and
the installed `work doctor` passed all access checks. Current definitions:

- `~/.aws/config`: Home Manager now manages `SystemAdministrator-836356947314`,
  `prod`, `stage`, `staging`, `sandbox`, and `operations`, sharing refreshable
  SSO session `inngest`. Both staging profile names select account `909933634258`.
- `~/.kube/config`: Odin's four contexts, their CA data and API endpoints, and
  its selected AWS production context. EKS exec users explicitly select
  `AWS_PROFILE=prod` or `AWS_PROFILE=stage` for the corresponding account.

The imported kubeconfig remains a mode 0600 **snapshot** in Muninn's private
home; future Odin edits are not automatically synchronized. AWS profile metadata
is now a managed symlink, while credential caches remain private. No token caches,
credentials file, private keys, or saved login sessions were copied. The
context mappings, CA data, and endpoints were compared against Odin. AWS SSO
and Cognito were then authenticated separately in the guest. The guest has
`kubectl`, `kubectl-oidc_login`, AWS CLI, and `work`; no restart was needed for
the live access fix.

Setup details to preserve:

- The earlier unmanaged SSH configuration conflict and AWS profile mismatch
  were resolved. Private SSH additions live in `~/.ssh/config.local`, including
  the preserved `simcity-macbook` block. Fresh login shells load merged
  `KUBECONFIG`, with `~/.kube/config` first and optional `work-prod`, `work-stage`,
  and `work-staging` files afterward. The installed helper handles both imported
  EKS ARN contexts and the `stage` alias; absent optional files are not a failure.
- Only the guest user environment was activated live. The new guest manifest
  is selected on Odin, but a full restart persistence check remains outstanding.
  See [the activation record](/home/jakob/dotfiles/docs/muninn-work-access.md#verified-setup-2026-09-26).
- Subnet-route acceptance was initially disabled, which prevented access to
  Ashburn's IPv6 API addresses. Enabling it installed work routes for
  `2607:e3c0:a041::/48` (NetActuate) and `2607:e3c0:a042::/48` (Rackspace).
  Both APIs then passed TLS verification using their kubeconfig CA and DNS
  name, followed by authenticated kubectl reads.

These are setup observations, not proof of a cluster outage. No cluster
mutation, credential transfer, or routing change is implied by this runbook.

## Connect and check the guest

From Odin:

```sh
muninn status
muninn ssh
```

From the Mac, the configured alias should use Odin as ProxyJump:

```sh
ssh muninn
```

If that alias hangs, use the explicit Mac → Odin → Muninn connection in
`using-muninn`. Kubernetes access uses guest-local credentials; it does not
require the Mac's forwarded 1Password agent used for bastion/PgBouncer SSH.

If the VM is stopped, use the `using-muninn` skill and the resource note above
for startup. Do not rebuild the host or alter VM resources just to run kubectl.
Inside Muninn, check the identity and current setup:

```sh
hostname
tailscale status --json | jq '{BackendState, CurrentTailnet, Health,
  Self: (.Self | {DNSName, Online})}'
tailscale debug prefs | jq '{RouteAll, CorpDNS}'
kubectl config get-contexts
aws configure list-profiles
```

Expect hostname `muninn` and work suffix `tail2dd48.ts.net`. If enrollment is
needed within the authorized setup, use `work login tailscale` **inside Muninn**.
Its earlier non-setuid `sudo` PATH issue is fixed. The equivalent explicit
invocation uses the NixOS privilege wrapper:

```sh
/run/wrappers/bin/sudo /run/current-system/sw/bin/tailscale login \
  --accept-dns=true --accept-routes=true --advertise-exit-node=false \
  --advertise-routes= --exit-node= --ssh=true --netfilter-mode=off --timeout=5m
```

Give the user that invocation's fresh browser link and verify the tailnet
afterward. Do not save login links or repeat login to fix API timeouts.

For Ashburn connectivity, resolve the selected API **inside Muninn**:

```sh
getent ahosts kube-api-1ee4e8d5.infra.inngest.lol
getent ahosts iad-rs-kube.infra.inngest.lol
ip -4 route show table all
ip -6 route show table all
```

Test the selected address and port 8443 with a short timeout. The working
Ashburn path uses IPv6 through work-tailnet subnet routers. `RouteAll` must
be true; to restore the verified setting inside Muninn:

```sh
/run/wrappers/bin/sudo tailscale set --accept-routes=true
ip -6 route show table 52
```

`hosts/muninn/default.nix` and the updated `work login tailscale` helper retain
this setting. An older installed manifest may reset it to false on boot;
check the selected manifest and `tailscaled-set.service` if the issue returns.
Leave Odin and the Mac on the personal tailnet. A tunnel cannot repair missing
guest routing, and an OIDC login cannot repair a connection timeout.

## Run kubectl inside Muninn

Credentials and kubeconfigs belong in Muninn's private persistent home, not
the shared dotfiles or worktrees. Authenticate on the host executing kubectl.

### AWS EKS

The managed `prod` profile and imported production ARN context are available. An
existing working Odin AWS session remains an independent route; EKS does not
require this VM. If guest definitions are missing later, inspect the private
files and [the work-access setup](/home/jakob/dotfiles/docs/muninn-work-access.md)
before generating or replacing configuration.

Inside Muninn, check the identity first:

```sh
aws sts get-caller-identity --profile prod --region us-east-2
```

Require account `836356947314`. If its SSO session needs login:

```sh
aws sso login --profile prod --use-device-code --no-browser
```

Then use the inherited context for a read-only request:

```sh
kubectl --kubeconfig "$HOME/.kube/config" \
  --context arn:aws:eks:us-east-2:836356947314:cluster/main \
  --request-timeout=20s -n inngest get deployments
```

`work kube-config prod` is optional: it generates `~/.kube/work-prod` with
context `prod` and role `EKSAdminAccess`, rather than changing the imported
config. It does not configure NetActuate or Rackspace. A fresh login shell loads
that separate file through the merged `KUBECONFIG`; an existing shell can use
explicit `--kubeconfig ~/.kube/work-prod --context prod`. The helper supports
both `stage` and `staging`, and the imported EKS exec user still selects `stage`.

### NetActuate / Rackspace OIDC

The imported configuration contains the endpoints, CAs, and Cognito exec
plugins. Authenticate separately in Muninn. For a future refresh, inspect
Odin's definitions before replacing the guest copy: transfer reviewed profile
and context metadata, preserve guest-specific files, and do not copy an entire
`.kube` directory, token cache, or private credentials. Normalize any host-only
plugin paths to the guest binaries and preserve explicit EKS profile bindings.

Inspect contexts and endpoints as described in the main skill. The Mac aliases
`k8s-oidc`, `rs-ashburn`, and credential entry `na-ashburn` are present in the
imported Odin configuration. Use the
[Cognito OIDC procedure](connections.md#cognito-oidc-login) in the guest; for
`authcode-keyboard`, the user enters the code into the waiting guest terminal.
Browser success alone does not complete the CLI login.

An alternative verified flow uses the plugin's `authcode` grant with
`--skip-open-browser --listen-address=127.0.0.1:8000`, retaining the imported
issuer, client ID, scopes, and redirect URL. Forward the Mac's loopback port
to **Muninn's loopback port**, then open `http://localhost:8000/` on the Mac:

```sh
# Run on the Mac while the guest login process is waiting.
ssh -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:8000:127.0.0.1:8000 muninn
```

When running the plugin directly, suppress its stdout because successful
`get-token` output contains credentials; keep its private disk cache enabled.
The resulting `na-ashburn` cache was reused by both cluster contexts. A forward
to `10.88.0.10:8000` from Odin does not reach a guest server bound only to
`127.0.0.1`. Close the temporary callback tunnel after login.

Once configured, verified, and authenticated, an Odin command can be:

```sh
muninn ssh 'kubectl --context k8s-oidc --user=na-ashburn \
  --request-timeout=15s -n inngest get deployments'
```

## Keep kubectl credentials on Odin; tunnel the API through Muninn

Use this option when Odin already has the correct context and working OIDC
credentials. Muninn needs network reachability but no kubeconfig or OIDC
tokens. Confirm that Muninn can reach the selected API first, and choose an
unused Odin loopback port with `ss -ltnp`.

For NetActuate, run on Odin and retain this SSH session for cleanup:

```sh
ssh -N -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -L 127.0.0.1:18445:kube-api-1ee4e8d5.infra.inngest.lol:8443 \
  jakob@10.88.0.10
```

The guest key should already be trusted after verified `muninn ssh` access.
If hostname forwarding selects an unreachable IPv4 destination, use a freshly
resolved and tested IPv6 address in the bracketed forward syntax shown in
[connections.md](connections.md#tunnel-the-api-through-the-mac-when-kubectl-must-run-on-odin).
Do not reuse a historical IPv6 address without checking it.

In a separate Odin shell:

```sh
kubectl --context k8s-oidc --user=na-ashburn \
  --server=https://127.0.0.1:18445 \
  --tls-server-name=kube-api-1ee4e8d5.infra.inngest.lol \
  --request-timeout=15s -n inngest get deployments
```

For Rackspace, use remote destination `iad-rs-kube.infra.inngest.lol:8443`,
context `rs-ashburn`, and TLS name `iad-rs-kube.infra.inngest.lol`, after checking
its credential entry. Keep overrides per-command, preserve the context's CA,
and never disable TLS verification. Close only the tunnel you created.
