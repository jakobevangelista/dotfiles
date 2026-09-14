# Work access from Muninn

Muninn is the intended work workstation. Odin stays on the personal tailnet;
Muninn joins the work tailnet and makes its own work connections. The Mac's
`ssh muninn` alias connects through Odin to `10.88.0.10`, so changing Muninn's
tailnet does not remove this private SSH path.

The configuration lives in `modules/home/muninn-work.nix`. It adds GCP,
Datadog, PlanetScale, and the `work` helper alongside the existing AWS and
Kubernetes tools. Datadog Pup is packaged explicitly: nixpkgs' `pup` is an
unrelated HTML tool. PlanetScale is pinned to the version used for the
2026-09-18 Insights investigation.

## Verified setup, 2026-09-26

Home Manager is active (`Result=success`) and the installed `work` helper
matches the checked-in source. A fresh login shell loads the shared AWS SSO
profiles, `DD_TOKEN_STORAGE=file`, GCP project, and merged `KUBECONFIG`.
Read probes passed for the work tailnet, bastion TCP port, production AWS
identity, GCP logs, Datadog metrics, PlanetScale Insights, EKS, NetActuate,
and Rackspace. SSH authentication subsequently passed as `jakob` on the
bastion and both PgBouncer hosts using the existing personal work key through
the Mac's 1Password agent. Both PgBouncer services reported `active`.
No production key configuration or service state was changed.

The existing `simcity-macbook` SSH block was preserved in `~/.ssh/config.local`.
Private AWS/SSH backups are in
`~/.local/state/muninn/work-setup-20260926-_yndnnwn/`. The imported kubeconfig
was retained. No private keys or cloud credential caches were copied.

The guest and helper builds passed on Odin, and the helper's 17 regression
tests passed again before committing. Full flake evaluation also passed inside
Muninn on 2026-09-26 with `nix flake check --no-build --no-update-lock-file`
outside the agent sandbox. Earlier shared-store directory reads returned
`ENOMEM`; guest manifest builds were last verified on Odin, which remains the
preferred build location. The evaluation check did not build or activate a system.

Selected next-boot manifest, confirmed from Odin:

```text
/nix/store/0k4838hy5wff9jd0fdwdjy9d1qhdi76l-muninn-manifest.json
```

Odin's GC root is `~/.local/state/muninn/work-access-manifest-20260926`.
The previous selection was
`/nix/store/14v0cb6rc1g27q9l1cs5gpnszp64mvq4-muninn-manifest.json`.
Only the guest user environment was activated live; the full guest system
was not switched or rebooted. Its temporary Home Manager override is
`/run/systemd/system/home-manager-jakob.service.d/90-work-access.conf`;
the selected manifest supplies the same environment on the next boot.
The live guest closure is pinned at
`/nix/var/nix/gcroots/muninn-work-access-20260926`.

Muninn was left running at 2 vCPUs and 4 GiB RAM. Docker remains stopped.
No VM resource allocation, startup policy, or state disk was changed.
A deliberate restart remains the final persistence check; finish active
Muninn work before running `muninn restart` on Odin.

The `using-muninn` skill was refreshed on 2026-09-26 and its installed
`~/.codex/skills/using-muninn` link now points directly to the shared dotfiles
source. The selected Home Manager snapshot predates this documentation update;
reactivating it may restore the older skill until a normal rebuild incorporates
the updated source. No VM restart was needed for the documentation refresh.

## Build and activate

From Odin, build before activation:

```sh
cd ~/dotfiles
nix flake check --no-build --no-update-lock-file "path:$PWD"
nix build --no-link --no-update-lock-file "path:$PWD#muninn-manifest"
nix build --no-link --no-update-lock-file "path:$PWD#nixosConfigurations.odin.config.system.build.toplevel"
```

