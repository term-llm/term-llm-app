import copy
import json
from pathlib import Path
import tempfile
import time
import unittest
from urllib.parse import urlencode

from contract import ContractError, digest, evidence, inputs, prompt
from media import video
from capture import Capture


NONCE = "test-public-run-nonce-1234"


def configuration():
    public = dict(schema_version=1, core_commit="a" * 40, app_commit="b" * 40,
                  binary_sha256="c" * 64, container_image_digest="sha256:" + "d" * 64,
                  contain_id="owned-demo", node_id="agent",
                  ssh=dict(host="demo.invalid", user="forward-only", port=22, local_port=8877,
                           broker_port=8769, known_host="demo.invalid ssh-ed25519 AAAAtest"))
    link = "term-llm-pair://v1?" + urlencode(dict(broker="http://localhost:8877/", sid="test", hk="test", hn="test", exp=int(time.time()) + 1200)) + "#ps=test-private-psk&cap=test-private-capability"
    private = dict(schema_version=1, run_nonce=NONCE, expires_at=time.time() + 1200,
                   direct=dict(pairing_link=link, ice_servers=[dict(urls=["stun:demo.invalid:3478"])]),
                   relay=dict(pairing_link=link, ice_servers=[dict(urls=["turn:demo.invalid:3478"], username="test-user", credential="test-turn-secret")]))
    return public, private


def observed(mode="direct"):
    sample = dict(selected_pair_id="actual-pair-id", local_type="relay" if mode == "relay" else "srflx", remote_type="host", protocol="udp",
                  bytes_sent=10, bytes_received=20, data_channel_bytes_sent=5, data_channel_bytes_received=6,
                  data_channel_messages_sent=1, data_channel_messages_received=2)
    after = {key: value + 100 if type(value) is int else value for key, value in sample.items()}
    return dict(schema_version=1, run_nonce=NONCE, mode=mode, force_relay=mode == "relay", transport="webrtc-datachannel", provider_label="SCRIPTED PROVIDER", hub_returned=True,
                chat=dict(session_id="actual-session", response_id="actual-response", sse_response_id="actual-response", prompt_sha256=digest(prompt(NONCE, mode)),
                          assistant_sha256="e" * 64, completed=True, sse_event_count=3, text_delta_count=1,
                          request_started_at=time.time() - 5, response_completed_at=time.time() - 1), before_chat=sample, after_chat=after)


