import base64
import contextlib
import hashlib
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import ssl
import stat
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("mobile_bridge", Path(__file__).parents[1] / "scripts/mobile_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class SnapshotTests(unittest.TestCase):
    def test_preferences_read_failure_does_not_export_unknown_visibility(self):
        with patch.object(bridge, "command", side_effect=bridge.BridgeError("failure")):
            with self.assertRaises(bridge.BridgeError):
                bridge.snapshot()

    def test_allowlist_preserves_metrics_and_timestamps_without_connections(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = {
                "id": "pearl", "name": "Pearl", "status": "partial", "updatedAt": 100,
                "checkedAt": 200, "configKey": "never-export", "error": "never-export",
                "url": "https://never-export", "source": "never-export", "apiKey": "never-export",
                "pearl": {"hashrate7d": 123.5, "walletBalance": 12, "averageWindow": "7d",
                          "privateKey": "never-export", "payouts": [{"id": "one", "date": 99,
                          "amount": 2, "status": "paid", "token": "never-export"}]},
            }
            Path(directory, "pearl.json").write_text(json.dumps(payload))
            raw = {"pearl": {"walletAddress": "never-export", "workerName": "never-export", "averageWindow": "7d"},
                   "power": {"currency": "EUR", "pricePerKWh": 0.32, "devices": [
                       {"id": "meter", "name": "Socket", "assignment": "pearl", "address": "never-export",
                        "serial": "never-export", "token": "never-export"}]}}
            result = bridge.snapshot(directory, raw, now=500)
            self.assertNotIn("never-export", json.dumps(result))
            pearl = next(item for item in result["providers"] if item["id"] == "pearl")
            self.assertEqual(pearl["updatedAt"], 100)
            self.assertEqual(pearl["checkedAt"], 200)
            self.assertEqual(pearl["status"], "partial")
            self.assertEqual(pearl["pearl"]["hashrate7d"], 123.5)
            self.assertEqual(result["generatedAt"], 500)
            meter = result["preferences"]["power"]["devices"][0]
            self.assertEqual(meter["assignment"], "pearl")
            self.assertEqual(meter["address"], "")
            self.assertEqual(meter["serial"], "")
            self.assertEqual(result["preferences"]["power"]["pricePerKWh"], 0.32)

    def test_disabled_and_unrelated_cache_files_are_not_read(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "credentials.json").write_text('{"token":"never-export"}')
            with patch.object(bridge, "read_private_file", wraps=bridge.read_private_file) as read:
                result = bridge.snapshot(directory, {"providers": {"vast": {"enabled": False}}})
            self.assertNotIn("vast", [item["id"] for item in result["providers"]])
            self.assertEqual({call.args[0].name for call in read.call_args_list},
                             {key + ".json" for key in bridge.NAMES if key != "vast"})

    def test_invalid_and_symbolic_cache_files_do_not_leak_or_break_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "pearl.json").write_text('{"id":"pearl","status":"ok","pearl":{"hashrate":NaN}}')
            Path(directory, "claude.json").symlink_to("pearl.json")
            Path(directory, "kraken.json").write_text('{"id":"kraken","kraken":{"currency":"EUR","assets":[{}]}}')
            result = bridge.snapshot(directory, {})
            self.assertTrue(all(item["status"] == "disconnected" for item in result["providers"]))

    def test_required_nested_shapes_preserve_all_provider_families(self):
        with tempfile.TemporaryDirectory() as directory:
            payloads = {
                "codex": {"windows": [{"id": "five", "label": "5h", "usedPercent": 0, "resetAt": 900}]},
                "claude": {"windows": [{"id": "weekly", "label": "Week", "usedPercent": 100, "main": True}]},
                "cursor": {"billingStart": 1, "billingEnd": 2},
                "vast": {"machines": [{"id": "m", "name": "GPU", "gpu": "5090", "status": "online", "running": 0}],
                         "daily": [{"day": 1, "amount": 0}], "earningsBreakdown": {"gpu": 1, "storage": 2, "network": 3, "adjustments": 4}},
                "pearl": {"pearl": {"priceUSD": None, "hashrate7d": 0, "walletBalance": 0}},
                "power": {"powerDevices": [{"id": "m", "name": "Power", "watts": -50, "status": "ok", "updatedAt": 10}]},
                "kraken": {"kraken": {"currency": "EUR", "totalValue": None, "assets": [
                    {"symbol": "BTC", "amount": 0.1, "earn": 0, "decimals": 8, "fiat": False,
                     "route": [{"symbol": "BTC/EUR", "invert": False}]}]}},
            }
            for identifier, values in payloads.items():
                Path(directory, identifier + ".json").write_text(json.dumps({"id": identifier, "status": "ok", **values}))
            result = bridge.snapshot(directory, {})
            self.assertEqual(len(result["providers"]), 7)
            self.assertTrue(all(item["status"] == "ok" for item in result["providers"]))
            for item in result["providers"]:
                for key, expected in payloads[item["id"]].items():
                    self.assertEqual(item[key], expected)

    def test_oversized_cache_is_not_parsed(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "codex.json").write_bytes(b"x" * (bridge.MAX_FILE_BYTES + 1))
            result = bridge.snapshot(directory, {})
            self.assertEqual(result["providers"][0]["status"], "disconnected")


class PairingAndServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temporary.name) / "Mobile"
        cls.pairing = bridge.setup(cls.directory, host="test-mac.local")

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_identity_is_private_stable_and_correctly_pinned(self):
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        for name in ("pairing.local.json", "certificate.pem", "private-key.pem"):
            self.assertEqual(stat.S_IMODE((self.directory / name).stat().st_mode), 0o600)
        second = bridge.setup(self.directory, host="test-mac.local")
        self.assertEqual(second, self.pairing)
        self.assertEqual(self.pairing["certificateSHA256"], bridge.certificate_digest(self.directory / "certificate.pem"))
        self.assertEqual(self.pairing["endpoint"], "https://test-mac.local:8943")

    def test_tls_auth_fixed_route_no_cors_and_suppressed_logs(self):
        expected = {"version": 1, "providers": [], "preferences": {}, "generatedAt": 123}
        server = bridge.make_server(self.directory, "127.0.0.1", 0, lambda: expected)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        output = io.StringIO()
        try:
            self.assertEqual(server.tls_context.minimum_version, ssl.TLSVersion.TLSv1_2)
            # A verified pinned-leaf client intentionally bypasses PKI hostname validation;
            # production iOS compares the challenge's certificate DER digest to its pairing.
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            with contextlib.redirect_stderr(output), contextlib.redirect_stdout(output):
                for method, path, auth, expected_status in (
                    ("GET", "/v1/snapshot", None, 401),
                    ("GET", "/v1/snapshot", "Bearer wrong", 401),
                    ("GET", "/v1/snapshot?token=never-export", None, 404),
                    ("GET", "/private-key.pem", None, 404),
                    ("OPTIONS", "/v1/snapshot", None, 404),
                    ("POST", "/v1/snapshot", None, 404),
                    ("PROPFIND", "/v1/snapshot", None, 404),
                    ("GET", "/v1/snapshot", "Bearer " + self.pairing["token"], 200),
                ):
                    client = http.client.HTTPSConnection("127.0.0.1", server.server_port, context=context, timeout=5)
                    client.connect()
                    self.assertEqual(hashlib.sha256(client.sock.getpeercert(binary_form=True)).hexdigest(),
                                     self.pairing["certificateSHA256"])
                    client.request(method, path, headers={"Authorization": auth} if auth else {})
                    response = client.getresponse()
                    self.assertEqual(response.status, expected_status)
                    self.assertIsNone(response.getheader("Access-Control-Allow-Origin"))
                    payload = response.read()
                    if expected_status == 200:
                        self.assertEqual(json.loads(payload), expected)
                    client.close()
            self.assertEqual(output.getvalue(), "")
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)

    def test_pairing_command_never_prints_url_or_external_diagnostics(self):
        completed = subprocess.CompletedProcess([], 0, stdout=b"sensitive command output", stderr=b"")
        output = io.StringIO()
        with patch.object(subprocess, "run", return_value=completed) as run, contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            bridge.pair_device("test-device", self.directory, "dev.example.mobile")
        arguments = run.call_args.args[0]
        self.assertIn("--payload-url", arguments)
        self.assertIn("--terminate-existing", arguments)
        self.assertIn("--accept-pairing-launch", arguments)
        url = arguments[arguments.index("--payload-url") + 1]
        self.assertEqual(arguments[arguments.index("--pairing-digest") + 1], hashlib.sha256(url.encode()).hexdigest())
        payload = url.split("payload=")[1]
        decoded = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        self.assertEqual(decoded, self.pairing)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(run.call_args.kwargs["stderr"], subprocess.DEVNULL)

    def test_failures_do_not_include_external_output(self):
        failed = subprocess.CompletedProcess([], 1, stdout=b"secret-token", stderr=b"")
        with patch.object(subprocess, "run", return_value=failed):
            with self.assertRaises(bridge.BridgeError) as result:
                bridge.pair_device("test-device", self.directory)
        self.assertNotIn("secret-token", str(result.exception))

    def test_invalid_host_cannot_inject_url_or_certificate_arguments(self):
        for host in ("user:pass@host", "mac.local/path", "-option", "host\nCN=other", "host?token=secret"):
            with self.assertRaises(bridge.BridgeError):
                bridge.valid_host(host)


if __name__ == "__main__":
    unittest.main()