Before activating, inspect existing Muninn `~/.aws/config` and `~/.ssh/config`
for local configuration that needs preserving. Home Manager refuses to
overwrite unmanaged files; resolve conflicts deliberately. Extra private SSH
configuration may go in `~/.ssh/config.local`. Preserve the existing
`simcity-macbook` block there before activating, without overwriting an
existing local include. Back up both unmanaged files in Muninn's private
home first. The managed AWS file retains all imported profile names.

When ready to activate on Odin:

```sh
sudo nixos-rebuild switch --flake "path:$HOME/dotfiles#odin" --no-update-lock-file
```

If Muninn is stopped, run `muninn start`. If it is running, finish active work
and run `muninn restart` to load the new guest manifest. This preserves the
existing state disk. No work credentials are copied from Odin or the Mac.
Muninn remains manual-start until access has been validated across a restart.

## Enroll the work tailnet

From the Mac, keep an Odin connection available, then run:

```sh
ssh -t muninn work login tailscale
```

Choose the Inngest work account in the browser and complete any normal device
approval. The helper verifies the expected work tailnet suffix,
`tail2dd48.ts.net`, after login. It refuses to run setup on a host other than
Muninn. Ordinary `work login` does not change Tailscale accounts.

The guest accepts work-tailnet subnet routes. Ashburn Kubernetes APIs need
the advertised IPv6 networks; with acceptance disabled, their API connections
failed even after tailnet enrollment. The verified fix is
`sudo tailscale set --accept-routes=true` inside Muninn. The guest Nix config
and updated login helper preserve it. Odin and the Mac stay on the personal
tailnet. PgBouncer continues to use its configured SSH jump through the bastion.

## Browser logins

Run this in the Mac terminal to forward Datadog's callback directly into
Muninn and start the service logins there:

```sh
ssh -t -o ExitOnForwardFailure=yes -L 127.0.0.1:8000:127.0.0.1:8000 muninn work login
```

Open the printed links in the Mac's browser. Enter any authorization code in
the requesting terminal, never in chat. The CLI credentials are saved inside
Muninn. Datadog uses read-only OAuth and file storage so SSH sessions do not
depend on an unlocked desktop keyring. PlanetScale uses its Linux credential
backend; verify it again from a fresh SSH session after login.

For an individual service, inside Muninn:

```sh
work login aws
work login gcp
work login dd
work login pscale
```

If the Mac's `ssh muninn` command produces no output, first use the known
working route from an Odin terminal:

```sh
muninn ssh
hostname
```

After `hostname` prints `muninn`, run the login commands in that shell.
GCP uses a link and an authorization code; PlanetScale prints its browser
login instructions. Neither requires a browser installed in the guest.

Datadog still needs the Mac-to-Muninn port 8000 tunnel. If it is not already
part of the SSH session, keep this running in another Mac terminal:

```sh
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:8000:127.0.0.1:8000 muninn
```

The helper skips services whose read probes succeed. Permission failures and
network errors do not automatically trigger login. `work login SERVICE
--force` explicitly starts a new login when the probe cannot identify the
authentication error, or when changing accounts/scopes.

AWS profiles `prod`, `stage`, `staging`, `sandbox`, `operations`, and
`SystemAdministrator-836356947314` share the
`inngest` SSO session, which supports token refresh. They retain the existing
`SystemAdministrator` permission set: they are not read-only IAM roles.
`stage` and `staging` select the same staging account; the imported EKS
context continues to use `stage`.
Organization session limits still require periodic browser reauthentication.

## Kubernetes

On 2026-09-24, Odin's AWS profile and Kubernetes context definitions were
copied into Muninn's private `~/.aws/config` and `~/.kube/config` at Jakob's
request. They persist across VM restarts but are snapshots, not live shares.
No login tokens were copied; subsequent AWS and Cognito browser logins created
guest-local sessions, and deployment reads passed against all three production
clusters. The four contexts retain Odin's names (two EKS
ARNs, `k8s-oidc`, and `rs-ashburn`); the EKS exec users select `prod` and `stage`
explicitly. See the [Muninn Kubernetes access runbook](../.config/agents/skills/using-inngest-prod-kubernetes/references/muninn.md)
for verification, login, and routing prerequisites.