class AdapterTests(unittest.TestCase):
    def test_valid_private_runtime(self):
        public, private = configuration()
        inputs(public, private, NONCE)

    def test_reject_wrong_or_stale_runtime(self):
        public, private = configuration()
        for change in (dict(run_nonce="wrong"), dict(expires_at=0), dict(expires_at=time.time() + 7200)):
            with self.assertRaises(ContractError):
                inputs(public, dict(private, **change), NONCE)

    def test_broker_only_forward_and_pinned_host(self):
        public, private = configuration()
        for broker in ("http://remote.invalid:8877/", "http://localhost:9000/node/agent/", "https://localhost:8877/"):
            bad = copy.deepcopy(private)
            bad["direct"]["pairing_link"] = bad["direct"]["pairing_link"].replace("http%3A%2F%2Flocalhost%3A8877%2F", urlencode({"broker": broker})[7:])
            with self.assertRaises(ContractError):
                inputs(public, bad, NONCE)
        public["ssh"]["known_host"] = "different.invalid ssh-ed25519 AAAA"
        with self.assertRaises(ContractError):
            inputs(public, private, NONCE)

    def test_requires_self_hosted_relay_credentials(self):
        public, private = configuration()
        private["relay"]["ice_servers"][0].pop("credential")
        with self.assertRaises(ContractError):
            inputs(public, private, NONCE)

    def test_actual_correlation_without_provider_nonce_echo(self):
        public, _ = configuration()
        clean = evidence(observed(), public, NONCE, "direct")
        self.assertNotIn("response_nonce", clean)
        self.assertEqual(clean["remote_audit_status"], "pending-parent-audit")
        evidence(observed("relay"), public, NONCE, "relay")

    def test_counter_increases_not_aggregate_or_wrong_ice_proof(self):
        public, _ = configuration()
        for change in (dict(local_type="relay"), dict(data_channel_bytes_received=6), dict(selected_pair_id="other-pair")):
            raw = observed()
            raw["after_chat"].update(change)
            with self.assertRaises(ContractError):
                evidence(raw, public, NONCE, "direct")
        raw = observed("relay")
        raw["after_chat"]["local_type"] = "host"
        with self.assertRaises(ContractError):
            evidence(raw, public, NONCE, "relay")

    def test_native_selected_pair_details_are_preserved_not_synthesized(self):
        public, _ = configuration()
        raw = observed("relay")
        for name in ("before_chat", "after_chat"):
            raw[name].update(state="succeeded", nominated=True, local_relay_protocol="udp")
        clean = evidence(raw, public, NONCE, "relay")
        self.assertTrue(clean["after_chat"]["nominated"])
        self.assertEqual(clean["after_chat"]["local_relay_protocol"], "udp")
        self.assertNotIn("remote_relay_protocol", clean["after_chat"])
        for change in (dict(state="failed"), dict(nominated=False), dict(local_relay_protocol="private-address")):
            invalid = copy.deepcopy(raw)
            invalid["after_chat"].update(change)
            with self.assertRaises(ContractError):
                evidence(invalid, public, NONCE, "relay")

    def test_sse_must_match_specific_completed_response(self):
        public, _ = configuration()
        for change in (dict(completed=False), dict(sse_response_id="wrong"), dict(text_delta_count=0), dict(sse_event_count=1), dict(prompt_sha256="0" * 64)):
            raw = observed()
            raw["chat"].update(change)
            with self.assertRaises(ContractError):
                evidence(raw, public, NONCE, "direct")

    def test_secret_fields_are_not_copied_to_artifacts(self):
        public, _ = configuration()
        raw = observed()
        raw["sdp"] = "private-sdp"
        raw["chat"]["token"] = "private-token"
        raw["after_chat"]["address"] = "private-address"
        text = json.dumps(evidence(raw, public, NONCE, "direct"))
        for secret in ("private-sdp", "private-token", "private-address"):
            self.assertNotIn(secret, text)

    def test_failure_hierarchy_log_is_retained_with_runtime_secrets_redacted(self):
        capture = Capture.__new__(Capture)
        capture.sensitive = ["private-psk", "private-cap", "private-turn-credential"]
        raw = ("PEER_CAPTURE_MISSING_UI_HIERARCHY_BEGIN\nScrollView identifier: peer.approval\n"
               "private-psk private-cap private-turn-credential\nPEER_CAPTURE_MISSING_UI_HIERARCHY_END")
        clean = capture.redact(raw)
        self.assertIn("ScrollView identifier: peer.approval", clean)
        self.assertEqual(clean.count("[REDACTED]"), 3)
        for secret in capture.sensitive:
            self.assertNotIn(secret, clean)

    def test_failed_launch_diagnostics_are_bounded_and_redacted(self):
        from unittest.mock import patch
        import subprocess
        with tempfile.TemporaryDirectory() as temp:
            capture = Capture.__new__(Capture)
            capture.private = Path(temp) / "private"
            capture.artifacts = Path(temp) / "artifacts"
            capture.private.mkdir()
            capture.artifacts.mkdir()
            capture.sensitive = ["private-launch-capability"]
            def logs(args, **kwargs):
                self.assertEqual(kwargs["timeout"], 15)
                kwargs["stdout"].write(("old entry\n" * 300 + "SBRequestDenied private-launch-capability\n").encode())
                return subprocess.CompletedProcess(args, 0)
            with patch("capture.subprocess.run", side_effect=logs):
                capture.launch_diagnostics("direct", "test-simulator")
            result = (capture.artifacts / "direct-simulator-launch.log").read_text()
            self.assertIn("SBRequestDenied [REDACTED]", result)
            self.assertNotIn(capture.sensitive[0], result)
            self.assertLessEqual(len(result.splitlines()), 201)
            self.assertLess(len(result.encode()), 65600)

    def test_raw_xcresult_is_quarantined_if_secret_found(self):
        with tempfile.TemporaryDirectory() as temp:
            capture = Capture.__new__(Capture)
            capture.sensitive = ["private-cap"]
            source, target = Path(temp) / "raw", Path(temp) / "artifact"
            source.write_text("diagnostic private-cap")
            with self.assertRaises(ContractError):
                capture.safe_copy(source, target)
            self.assertFalse(target.exists())

    def test_unfinalized_video_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "placeholder.mp4"
            # Structural bytes for gate unit tests ONLY, never capture artifacts.
            def box(kind, body):
                return (len(body) + 8).to_bytes(4, "big") + kind + body
            path.write_bytes(box(b"ftyp", b"mp42") + box(b"mdat", b"x" * 4000))
            with self.assertRaises(ContractError):
                video(path)
            path.write_bytes(path.read_bytes() + box(b"moov", b""))
            video(path)


if __name__ == "__main__":
    unittest.main()
