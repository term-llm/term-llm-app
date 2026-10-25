"""Portable protocol-v2 and Xcode membership checks; no Apple SDK required."""
import base64
import hashlib
import hmac
import json
import struct
import unittest
from pathlib import Path

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except ImportError:  # The repository's self-hosted check installs no Python packages.
    Ed25519PrivateKey = None

ROOT = Path(__file__).resolve().parents[2]
V = json.loads((Path(__file__).parent / "fixtures/vectors_v2.json").read_text())


def b64(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def enc(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def transcript(label, *fields):
    values = [b"term-llm/pairing/v2", label.encode(), *fields]
    return b"".join(struct.pack(">I", len(value)) + value for value in values)


class MobileSharingContractTests(unittest.TestCase):
    def test_pair_request_vector(self):
        value = transcript(
            "pair-request", b"device", b64(V["invitation_id"]), b64(V["host_key"]),
            b64(V["device_key"]), b64(V["device_nonce"]), b"phone")
        self.assertEqual(enc(value), V["pair_request_transcript"])
        key = hmac.digest(b64(V["pairing_secret"]), b"term-llm/pairing/v2/mac-key", "sha256")
        self.assertEqual(enc(key), V["mac_key"])
        self.assertEqual(enc(hmac.digest(key, value, "sha256")), V["pair_request_mac"])
        self.assertEqual(enc(hashlib.sha256(value).digest()), V["pair_request_hash"])
        if Ed25519PrivateKey is not None:
            private = Ed25519PrivateKey.from_private_bytes(b64(V["device_seed"]))
            self.assertEqual(enc(private.sign(value)), V["pair_request_signature"])
        sas_t = transcript("pair-sas", b64(V["invitation_id"]), b64(V["host_key"]), b64(V["device_key"]))
        sas = struct.unpack(">I", hmac.digest(key, sas_t, "sha256")[:4])[0] % 1_000_000
        self.assertEqual(f"{sas:06d}", V["sas"])

    def test_pair_answer_vector(self):
        value = transcript(
            "pair-answer", b"host", b64(V["invitation_id"]), b64(V["host_key"]), b64(V["device_key"]),
            b64(V["device_nonce"]), b64(V["pair_request_hash"]), b64(V["device_id"]),
            b64(V["reconnect_capability"]), b"web-v1", b"/chat", b"desk")
        self.assertEqual(enc(value), V["pair_answer_transcript"])
        key = b64(V["mac_key"])
        self.assertEqual(enc(hmac.digest(key, value, "sha256")), V["pair_answer_mac"])
        if Ed25519PrivateKey is not None:
            host = Ed25519PrivateKey.from_private_bytes(b64(V["host_seed"]))
            self.assertEqual(enc(host.sign(value)), V["pair_answer_signature"])

    def test_transport_request_vector(self):
        value = transcript(
            "transport-request", b"device", b64(V["transport_challenge_id"]), b64(V["host_key"]),
            b64(V["transport_host_nonce"]), b64(V["device_key"]), b64(V["transport_device_nonce"]),
            b64(V["device_id"]), V["transport_offer_sdp"].encode())
        self.assertEqual(enc(value), V["transport_request_transcript"])
        self.assertEqual(enc(hashlib.sha256(value).digest()), V["transport_request_hash"])
        if Ed25519PrivateKey is not None:
            private = Ed25519PrivateKey.from_private_bytes(b64(V["device_seed"]))
            self.assertEqual(enc(private.sign(value)), V["transport_request_signature"])

    def test_copied_frozen_fixture_hash(self):
        fixture = (Path(__file__).parent / "fixtures/vectors_v2.json").read_bytes()
        self.assertEqual(hashlib.sha256(fixture).hexdigest(),
                         "1e68c2ebfa0b53073a9089b798990ad8defd49b088bd917ef29e695a341568de")
        self.assertEqual(len(b64(V["device_id"])), 16)
        self.assertEqual(len(b64(V["reconnect_capability"])), 32)
        self.assertEqual(json.loads(V["pair_answer_json"])["scope"], "web-v1")

    def test_xcode_membership_and_pinned_sdk(self):
        project = (ROOT / "TermLLM.xcodeproj/project.pbxproj").read_text()
        for path in sorted((ROOT / "TermLLM").glob("*Sharing*.swift")) + sorted((ROOT / "TermLLM").glob("Peer*.swift")) + [ROOT / "TermLLM/WebRTCHubTransport.swift"]:
            self.assertIn(path.name, project, path.name)
        for path in sorted((ROOT / "TermLLMTests").glob("MobileSharing*.swift")):
            self.assertIn(path.name, project, path.name)
        self.assertIn("44f36788497f701bc8c0306de3a1c2511d56019d", project)
        resolved = (ROOT / "TermLLM.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text()
        self.assertIn("44f36788497f701bc8c0306de3a1c2511d56019d", resolved)

    def test_swift_declares_frozen_v2_names_and_no_pilot_pairing(self):
        source = (ROOT / "TermLLM/MobileSharingProtocol.swift").read_text()
        for token in ('static let version = 2', 'required: ["v", "b", "h", "i", "e"]',
                      'query["b"]', 'invitation_id:', 'reconnect_capability:',
                      'static let maxBrokerFrameBytes = maxMessageBytes + 512',
                      '"transport_hello"', '"transport_challenge"', '"transport_request"',
                      '"transport_answer"', '"web-v1"', 'term-llm/pairing/v2'):
            self.assertIn(token, source)
        self.assertNotIn('query["broker"]', source)
        self.assertNotIn('required: ["v", "broker"', source)
        broker = (ROOT / "TermLLM/MobileSharingBroker.swift").read_text()
        for token in ('case "not_found": return .notFound',
                      'case "unauthorized": return .unauthorized',
                      'MobileSharingWire.maxBrokerFrameBytes'):
            self.assertIn(token, broker)
        connector = (ROOT / "TermLLM/MobileSharingConnector.swift").read_text()
        self.assertIn('catch MobileSharingBrokerError.unauthorized', connector)
        self.assertIn('throw MobileSharingProtocolError.revoked', connector)
        peer = (ROOT / "TermLLM/PeerWireProtocol.swift").read_text()
        self.assertIn("var maxRequestBodyBytes = 48_384", peer)
        self.assertIn('static let channelLabel = "term-llm-http-v1"', peer)
        self.assertNotIn('term-llm/pairing/v1', source)
        self.assertNotIn('offer_sdp: MobileSharingB64', source)


if __name__ == "__main__":
    unittest.main()