`work doctor` recognizes those imported EKS ARN contexts. It also checks
`k8s-oidc` and `rs-ashburn` using the working `na-ashburn` OIDC user, after
verifying their configured API endpoints. The AWS identity check gates the
EKS read; Ashburn checks use their own OIDC session. No kubeconfig is rewritten
by diagnosis, and the imported file comes first in `KUBECONFIG` to preserve
its selected context.

Separate local kubeconfigs are optional. Inside Muninn, generate them using
read-only EKS metadata requests when needed:

```sh
work kube-config prod
work kube-config staging
kubectl --context prod --namespace inngest get deployments
kubectl --context staging --namespace inngest get deployments
```

The helper checks the AWS account before writing `~/.kube/work-prod` or
`~/.kube/work-staging`. Each kubeconfig uses the matching AWS profile and
`EKSAdminAccess` role; `~/.kube/config` is not rewritten. New SSH sessions load
the imported file and the optional `work-prod`, `work-stage`, and
`work-staging` paths through `KUBECONFIG`. For an existing shell, reconnect or use
`kubectl --kubeconfig ~/.kube/work-prod --context prod ...`.

EKS token authentication uses AWS SSO. Other Kubernetes clusters may need
their own OIDC setup; the existing cloud-tools package includes
`kubelogin-oidc`.

## Bastion and PgBouncer SSH

The aliases are `prod-bastion`, `pgbouncer-b`, and `pgbouncer-c`. They select
user `jakob`, disable agent forwarding, and require the pinned host keys
verified during the 2026-09-18 investigation. The PgBouncer private addresses
are that incident's hosts; review them if the EC2 instances are replaced.

Outbound authentication needs an approved work identity. Jakob prefers the
existing personal work key in 1Password. Its source-managed public key is
in `ansible/roles/common/vars/main.yml` under user `jakob`; the fingerprint is
`SHA256:Ue9fVeyyNxSM5BbpwsngfOtELaunfJ1vLG15kDfbl1Q`.
Verify the forwarded agent contains that key before attempting authentication.
Do not substitute a shared automation key or export a private key.
Jakob confirmed that fingerprint is available in the Mac's 1Password agent
on 2026-09-26. Its public half is installed in Muninn at
`~/.ssh/id_ed25519_work.pub`. A production-host block in the private
`~/.ssh/config.local` selects that public key and
`IdentityAgent ~/.ssh/1password-agent.sock`; the existing `simcity-macbook`
block is preserved. The socket link must point to a live forwarded agent
from the current Mac connection.

On the verified connection, Muninn's OpenSSH 10.3 created its forwarded
socket under `~/.ssh/agent/s.*.sshd.*`, rather than `/tmp/ssh-*/agent.*`.
Use the session's `SSH_AUTH_SOCK` rather than assuming a directory. The Mac
login initially stopped at Muninn's host-key verification; pinning the
public host key whose fingerprint is recorded below allowed authentication.

From the Mac's local terminal, connect directly to Muninn through Odin and
forward the 1Password agent:

```sh
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh -A -S none -J odin -o HostKeyAlias=muninn -o StrictHostKeyChecking=yes -o ConnectTimeout=10 jakob@10.88.0.10
```

Then run `ssh-add -l` inside that session to inspect public fingerprints.
The verified Muninn host fingerprint on 2026-09-26 is
`SHA256:JS4C1XYuevKAN6vU+4qqKH1R76YfjHqJvBID/+XK0tI`.
Keep the session connected and approve the personal work key in 1Password
when requested. The Mac supplies signing through its SSH agent; Muninn still
uses its own work-tailnet networking. `ForwardAgent no` on the production
aliases prevents forwarding the agent onward to production hosts.
This arrangement needs the Mac connection and available 1Password agent;
cloud CLI and Kubernetes access do not depend on it. The forwarded socket is
specific to that session. After checking the expected fingerprint with
`ssh-add -l`, connect the configured path from that same Muninn shell:

