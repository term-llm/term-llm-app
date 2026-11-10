import CryptoKit
import Network
import XCTest
@testable import TermLLM

final class LinkedDevicesProtocolTests: XCTestCase {
    private let hostSeed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let deviceSeed = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    private let hostKey = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"
    private let deviceKey = "Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc"
    private let invitationID = "oKGio6SlpqeoqaqrrK2urw"
    private let pairingSecret = "wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t8"
    private let deviceNonce = "4OHi4-Tl5ufo6err7O3u7_Dx8vP09fb3-Pn6-_z9_v8"

    private func data(_ value: String) throws -> Data {
        try XCTUnwrap(LinkedDevicesBase64URL.decode(value, maximumBytes: 1024))
    }

    private func fixture() throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "linked-devices-vectors-v2", withExtension: "json"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func fixtureString(_ key: String, in fixture: [String: Any]) throws -> String {
        try XCTUnwrap(fixture[key] as? String, key)
    }

    /// CryptoKit can produce a valid Ed25519 signature that is not byte-identical
    /// to core's frozen signer (observed in the actual simulator run). Both must
    /// authenticate the exact frozen transcript under the same public key.
    private func assertValidSignatures(generated: Data, frozen: String, transcript: Data, publicKey: Data,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        XCTAssertTrue(verifier.isValidSignature(generated, for: transcript),
                      "generated signature did not authenticate the frozen transcript", file: file, line: line)
        XCTAssertTrue(verifier.isValidSignature(try data(frozen), for: transcript),
                      "frozen core signature did not authenticate the frozen transcript", file: file, line: line)
    }

    private func link(expiry: Int64 = 2_000_000_000) throws -> LinkedDevicesPairingLink {
        try LinkedDevicesPairingLink.parse(
            "termllm://pair?v=2&b=https%3A%2F%2Fbroker.example&h=\(hostKey)&i=\(invitationID)&e=\(expiry)&n=desk" +
            "#s=\(pairingSecret)&c=aW52aXRhdGlvbi1jYXA")
    }

    func testFrozenPairingVectorMatchesCoreAndSignaturesVerify() throws {
        let credential = LinkedDevicesCredential(hostKey: try data(hostKey), deviceSeed: try data(deviceSeed))
        let attempt = try LinkedDevicesPairingAttempt(link: link(), credential: credential, deviceName: "phone",
                                                       now: Date(timeIntervalSince1970: 1_900_000_000),
                                                       nonce: try data(deviceNonce))
        XCTAssertEqual(LinkedDevicesBase64URL.encode(attempt.request.device_key.data), deviceKey)
        let transcript = LinkedDevicesTranscript.pairRequest(attempt.request, hostKey: try data(hostKey))
        XCTAssertEqual(LinkedDevicesBase64URL.encode(transcript),
                       "AAAAE3Rlcm0tbGxtL3BhaXJpbmcvdjIAAAAMcGFpci1yZXF1ZXN0AAAABmRldmljZQAAABCgoaKjpKWmp6ipqqusra6vAAAAIAOhB7_zzhC-HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4AAAAICmsuuFBvMrwsi4alNNNC8c2HlJtC_4SyJeUvJMilm3XAAAAIODh4uPk5ebn6Onq6-zt7u_w8fLz9PX29_j5-vv8_f7_AAAABXBob25l")
        XCTAssertEqual(LinkedDevicesBase64URL.encode(LinkedDevicesTranscript.macKey(try data(pairingSecret))),
                       "GNYGK6Gilj7Ywjzf9gteSebL72uRZV4HGr9W0OJftpE")
        XCTAssertEqual(LinkedDevicesBase64URL.encode(attempt.request.mac.data),
                       "redYqpOeAgSKJdImOylqSQLzu7zXxKxhYfWr3BVFEZM")
        try assertValidSignatures(generated: attempt.request.sig.data,
                                  frozen: "qCkEwwvTAO1wsZrc3q9F9B7AIArcovGXgE1msKa7r5QNTgjCEXCEzZHdBIwKwGF6h6R8hctXwx1Rxd20H5JxCg",
                                  transcript: transcript, publicKey: attempt.request.device_key.data)
        XCTAssertEqual(LinkedDevicesBase64URL.encode(attempt.requestHash),
                       "J7_QqLsW2vuSxBGIHCWR8lnuPDKfkveV5oKQuXQxOxA")
        XCTAssertEqual(attempt.sas, "505580")
    }

