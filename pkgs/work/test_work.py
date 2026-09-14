"""Check failure handling and command boundaries without cloud credentials."""

from contextlib import redirect_stdout
import importlib.util
from io import StringIO
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("work", sys.argv.pop(1))
work = importlib.util.module_from_spec(spec)
sys.modules["work"] = work
spec.loader.exec_module(work)


def response(code=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], code, stdout, stderr)


def eks_config(account="836356947314", context=None):
    arn = f"arn:aws:eks:us-east-2:{account}:cluster/main"
    return {
        "contexts": [{"name": context or arn, "context": {"cluster": arn, "user": arn}}],
        "clusters": [{"name": arn, "cluster": {"server": "https://EXAMPLE.gr7.us-east-2.eks.amazonaws.com"}}],
        "users": [{"name": arn}],
    }


class AccessChecks(unittest.TestCase):
    def test_wrong_aws_account_is_not_success(self):
        with patch.object(work, "capture", return_value=response(stdout='{"Account":"wrong"}')):
            self.assertEqual(work.probe("aws").state, "IDENTITY")

    def test_wrong_tailnet_is_not_success(self):
        value = {"BackendState": "Running", "CurrentTailnet": {"MagicDNSSuffix": "personal.example"}}
        with patch.object(work, "capture", return_value=response(stdout=json.dumps(value))):
            self.assertEqual(work.probe("tailscale").state, "IDENTITY")

    def test_missing_and_expired_credentials_request_login(self):
        for error in ["Error loading SSO Token: Token for inngest does not exist",
                      "SSO session has expired", "must run 'pscale auth login'",
                      "401 Unauthorized"]:
            with self.subTest(error=error), patch.object(work, "capture", return_value=response(1, stderr=error)):
                self.assertEqual(work.probe("aws", "staging").state, "LOGIN")

    def test_forbidden_does_not_trigger_browser_login(self):
        with patch.object(work.socket, "gethostname", return_value="muninn"), \
             patch.object(work, "capture", return_value=response(1, stderr="403 Forbidden token=secret")), \
             patch.object(work, "interactive") as interactive, redirect_stdout(StringIO()) as output:
            self.assertEqual(work.login("dd", "prod"), 1)
            interactive.assert_not_called()
            self.assertNotIn("secret", output.getvalue())

    def test_read_only_credential_cache_does_not_request_login(self):
        with patch.object(work.socket, "gethostname", return_value="muninn"), \
             patch.object(work, "capture", return_value=response(1, stderr="auth login failed: [Errno 30] Read-only file system")), \
             patch.object(work, "interactive") as interactive, redirect_stdout(StringIO()):
            self.assertEqual(work.probe("gcp").state, "LOCAL")
            self.assertEqual(work.login("gcp", "prod"), 1)
            interactive.assert_not_called()

    def test_valid_auth_skips_login(self):
        with patch.object(work.socket, "gethostname", return_value="muninn"), \
             patch.object(work, "probe", return_value=work.Result("OK", "ready")), \
             patch.object(work, "interactive") as interactive, redirect_stdout(StringIO()):
            self.assertEqual(work.login("all", "prod"), 0)
            interactive.assert_not_called()

    def test_setup_refuses_to_switch_odins_tailnet(self):
        with patch.object(work.socket, "gethostname", return_value="odin"), \
             patch.object(work, "interactive") as interactive:
            with self.assertRaises(SystemExit):
                work.login("tailscale", "prod", force=True)
            interactive.assert_not_called()

    def test_doctor_suppresses_response_payloads(self):
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(work.Path, "home", return_value=Path(temp)), \
             patch.object(work, "capture", return_value=response(1, stderr="unexpected error SECRET_PAYLOAD")), \
             patch.object(work, "network_probe", return_value=work.Result("CHECK", "offline")), \
             patch.object(work, "interactive") as interactive, redirect_stdout(StringIO()) as output:
            self.assertEqual(work.doctor("prod"), 1)
            interactive.assert_not_called()
            self.assertNotIn("SECRET_PAYLOAD", output.getvalue())

    def test_missing_kubeconfig_does_not_fall_back_to_default_cluster(self):
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(work.Path, "home", return_value=Path(temp)), \
             patch.object(work, "capture") as capture:
            self.assertEqual(work.probe("kube").state, "SETUP")
            capture.assert_not_called()

    def test_kube_setup_verifies_identity_before_writing(self):
        with patch.object(work.socket, "gethostname", return_value="muninn"), \
             patch.object(work, "probe", return_value=work.Result("IDENTITY", "wrong account")), \
             patch.object(work, "interactive") as interactive, redirect_stdout(StringIO()):
            self.assertEqual(work.kube_config("prod"), 1)
            interactive.assert_not_called()

    def test_probes_are_bounded_reads(self):
        dd = work.probe_command("dd", "prod")
        self.assertIn("--read-only", dd)
        self.assertEqual(dd[2:4], ["metrics", "query"])
        self.assertIn("--limit=1", work.probe_command("gcp", "prod"))
        self.assertEqual(work.probe_command("pscale", "prod")[1:3], ["insights", "queries"])

    def test_imported_eks_context_is_used_without_writes(self):
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(work.Path, "home", return_value=Path(temp)), \
             patch.object(work, "capture", side_effect=[response(stdout=json.dumps(eks_config())), response()]) as capture:
            config = Path(temp) / ".kube/config"
            config.parent.mkdir()
            config.write_text("existing configuration")
            self.assertEqual(work.probe("kube").state, "OK")
            command = capture.call_args.args[0]
            self.assertIn(str(config), command)
            self.assertIn("arn:aws:eks:us-east-2:836356947314:cluster/main", command)
            self.assertIn("--request-timeout=10s", command)
            self.assertEqual(command[-3:], ["get", "deployments", "--output=name"])
            self.assertEqual(config.read_text(), "existing configuration")
            self.assertEqual(list(config.parent.iterdir()), [config])

    def test_wrong_eks_cluster_is_rejected_before_api_request(self):
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(work.Path, "home", return_value=Path(temp)), \
             patch.object(work, "capture", return_value=response(stdout=json.dumps(eks_config("909933634258", "prod")))) as capture:
            config = Path(temp) / ".kube/work-prod"
            config.parent.mkdir()
            config.touch()
            self.assertEqual(work.probe("kube").state, "IDENTITY")
            self.assertEqual(capture.call_count, 1)

    def test_both_staging_profiles_use_imported_context(self):
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(work.Path, "home", return_value=Path(temp)), \
             patch.object(work, "capture", return_value=response(stdout=json.dumps(eks_config("909933634258")))):
            config = Path(temp) / ".kube/config"
            config.parent.mkdir()
            config.touch()
            for profile in ("stage", "staging"):
                with self.subTest(profile=profile):
                    command = work.kube_command("kube", profile)
                    self.assertIn("arn:aws:eks:us-east-2:909933634258:cluster/main", command)

    def test_dedicated_kubeconfig_still_works(self):
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(work.Path, "home", return_value=Path(temp)), \
             patch.object(work, "capture", return_value=response(stdout=json.dumps(eks_config(context="prod")))):
            config = Path(temp) / ".kube/work-prod"
            config.parent.mkdir()
            config.touch()
            command = work.kube_command("kube", "prod")
            self.assertIn(str(config), command)
            self.assertEqual(command[command.index("--context") + 1], "prod")

    def test_ashburn_requires_expected_endpoint_and_uses_working_oidc_user(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(work.Path, "home", return_value=Path(temp)):
            config = Path(temp) / ".kube/config"
            config.parent.mkdir()
            config.touch()
            for service, (context, endpoint) in work.ASHBURN.items():
                for server in (endpoint, "https://unexpected.example"):
                    with self.subTest(service=service, server=server):
                        metadata = {
                            "contexts": [{"name": context, "context": {"cluster": "cluster", "user": "other"}}],
                            "clusters": [{"name": "cluster", "cluster": {"server": server}}],
                            "users": [{"name": "na-ashburn"}],
                        }
                        with patch.object(work, "capture", return_value=response(stdout=json.dumps(metadata))):
                            command = work.kube_command(service, "prod")
                        if server != endpoint:
                            self.assertEqual(command.state, "IDENTITY")
                        else:
                            self.assertEqual(command[command.index("--user") + 1], "na-ashburn")
                            self.assertEqual(command[-3:], ["get", "deployments", "--output=name"])

    def test_timeout_terminates_child_callback_process(self):
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / "orphan"
            child = "import pathlib,time; time.sleep(2); pathlib.Path(" + repr(str(marker)) + ").touch()"
            parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-P','-c'," + repr(child) + "]); time.sleep(30)"
            with self.assertRaises(subprocess.TimeoutExpired):
                work.capture([sys.executable, "-P", "-c", parent], timeout=1)
            time.sleep(1.4)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
