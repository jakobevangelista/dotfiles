# Production access paths

For the Muninn work-tailnet path, see [muninn.md](muninn.md). It lets the Mac
and Odin remain on the personal tailnet. The Mac/LAN methods below remain
fallbacks; they depend on current LAN reachability and a work login on the Mac.

## AWS EKS from Odin

Check the existing session first; do not require login or agent forwarding if
it already works:

```sh
aws sts get-caller-identity --profile prod
```

Require account `836356947314`. If SSO has expired, initiate the device flow
on Odin and give the user the freshly generated link/code:

```sh
aws sso login --profile prod --use-device-code --no-browser
```

Then use the explicit production context:

```sh
AWS_PROFILE=prod kubectl \
  --context arn:aws:eks:us-east-2:836356947314:cluster/main \
  --request-timeout=20s -n inngest get deployments
```

The observed exec plugin assumes
`arn:aws:iam::836356947314:role/EKSAdminAccess`. An AWS login does not
authenticate the bare-metal Ashburn clusters.

## Mac and Odin on different tailnets

Observed addresses on 2026-09-24, **not fixed configuration**:

| Machine | LAN address | Personal-tailnet address |
| --- | --- | --- |
| Odin | `10.0.0.74` | `100.118.239.121` |
| Work MacBook | `10.0.0.236` | `100.75.136.81` |

The observed SSH user on both was `jakob`. Other Mac configurations use other
usernames; verify rather than renaming accounts. On Odin, `ip -brief -4 addr`
shows its LAN interface. On the Mac, use `route -n get default` to identify
the LAN interface and `ipconfig getifaddr <interface>` to read its address.

Have the user establish a LAN session **from the Mac** before switching its
personal Tailscale account to the Inngest work tailnet:

```sh
ssh -A jakob@10.0.0.74
```

Keep that session open. In its **Odin shell**, publish the forwarded agent:

```sh
forwarded_sock=$SSH_AUTH_SOCK
stable_sock=$HOME/.ssh/mac-forwarded-agent.sock
test -S "$forwarded_sock" &&
  test "$forwarded_sock" != "$stable_sock" &&
  install -d -m 700 "$HOME/.ssh" &&
  ln -sfn "$forwarded_sock" "$stable_sock"
SSH_AUTH_SOCK="$stable_sock" ssh-add -l
```

Refresh this link after each reconnect. Agent processes may have inherited a
stale `SSH_AUTH_SOCK`; explicitly set the stable path on **every** SSH/SCP
tool invocation. If it is unavailable, ask for this step rather than searching
`/tmp` for sockets or copying a private key.

The user switches the Mac's tailnet; leave Odin's personal-tailnet connection
alone. A browser login and network reachability are separate checks.

## Run kubectl on the Mac

The following worked from Odin after the Mac joined the work tailnet:

```sh
SSH_AUTH_SOCK=/home/jakob/.ssh/mac-forwarded-agent.sock \
ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
  -o HostKeyAlias=100.75.136.81 jakob@10.0.0.236 \
  '/opt/homebrew/bin/kubectl --context k8s-oidc --user=na-ashburn \
    --request-timeout=15s -n inngest get deployments'
```

Here `HostKeyAlias` checks the already-trusted host key for **the same Mac**
previously reached at its personal-tailnet address. Verify that association
with `ssh-keygen -F 100.75.136.81 -l`; do not use another machine's alias or
disable host-key checking to get past an error. The successful remote hostname
was `jakob-goated-inngest-macbook-pro.local`.

Use the Mac's absolute kubectl path when a noninteractive shell has a limited
PATH. Keep quoted remote commands free of credential values. Do not forward
the agent onward to cluster hosts.

## Cognito OIDC login

Both Ashburn clusters use the same Cognito issuer/client, but kubeconfig
credential entries can have different plugin arguments and token caches.
On this setup, `--user=na-ashburn` worked with **both** `k8s-oidc` and
`rs-ashburn`. The default `cognito-oidc` entry requested a separate login.
Reusing the working credential entry does not change the selected cluster.

First try a read-only command. If the helper prints a URL and `Enter code:`,
keep that process alive and give the user **that invocation's** fresh URL.
After browser login, `http://localhost:8000/?code=...&state=...` can fail to
load: `authcode-keyboard` expects the code to be entered into the waiting
process. Browser success alone has not finished the CLI login.

Prefer that the user enters the code in their terminal. For an agent-managed
prompt, pass the returned code only to the matching waiting process; disable
terminal echo first and do not repeat it in logs or retain it in files. Never
store login URLs, codes, access tokens, or refresh tokens in this skill.

Authenticate on the machine that will use the credentials. If kubectl will
run on the Mac, an Odin-only OIDC login does not log in the Mac. If a token
exchange succeeds but API calls time out, investigate routing before asking
for another login.

## Tunnel the API through the Mac when kubectl must run on Odin

This route keeps Odin's OIDC credentials on Odin and uses the Mac only for
network access. Choose an unused loopback port (`ss -ltnp`), and keep the SSH
process/session identifier so you can close only the tunnel you created.

For Rackspace, the remote destination hostname worked directly:

```sh
SSH_AUTH_SOCK=/home/jakob/.ssh/mac-forwarded-agent.sock \
ssh -N -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
  -o HostKeyAlias=100.75.136.81 -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -L 127.0.0.1:18443:iad-rs-kube.infra.inngest.lol:8443 \
  jakob@10.0.0.236
```

In a separate Odin tool call:

```sh
kubectl --context rs-ashburn --server=https://127.0.0.1:18443 \
  --tls-server-name=iad-rs-kube.infra.inngest.lol \
  --request-timeout=15s -n inngest get deployments
```

For NetActuate, hostname forwarding selected an IPv4 route that timed out.
On the Mac, inspect current DNS and test the advertised IPv6 addresses:

```sh
dscacheutil -q host -a name kube-api-1ee4e8d5.infra.inngest.lol
nc -6 -vz -G 4 2607:e3c0:a041:10::ae 8443
route -n get -inet6 2607:e3c0:a041:10::ae
```

`2607:e3c0:a041:10::ae` was one verified address, reached through a work-tailnet
`utun` interface. Re-resolve and verify it rather than assuming it is permanent.
With that verified address, use the same SSH options as above and this forward:

```sh
-L '127.0.0.1:18445:[2607:e3c0:a041:10::ae]:8443'
```

Then, on Odin:

```sh
kubectl --context k8s-oidc --user=na-ashburn \
  --server=https://127.0.0.1:18445 \
  --tls-server-name=kube-api-1ee4e8d5.infra.inngest.lol \
  --request-timeout=15s -n inngest get deployments
```

The context supplies the correct CA and the TLS server name preserves hostname
verification. Never add `--insecure-skip-tls-verify`. Keep these overrides local
to the command; close the temporary tunnel when finished.