    func testFrozenPairAnswerVerifiesAndPersistsRevocationOnlyGrant() throws {
        let credential = LinkedDevicesCredential(hostKey: try data(hostKey), deviceSeed: try data(deviceSeed))
        let attempt = try LinkedDevicesPairingAttempt(link: link(), credential: credential, deviceName: "phone",
                                                       now: Date(timeIntervalSince1970: 1_900_000_000),
                                                       nonce: try data(deviceNonce))
        let answer = LinkedDevicesPairAnswer(
            v: 2, type: "pair_answer", invitation_id: LinkedDevicesB64(try data(invitationID)),
            host_key: LinkedDevicesB64(try data(hostKey)), device_key: LinkedDevicesB64(try data(deviceKey)),
            device_nonce: LinkedDevicesB64(try data(deviceNonce)),
            request_hash: LinkedDevicesB64(try data("J7_QqLsW2vuSxBGIHCWR8lnuPDKfkveV5oKQuXQxOxA")),
            device_id: LinkedDevicesB64(try data("kJGSk5SVlpeYmZqbnJ2enw")),
            reconnect_capability: LinkedDevicesB64(try data("QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8")),
            scope: "web-v1", base_path: "/chat", host_label: "desk",
            mac: LinkedDevicesB64(try data("oZGEvpqORlY11rnDP2XyelRtML0wvQ9YXKDVgbP3gWY")),
            sig: LinkedDevicesB64(try data("SKgP9y-GFIEuP8b0k-EfOSExTsyJQOquWKdPVR5f7rmddTJSTrTNvuG6tsZ856G0ybZMPDBCARbmrkmtyYEOAQ")))
        XCTAssertEqual(LinkedDevicesBase64URL.encode(LinkedDevicesTranscript.pairAnswer(answer)),
                       "AAAAE3Rlcm0tbGxtL3BhaXJpbmcvdjIAAAALcGFpci1hbnN3ZXIAAAAEaG9zdAAAABCgoaKjpKWmp6ipqqusra6vAAAAIAOhB7_zzhC-HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4AAAAICmsuuFBvMrwsi4alNNNC8c2HlJtC_4SyJeUvJMilm3XAAAAIODh4uPk5ebn6Onq6-zt7u_w8fLz9PX29_j5-vv8_f7_AAAAICe_0Ki7Ftr7ksQRiBwlkfJZ7jwyn5L3leaCkLl0MTsQAAAAEJCRkpOUlZaXmJmam5ydnp8AAAAgQEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8AAAAGd2ViLXYxAAAABS9jaGF0AAAABGRlc2s")
        let paired = try attempt.verify(answer)
        XCTAssertEqual(paired.deviceSeed, try data(deviceSeed))
        XCTAssertEqual(paired.deviceID, "kJGSk5SVlpeYmZqbnJ2enw")
        XCTAssertEqual(paired.reconnectCapability, try data("QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8"))
        XCTAssertNil(Mirror(reflecting: paired).children.first { $0.label?.contains("expir") == true })
    }

