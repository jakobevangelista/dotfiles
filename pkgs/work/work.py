"""Muninn's work access checks and browser-login entry points.

Doctor makes bounded read requests. It never prints API responses, query data,
or credentials. Login and kube-config are explicit local setup operations.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import sys

ACCOUNTS = {"prod": "836356947314", "stage": "909933634258", "staging": "909933634258"}
ASHBURN = {
    "kube-na": ("k8s-oidc", "https://kube-api-1ee4e8d5.infra.inngest.lol:8443"),
    "kube-rs": ("rs-ashburn", "https://iad-rs-kube.infra.inngest.lol:8443"),
}
PROJECT = "peerless-truck-309218"
EMAIL = "jakob@inngest.com"
TAILNET = "tail2dd48.ts.net"
BASTION = "bastion-aws-prod." + TAILNET
SERVICES = ("aws", "gcp", "dd", "pscale")
ENV = {
    "AWS_PAGER": "",
    "AWS_CLI_AUTO_PROMPT": "off",
    "DD_TOKEN_STORAGE": "file",
    "DD_SITE": "datadoghq.com",
    "CLOUDSDK_CORE_DISABLE_PROMPTS": "1",
}


@dataclass
class Result:
    state: str
    detail: str


def capture(command, timeout=25):
    # A timed-out kubectl can leave its OIDC callback server behind. Bound the
    # whole process group, and never open a browser during diagnostic probes.
    with subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env={**os.environ, **ENV, "BROWSER": "false"},
        stdin=subprocess.DEVNULL, start_new_session=True,
    ) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def kube_file(profile):
    return str(Path.home() / ".kube" / ("work-" + profile))


def kube_command(service, profile):
    imported = str(Path.home() / ".kube/config")
    if service == "kube":
        arn = f"arn:aws:eks:us-east-2:{ACCOUNTS[profile]}:cluster/main"
        candidates = [(imported, arn), (kube_file(profile), profile)]
    else:
        candidates = [(imported, ASHBURN[service][0])]
    for filename, context_name in candidates:
        if not Path(filename).is_file():
            continue
        response = capture(["kubectl", "--kubeconfig", filename,
                            "config", "view", "--output=json"])
        if response.returncode:
            return Result("CHECK", "Cannot read kubeconfig metadata: " + filename)
        data = json.loads(response.stdout)
        if not isinstance(data, dict):
            return Result("CHECK", "Unexpected kubeconfig metadata")
        contexts = {item["name"]: item["context"] for item in data.get("contexts", [])}
        if context_name not in contexts:
            continue
        context = contexts[context_name]
        clusters = {item["name"]: item["cluster"] for item in data.get("clusters", [])}
        server = clusters.get(context["cluster"], {}).get("server", "").rstrip("/")
        if service == "kube":
            if context["cluster"] != arn or not re.fullmatch(
                r"https://[A-Za-z0-9.-]+\.eks\.amazonaws\.com", server
            ):
                return Result("IDENTITY", "Kubernetes cluster does not match " + profile)
        elif server != ASHBURN[service][1]:
            return Result("IDENTITY", "Kubernetes endpoint does not match " + context_name)
        command = ["kubectl", "--kubeconfig", filename, "--context", context_name]
        if service in ASHBURN:
            if "na-ashburn" not in {item["name"] for item in data.get("users", [])}:
                return Result("SETUP", "Missing na-ashburn OIDC user")
            command += ["--user", "na-ashburn"]
        return command + ["--request-timeout=10s", "--namespace", "inngest",
                          "get", "deployments", "--output=name"]
    detail = "Run: work kube-config " + profile if service == "kube" else "Missing " + ASHBURN[service][0] + " context"
    return Result("SETUP", detail)


def probe_command(service, profile):
    if service == "aws":
        return ["aws", "--profile", profile, "--region", "us-east-2",
                "sts", "get-caller-identity", "--output", "json"]
    if service == "gcp":
        return ["gcloud", "logging", "read", 'severity>=DEFAULT',
                "--account=" + EMAIL, "--project=" + PROJECT,
                "--freshness=5m", "--limit=1", "--format=json"]
    if service == "dd":
        return ["pup", "--read-only", "metrics", "query", "--query",
                "avg:system.uptime{host:pgbouncer*}", "--from", "5m",
                "--to", "now", "--output", "json"]
    if service == "pscale":
        return ["pscale", "insights", "queries", "cloud-prod", "main",
                "--org", "inngest", "--period", "1h", "--limit", "1",
                "--format", "json"]
    if service == "kube" or service in ASHBURN:
        return kube_command(service, profile)
    if service == "tailscale":
        return ["tailscale", "status", "--json"]
    if service == "ssh":
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
                "prod-bastion", "true"]
    raise ValueError(service)


def probe(service, profile="prod"):
    tool = "kubectl" if service == "kube" or service in ASHBURN else {
        "gcp": "gcloud", "dd": "pup",
    }.get(service, service)
    try:
        command = probe_command(service, profile)
        if isinstance(command, Result):
            return command
        response = capture(command)
    except FileNotFoundError:
        return Result("MISSING", tool + " is not installed")
    except subprocess.TimeoutExpired:
        return Result("CHECK", "Timed out; check connectivity before logging in again")
    except (ValueError, KeyError, TypeError):
        return Result("CHECK", "Unexpected kubeconfig metadata")
    if response.returncode:
        # Classify errors without echoing potentially sensitive CLI output.
        error = (response.stderr + response.stdout).lower()
        if re.search(r"read-only file system|\berofs\b|\berrno 30\b", error):
            return Result("LOCAL", "Local credential cache is read-only; allow cache writes before retrying")
        if re.search(r"accessdenied|permission.denied|forbidden|\b403\b|insufficient.scope", error):
            return Result("ACCESS", "Read denied; check permissions, identity, and scopes")
        if re.search(r"not logged in|not authenticated|unauthenticated|unauthorized|\b401\b|"
                     r"expired|invalid.grant|auth login|sso login|no.*credentials|"
                     r"unable to locate credentials|no.*token|token.*does not exist", error):
            hint = ("work login " + service + (" --profile " + profile if service == "aws" else "")) if service in SERVICES else "Check the service login"
            return Result("LOGIN", hint)
        return Result("CHECK", "Read failed; inspect with: " + shlex.join(command))
    if service in ("aws", "tailscale"):
        try:
            data = json.loads(response.stdout)
        except (ValueError, TypeError):
            return Result("CHECK", "Unexpected response; identity was not verified")
        if not isinstance(data, dict):
            return Result("CHECK", "Unexpected response; identity was not verified")
        if service == "aws":
            if data.get("Account") != ACCOUNTS[profile]:
                return Result("IDENTITY", "AWS account does not match " + profile)
            return Result("OK", "Account " + ACCOUNTS[profile] + "; caller identity verified")
        if data.get("BackendState") != "Running":
            return Result("LOGIN", "Run in Muninn: work login tailscale")
        if data.get("CurrentTailnet", {}).get("MagicDNSSuffix") != TAILNET:
            return Result("IDENTITY", "Work tailnet is not selected; run: work login tailscale")
        if not data.get("Self", {}).get("Online"):
            return Result("CHECK", "Work tailnet selected, but the device is offline")
        return Result("OK", "Connected to the work tailnet")
    return Result("OK", {
        "gcp": "Logs read permitted for " + EMAIL + " in " + PROJECT,
        "dd": "Read-only metrics query succeeded on datadoghq.com",
        "pscale": "Insights read permitted for inngest/cloud-prod/main",
        "kube": profile + ": deployment list permitted in inngest",
        "kube-na": "NetActuate: deployment list permitted in inngest",
        "kube-rs": "Rackspace: deployment list permitted in inngest",
        "ssh": "Bastion SSH authentication succeeded",
    }[service])


def network_probe():
    try:
        with socket.create_connection((BASTION, 22), timeout=5):
            return Result("OK", "Work bastion SSH port reachable")
    except OSError:
        return Result("CHECK", "Work bastion DNS/port unreachable; check tailnet and ACLs")


def doctor(profile):
    names = ["tailscale", "network", *SERVICES, "kube", *ASHBURN, "ssh"]
    print("Work access on " + socket.gethostname() + " (AWS/EKS: " + profile + ")", flush=True)
    print("Datadog, PlanetScale, and Ashburn checks target production; API payloads are suppressed.", flush=True)
    identity = probe("aws", profile)
    def check(name):
        if name == "aws":
            return identity
        if name == "kube" and identity.state != "OK":
            return Result("CHECK", "AWS identity must pass before the Kubernetes read")
        return network_probe() if name == "network" else probe(name, profile)
    with ThreadPoolExecutor(max_workers=len(names)) as pool:
        results = list(pool.map(check, names))
    for name, result in zip(names, results):
        print(f"{result.state:8} {name:10} {result.detail}")
    return int(any(result.state != "OK" for result in results))


def require_muninn():
    if socket.gethostname().split(".")[0] != "muninn":
        raise SystemExit("Run this setup command inside Muninn: ssh muninn")


def interactive(command):
    # Login owns its terminal and browser instructions. Never capture or save
    # credentials or authorization codes in our own files.
    return subprocess.call(command, env={**os.environ, **ENV})


def login(service, profile, force=False):
    require_muninn()
    if service == "tailscale":
        if probe("tailscale").state == "OK" and not force:
            print("Already connected to the work tailnet")
            return 0
        print("Select your Inngest work account in the browser. Private SSH through Odin stays available.", flush=True)
        status = interactive([
            "/run/wrappers/bin/sudo", "tailscale", "login", "--accept-dns=true", "--accept-routes=true",
            "--advertise-exit-node=false", "--advertise-routes=", "--exit-node=",
            "--ssh=true", "--netfilter-mode=off", "--timeout=5m",
        ])
        if status:
            return status
        after = probe("tailscale")
        print(after.state + ": " + after.detail)
        return int(after.state != "OK")
    commands = {
        "aws": ["aws", "sso", "login", "--profile", profile, "--use-device-code", "--no-browser"],
        "gcp": ["gcloud", "auth", "login", EMAIL, "--no-launch-browser"],
        "dd": ["pup", "auth", "login", "--site", "datadoghq.com", "--read-only", "--callback-port", "8000"],
        "pscale": ["pscale", "auth", "login", "--format", "json"],
    }
    failed = False
    for name in SERVICES if service == "all" else [service]:
        print(name + ": checking current access (up to 25 seconds)...", flush=True)
        before = probe(name, profile)
        if before.state == "OK" and not force:
            print(name + ": already usable; skipping login", flush=True)
            continue
        if before.state != "LOGIN" and not force:
            print(f"{name}: {before.state}: {before.detail}", flush=True)
            print("If reauthentication is needed, run: work login " + name + " --force", flush=True)
            failed = True
            continue
        if name == "dd":
            print("Keep this tunnel open in a Mac terminal first:", flush=True)
            print("  ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:8000:127.0.0.1:8000 muninn", flush=True)
        if interactive(commands[name]):
            failed = True
            continue
        after = probe(name, profile)
        print(f"{name}: {after.state}: {after.detail}", flush=True)
        failed |= after.state != "OK"
    return int(failed)


def kube_config(profile):
    require_muninn()
    identity = probe("aws", profile)
    if identity.state != "OK":
        print(identity.state + ": " + identity.detail)
        return 1
    target = Path(kube_file(profile))
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.umask(0o077)
    return interactive([
        "aws", "--profile", profile, "--region", "us-east-2", "eks", "update-kubeconfig",
        "--name", "main", "--role-arn", "arn:aws:iam::" + ACCOUNTS[profile] + ":role/EKSAdminAccess",
        "--alias", profile, "--user-alias", "work-" + profile, "--kubeconfig", str(target),
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("doctor", help="Read-only network, identity, and API checks")
    check.add_argument("--profile", choices=ACCOUNTS, default="prod")
    auth = sub.add_parser("login", help="Browser logins for services that need authentication")
    auth.add_argument("service", choices=["all", *SERVICES, "tailscale"], nargs="?", default="all")
    auth.add_argument("--profile", choices=ACCOUNTS, default="prod")
    auth.add_argument("--force", action="store_true", help="Explicitly reauthenticate even if the probe cannot identify an auth failure")
    kube = sub.add_parser("kube-config", help="Read EKS metadata and write a dedicated local kubeconfig")
    kube.add_argument("profile", choices=ACCOUNTS)
    args = parser.parse_args()
    if args.command == "doctor":
        return doctor(args.profile)
    if args.command == "login":
        return login(args.service, args.profile, args.force)
    return kube_config(args.profile)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
