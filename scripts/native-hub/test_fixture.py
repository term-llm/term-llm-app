import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from urllib.request import urlopen
from urllib.error import HTTPError

from fixture_server import CORE_COMMIT, FixtureServer, LABEL, responses
from verify_capture import REQUIRED_ROUTES, verify


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.log = Path(self.temp.name) / "requests.jsonl"
        self.server = FixtureServer(("127.0.0.1", 0), self.log, stall_seconds=0.3)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def get(self, path):
        with urlopen(self.base + path, timeout=2) as result:
            return result.read()

    def test_contract_and_demo_marking(self):
        health = json.loads(self.get("/__health"))
        self.assertEqual(health["core_commit"], CORE_COMMIT)
        self.assertEqual(json.loads(self.get("/healthz"))["role"], "hub")
        nodes = json.loads(self.get("/api/nodes?view=sidebar"))["nodes"]
        self.assertEqual([n["id"] for n in nodes], ["dev", "stalled", "offline"])
        self.assertFalse(nodes[-1]["status"]["reachable"])
        self.assertEqual(nodes[0]["sessions"]["recent"][0]["resume_path"], "/node/dev/chat/2")
        self.assertNotIn("token", nodes[0])
        for path in ["/", "/node/dev/"]:
            self.assertIn(LABEL, self.get(path).decode())
        self.assertIn("data-hub-config=", self.get("/").decode())
        attention = json.loads(self.get("/api/attention"))
        self.assertEqual(attention["total_unseen"], len(attention["inbox"]))
        self.assertEqual(attention["total_input_required"], len(attention["input_required"]))
        self.assertEqual(json.loads(self.get("/api/auth/session"))["administrator"], "Demo operator")
        self.assertFalse(responses()["/api/registration-info"]["enabled"])

    def test_stall_is_real_pending_http_and_logged_before_timeout(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        start = time.monotonic()
        connection.request("GET", "/node/stalled/?secret=not-logged")
        # Wait only for the request log, proving the server received it BEFORE response.
        deadline = start + 1
        while not self.log.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(json.loads(self.log.read_text().splitlines()[0])["status"], "stalled")
        self.assertNotIn("secret", self.log.read_text())
        self.assertEqual(connection.getresponse().status, 504)
        self.assertGreaterEqual(time.monotonic() - start, 0.25)
        connection.close()

    def test_unknown_route_and_mutations_fail(self):
        with self.assertRaises(HTTPError) as error:
            self.get("/api/not-a-real-route")
        self.assertEqual(error.exception.code, 404)
        error.exception.close()
        for method in ["POST", "PATCH", "DELETE"]:
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
            connection.request(method, "/api/auth/logout")
            result = connection.getresponse()
            self.assertEqual(result.status, 405)
            result.read()
            connection.close()


class CaptureGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "screenshots").mkdir()
        for index in range(8):
            (self.root / "screenshots" / f"{index}.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        def box(kind, body):
            return (8 + len(body)).to_bytes(4, "big") + kind + body
        # Structural placeholders ONLY for validator unit tests; never capture artifacts.
        (self.root / "native-hub-demo-fixture.mp4").write_bytes(
            box(b"ftyp", b"mp42") + box(b"mdat", b"\0" * 10000) + box(b"moov", b""))
        request_entries = [dict(path=p, status="stalled" if p == "/node/stalled/chat/3" else 200)
                           for p in sorted(REQUIRED_ROUTES)]
        request_entries.append(dict(path="/api/nodes", status=200))
        (self.root / "fixture-requests.jsonl").write_text("\n".join(json.dumps(entry) for entry in request_entries))
        self.summary = self.root / "test-summary.json"
        self.summary.write_text(json.dumps(dict(result="Passed", passedTests=1, failedTests=0, skippedTests=0)))

    def tearDown(self):
        self.temp.cleanup()

    def test_complete_artifacts_pass(self):
        verify(self.root)

    def test_recorded_device_must_match_xcresult(self):
        summary = json.loads(self.summary.read_text())
        summary["devicesAndConfigurations"] = [{"device": {"deviceId": "test-device"}}]
        self.summary.write_text(json.dumps(summary))
        verify(self.root, "TEST-DEVICE")
        with self.assertRaisesRegex(ValueError, "not a clone"):
            verify(self.root, "other-device")

    def test_screenshots_without_tests_never_pass(self):
        for data in [dict(result="Passed", passedTests=0), dict(result="Failed", passedTests=1),
                     dict(result="Passed", passedTests=1, skippedTests=1), dict(result="Passed", passedTests=1, failedTests=1)]:
            self.summary.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                verify(self.root)

    def test_stalled_chat_requires_subsequent_native_refresh(self):
        log = self.root / "fixture-requests.jsonl"
        entries = log.read_text().splitlines()
        log.write_text("\n".join(entries[:-1]))
        with self.assertRaisesRegex(ValueError, "while stalled request remained pending"):
            verify(self.root)

    def test_refresh_after_stalled_response_completes_is_not_concurrency(self):
        log = self.root / "fixture-requests.jsonl"
        entries = [json.loads(line) for line in log.read_text().splitlines()]
        entries.insert(len(entries) - 1, dict(path="/node/stalled/chat/3", status=504))
        log.write_text("\n".join(json.dumps(entry) for entry in entries))
        with self.assertRaisesRegex(ValueError, "while stalled request remained pending"):
            verify(self.root)

    def test_missing_http_or_video_or_screenshot_fails(self):
        log = self.root / "fixture-requests.jsonl"
        original = log.read_text()
        log.write_text("")
        with self.assertRaises(ValueError):
            verify(self.root)
        log.write_text(original)
        video = self.root / "native-hub-demo-fixture.mp4"
        original_video = video.read_bytes()
        video.write_bytes(b"not an mp4")
        with self.assertRaises(ValueError):
            verify(self.root)
        video.write_bytes(original_video)
        (self.root / "screenshots" / "0.png").unlink()
        with self.assertRaises(ValueError):
            verify(self.root)


if __name__ == "__main__":
    unittest.main()