    func testFrozenTransportVectorsLoadCopiedCoreFixture() throws {
        let fixture = try fixture()
        var credential = LinkedDevicesCredential(hostKey: try data(try fixtureString("host_key", in: fixture)),
                                                  deviceSeed: try data(try fixtureString("device_seed", in: fixture)))
        credential.deviceID = try fixtureString("device_id", in: fixture)
        credential.reconnectCapability = try data(try fixtureString("reconnect_capability", in: fixture))
        credential.basePath = "/chat"

        let hello = try LinkedDevicesTransportAttempt.hello(
            credential: credential, nonce: try data(try fixtureString("transport_hello_nonce", in: fixture)))
        let helloTranscript = LinkedDevicesTranscript.transportHello(hello, hostKey: credential.hostKey)
        XCTAssertEqual(LinkedDevicesBase64URL.encode(helloTranscript),
                       try fixtureString("transport_hello_transcript", in: fixture))
        try assertValidSignatures(generated: hello.sig.data,
                                  frozen: try fixtureString("transport_hello_signature", in: fixture),
                                  transcript: helloTranscript, publicKey: hello.device_key.data)

        let challengeData = Data(try fixtureString("transport_challenge_json", in: fixture).utf8)
        let challenge = try LinkedDevicesMessageCodec.decode(
            LinkedDevicesTransportChallenge.self, data: challengeData, expectedType: "transport_challenge",
            fields: ["v", "type", "challenge_id", "host_key", "host_nonce", "device_key", "device_id", "expires_at", "sig"])
        let request = try LinkedDevicesTransportAttempt(
            challenge: challenge, credential: credential,
            offerSDP: try fixtureString("transport_offer_sdp", in: fixture),
            now: Date(timeIntervalSince1970: 1_800_000_000),
            nonce: try data(try fixtureString("transport_device_nonce", in: fixture)))
        let requestTranscript = LinkedDevicesTranscript.transportRequest(request.request,
                                                                          hostKey: credential.hostKey)
        XCTAssertEqual(LinkedDevicesBase64URL.encode(requestTranscript),
                       try fixtureString("transport_request_transcript", in: fixture))
        XCTAssertEqual(LinkedDevicesBase64URL.encode(request.requestHash),
                       try fixtureString("transport_request_hash", in: fixture))
        try assertValidSignatures(generated: request.request.sig.data,
                                  frozen: try fixtureString("transport_request_signature", in: fixture),
                                  transcript: requestTranscript, publicKey: request.request.device_key.data)

        let answerData = Data(try fixtureString("transport_answer_json", in: fixture).utf8)
        let answer = try LinkedDevicesMessageCodec.decode(
            LinkedDevicesTransportAnswer.self, data: answerData, expectedType: "transport_answer",
            fields: ["v", "type", "challenge_id", "host_key", "host_nonce", "device_key", "device_nonce", "request_hash", "device_id", "answer_sdp", "sig"])
        XCTAssertEqual(try request.verify(answer), try fixtureString("transport_answer_sdp", in: fixture))
        var wrongHost = answer
        wrongHost.host_key = LinkedDevicesB64(Data(repeating: 0xFF, count: 32))
        XCTAssertThrowsError(try request.verify(wrongHost)) { error in
            XCTAssertEqual(error as? LinkedDevicesProtocolError, .hostIdentityChanged)
        }
    }

    func testLinkValidationIsBoundedStrictAndKeepsSecretsInFragment() throws {
        let parsed = try link()
        XCTAssertEqual(parsed.hostKey, try data(hostKey))
        XCTAssertEqual(parsed.invitationID, try data(invitationID))
        XCTAssertEqual(parsed.hostLabel, "desk")
        XCTAssertEqual(parsed.hostID.count, 43)
        let spaced = try LinkedDevicesPairingLink.parse(
            "termllm://pair?v=2&b=https%3A%2F%2Fbroker.example&h=\(hostKey)&i=\(invitationID)&e=2000000000&n=my+desk#s=\(pairingSecret)")
        XCTAssertEqual(spaced.hostLabel, "my desk")
        let literalPlus = try LinkedDevicesPairingLink.parse(
            "termllm://pair?v=2&b=https%3A%2F%2Fbroker.example&h=\(hostKey)&i=\(invitationID)&e=2000000000&n=C%2B%2B#s=\(pairingSecret)")
        XCTAssertEqual(literalPlus.hostLabel, "C++")

        let valid = "termllm://pair?v=2&b=https%3A%2F%2Fbroker.example&h=\(hostKey)&i=\(invitationID)&e=2000000000"
        for invalid in [
            valid.replacingOccurrences(of: "&b=", with: "&broker=") + "#s=\(pairingSecret)", // obsolete key is not compatible
            valid + "&s=\(pairingSecret)#s=\(pairingSecret)", // secret in query
            valid + "&h=\(hostKey)#s=\(pairingSecret)",       // duplicate
            valid + "&unknown=x#s=\(pairingSecret)",
            valid + "#s=\(pairingSecret)&s=\(pairingSecret)",
            valid.replacingOccurrences(of: "https%3A", with: "http%3A") + "#s=\(pairingSecret)",
            "termllm://pair/path?v=2#s=\(pairingSecret)",
            String(repeating: "x", count: 4097),
        ] {
            XCTAssertThrowsError(try LinkedDevicesPairingLink.parse(invalid), invalid)
        }
    }