```sh
test -S "$SSH_AUTH_SOCK" && ln -sfn "$SSH_AUTH_SOCK" ~/.ssh/1password-agent.sock
```

This lets the production aliases work from existing Muninn terminals and
agent sessions without changing each process's environment. Reconnect and
refresh the link if the Mac connection closes. `-S none` prevents reusing a
destination SSH connection that may have started without agent forwarding.

Agent-based authentication selects the matching public key through
`IdentityFile` and `IdentitiesOnly yes`. A guest-local private key at
`~/.ssh/id_ed25519_work` is an alternative. No private key is copied or
generated by activation, and no production authorized-keys files are changed.
If using a new key,
create it in Muninn and register its public key through the normal work
access process:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_work -C jakob@muninn-work
```

Choose the passphrase policy appropriate for the approved work identity.
An encrypted key must be unlocked in a guest SSH agent before unattended
commands can use it. An approved SSH certificate can instead be configured
in `~/.ssh/config.local`. Tailnet connectivity does not grant SSH login.

## Check access and use the CLIs

```sh
work doctor
work doctor --profile staging
aws --profile prod sts get-caller-identity
gcloud logging read 'severity>=ERROR' --freshness=1h --limit=20
pup --read-only metrics query --query 'avg:system.uptime{host:pgbouncer*}' --from 5m
pscale insights queries cloud-prod main --org inngest --period 1h --limit 20
ssh pgbouncer-b 'id -un; hostname'
```

Doctor checks the tailnet, bastion reachability, AWS identity, GCP log reads,
Datadog metrics, PlanetScale Insights, all three production Kubernetes
clusters, and bastion SSH. It
prints only status and repair instructions, suppressing API payloads and
credentials. Checks have timeouts and a nonzero exit status if any fail.
`--profile staging` changes the AWS/EKS checks; Datadog and PlanetScale probes
continue to target the production resources used during the investigation.
Doctor verifies access, not production service health.

The wrapper starts Python with `-P`: adding the whole shared `/nix/store` to
Python's import path caused an `ENOMEM` directory-read failure in Muninn.
Doctor prints its heading before checking AWS and stops a timed-out probe's
whole process group, including any OIDC callback child. Diagnostic probes
do not launch browsers. Cloud CLIs may refresh their own private credential
caches during reads; a sandbox that makes those caches read-only can cause
misleading authentication failures.
The agent sandbox also maps root-owned SSH configuration to an untrusted
owner. Recheck ownership errors outside that sandbox before changing Muninn's
normal SSH configuration.

Only the diagnostic probes are read-only. Native tools retain the privileges
of the logged-in identities. Production changes still need explicit scope
and authorization; helpers are not an IAM or Kubernetes RBAC boundary.

Cloud credential directories (`~/.aws`, `~/.config/gcloud`,
`~/.config/pup`, `~/.config/planetscale`, and `~/.kube`) live in Muninn's
private persistent home. Tokens and private keys must never go in Nix
expressions, the Nix store, shared worktrees, or diagnostic output.

After the initial logins, check from a fresh SSH session, then deliberately
restart Muninn and run `work doctor` again. Keep Odin's connection available
while validating the work-tailnet transition. A restart should preserve
credentials and device identity; it does not extend their expiration.

## References

- [AWS SSO session configuration](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)
- [Datadog OAuth and SSH callback forwarding](https://github.com/DataDog/pup/blob/v1.22.1/docs/OAUTH2.md)
- [PlanetScale authentication](https://planetscale.com/docs/cli/auth)
- [1Password SSH agent forwarding](https://developer.1password.com/docs/ssh/agent/forwarding/)
- [Selecting one 1Password SSH key](https://developer.1password.com/docs/ssh/agent/advanced/)
- [Muninn lifecycle and recovery](muninn-workstation.md)