    func testMessageCodecRejectsUnknownFieldsAndOversize() throws {
        let good = Data("{\"device_name\":\"phone\",\"device_key\":\"\(deviceKey)\",\"device_nonce\":\"\(deviceNonce)\",\"invitation_id\":\"\(invitationID)\",\"mac\":\"redYqpOeAgSKJdImOylqSQLzu7zXxKxhYfWr3BVFEZM\",\"sig\":\"qCkEwwvTAO1wsZrc3q9F9B7AIArcovGXgE1msKa7r5QNTgjCEXCEzZHdBIwKwGF6h6R8hctXwx1Rxd20H5JxCg\",\"type\":\"pair_request\",\"v\":2}".utf8)
        let fields: Set<String> = ["v", "type", "invitation_id", "device_key", "device_nonce", "device_name", "mac", "sig"]
        XCTAssertNoThrow(try LinkedDevicesMessageCodec.decode(LinkedDevicesPairRequest.self, data: good,
                                                               expectedType: "pair_request", fields: fields))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        object["offer_sdp"] = "forbidden during pairing"
        XCTAssertThrowsError(try LinkedDevicesMessageCodec.decode(LinkedDevicesPairRequest.self,
                                                                   data: JSONSerialization.data(withJSONObject: object),
                                                                   expectedType: "pair_request", fields: fields))
        XCTAssertEqual(LinkedDevicesWire.maxMessageBytes, 256 * 1024)
        XCTAssertEqual(LinkedDevicesWire.maxBrokerFrameBytes, 256 * 1024 + 512)
    }

    func testPairingFailuresIncludeStageAndSafeActionableDetails() {
        let storage = LinkedDevicesPairingFailure(stage: .savingIdentity,
            error: LinkedDevicesStorageError.unavailable(-25308)).localizedDescription
        XCTAssertTrue(storage.contains("approval was verified"))
        XCTAssertTrue(storage.contains("Keychain status -25308"))
        XCTAssertTrue(storage.contains("Unlock the iPhone"))
        XCTAssertTrue(storage.contains("Diagnostic stage: saving-identity"))

        let timeout = LinkedDevicesPairingFailure(stage: .waitingForApproval,
            error: LinkedDevicesBrokerError.peerOffline).localizedDescription
        XCTAssertTrue(timeout.contains("Timed out waiting"))
        XCTAssertFalse(timeout.contains("host is offline"))

        let invitation = LinkedDevicesPairingFailure(stage: .contactingBroker,
            error: LinkedDevicesBrokerError.unauthorized).localizedDescription
        XCTAssertTrue(invitation.contains("invitation"))
        XCTAssertFalse(invitation.contains("revoked"))

        let localPort = LinkedDevicesPairingFailure(stage: .savingConnection,
            error: NWError.posix(.EADDRINUSE)).localizedDescription
        XCTAssertTrue(localPort.contains("port is already in use"))
        XCTAssertTrue(localPort.contains("POSIX 48"))

        let enrollment = LinkedDevicesPairingFailure(stage: .savingConnection,
            error: NSError(domain: "test", code: 1)).localizedDescription
        XCTAssertTrue(enrollment.contains("credentials were saved"))
        XCTAssertTrue(enrollment.contains("check Connections"))
    }

    func testWiFiAwarePairingFailureHasSafeNetworkDiagnostic() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("Wi-Fi Aware errors require the newer Network framework")
        }
        let failure = LinkedDevicesPairingFailure(stage: .startingLocalBridge,
                                                  error: NWError.wifiAware(-42))
        XCTAssertEqual(failure.reason, "The network connection failed (Wi-Fi Aware -42).")
        XCTAssertTrue(failure.localizedDescription.contains("Diagnostic stage: starting-local-chat-bridge"))
    }

    func testPairingFailuresNeverExposeArbitraryErrorsOrServerReasons() {
        let secret = "PRIVATE-PAIRING-CAPABILITY"
        let errors: [Error] = [
            LinkedDevicesBrokerError.closed(1006, secret),
            LinkedDevicesBrokerError.http(500, secret),
            LinkedDevicesProtocolError.invalid(secret),
            LinkedDevicesProtocolError.rejected(secret),
            NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret]),
            URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://\(secret)"])
        ]
        for error in errors {
            let message = LinkedDevicesPairingFailure(stage: .waitingForApproval, error: error).localizedDescription
            XCTAssertFalse(message.contains(secret))
            XCTAssertTrue(message.contains("Diagnostic stage: waiting-for-approval"))
        }
        let closed = LinkedDevicesPairingFailure(stage: .waitingForApproval,
            error: LinkedDevicesBrokerError.closed(1006, secret)).localizedDescription
        XCTAssertTrue(closed.contains("code 1006"))
    }

    @MainActor
    func testInvalidPairingLinkShowsActionableFailure() {
        let model = LinkedDevicesPairingModel()
        XCTAssertTrue(model.handle(URL(string: "termllm://pair?v=1")!))
        guard case .failed(let message) = model.phase else {
            return XCTFail("Invalid pairing links must show a failure")
        }
        XCTAssertTrue(message.contains("Diagnostic stage: opening-invitation"))
        XCTAssertTrue(message.contains("new QR code"))
    }

    func testFrozenBrokerAdviceMappingDistinguishesRevocationFromOffline() {
        func payload(_ code: String) -> Data { Data("{\"error\":\"\(code)\"}".utf8) }
        XCTAssertEqual(LinkedDevicesBrokerClient.apiError(status: 401, data: payload("unauthorized")), .unauthorized)
        XCTAssertEqual(LinkedDevicesBrokerClient.apiError(status: 404, data: payload("not_found")), .notFound)
        XCTAssertEqual(LinkedDevicesBrokerClient.apiError(status: 409, data: payload("peer_offline")), .peerOffline)
        XCTAssertEqual(LinkedDevicesBrokerClient.apiError(status: 429, data: payload("quota_exceeded")), .quotaExceeded)
    }

    func testWireMessagesKeepEveryKey() throws {
        try assertWireKeysRoundTrip(LinkedDevicesPairRequest.self, """
        {"v":2,"type":"pair_request","invitation_id":"AAEC","device_key":"AwQF","device_nonce":"BgcI",
         "device_name":"phone","mac":"CQoL","sig":"DA0O"}
        """)
        try assertWireKeysRoundTrip(LinkedDevicesPairAnswer.self, """
        {"v":2,"type":"pair_answer","invitation_id":"AAEC","host_key":"AwQF","device_key":"BgcI",
         "device_nonce":"CQoL","request_hash":"DA0O","device_id":"DxAR","reconnect_capability":"EhMU",
         "scope":"web-v1","base_path":"/chat","host_label":"desk","mac":"FRYX","sig":"GBka"}
        """)
        try assertWireKeysRoundTrip(LinkedDevicesPairReject.self,
                                    #"{"v":2,"type":"pair_reject","invitation_id":"AAEC","reason":"declined"}"#)
        try assertWireKeysRoundTrip(LinkedDevicesTransportHello.self, """
        {"v":2,"type":"transport_hello","device_key":"AAEC","device_id":"AwQF","reconnect_capability":"BgcI",
         "device_nonce":"CQoL","sig":"DA0O"}
        """)
        try assertWireKeysRoundTrip(LinkedDevicesTransportChallenge.self, """
        {"v":2,"type":"transport_challenge","challenge_id":"AAEC","host_key":"AwQF","host_nonce":"BgcI",
         "device_key":"CQoL","device_id":"DA0O","expires_at":1800000000,"sig":"DxAR"}
        """)
        try assertWireKeysRoundTrip(LinkedDevicesTransportRequest.self, """
        {"v":2,"type":"transport_request","challenge_id":"AAEC","host_nonce":"AwQF","device_key":"BgcI",
         "device_nonce":"CQoL","device_id":"DA0O","offer_sdp":"v=0","sig":"DxAR"}
        """)
        try assertWireKeysRoundTrip(LinkedDevicesTransportAnswer.self, """
        {"v":2,"type":"transport_answer","challenge_id":"AAEC","host_key":"AwQF","host_nonce":"BgcI",
         "device_key":"CQoL","device_nonce":"DA0O","request_hash":"DxAR","device_id":"EhMU",
         "answer_sdp":"v=0","sig":"FRYX"}
        """)
    }

    func testBrokerMessagesKeepEveryKey() throws {
        try assertWireKeysRoundTrip(LinkedDevicesBrokerFrame.self, """
        {"type":"ready","peer_id":"p1","peer_kind":"device","body":{"v":2},"role":"device",
         "peer_connected":true,"lease_expires_at":"2026-01-01T00:00:00Z","error":"none"}
        """)
        try assertWireKeysRoundTrip(LinkedDevicesICECredentials.self, """
        {"ice_servers":[{"urls":["turn:turn.example:3478"],"username":"user","credential":"secret"}],
         "expires_at":"2026-01-01T00:00:00Z"}
        """)
    }
}
