import CryptoKit
import XCTest
@testable import TermLLM

final class MobileSharingProtocolTests: XCTestCase {
    private let hostSeed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let deviceSeed = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    private let hostKey = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"
    private let deviceKey = "Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc"
    private let invitationID = "oKGio6SlpqeoqaqrrK2urw"
    private let pairingSecret = "wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t8"
    private let deviceNonce = "4OHi4-Tl5ufo6err7O3u7_Dx8vP09fb3-Pn6-_z9_v8"

    private func data(_ value: String) throws -> Data {
        try XCTUnwrap(MobileSharingBase64URL.decode(value, maximumBytes: 1024))
    }

    private func link(expiry: Int64 = 2_000_000_000) throws -> MobileSharingPairingLink {
        try MobileSharingPairingLink.parse(
            "termllm://pair?v=2&b=https%3A%2F%2Fbroker.example&h=\(hostKey)&i=\(invitationID)&e=\(expiry)&n=desk" +
            "#s=\(pairingSecret)&c=aW52aXRhdGlvbi1jYXA")
    }

    func testFrozenPairingVectorsMatchCoreByteForByte() throws {
        let credential = MobileSharingCredential(hostKey: try data(hostKey), deviceSeed: try data(deviceSeed))
        let attempt = try MobileSharingPairingAttempt(link: link(), credential: credential, deviceName: "phone",
                                                       now: Date(timeIntervalSince1970: 1_900_000_000),
                                                       nonce: try data(deviceNonce))
        XCTAssertEqual(MobileSharingBase64URL.encode(attempt.request.device_key.data), deviceKey)
        XCTAssertEqual(MobileSharingBase64URL.encode(MobileSharingTranscript.pairRequest(attempt.request,
                                                                                          hostKey: try data(hostKey))),
                       "AAAAE3Rlcm0tbGxtL3BhaXJpbmcvdjIAAAAMcGFpci1yZXF1ZXN0AAAABmRldmljZQAAABCgoaKjpKWmp6ipqqusra6vAAAAIAOhB7_zzhC-HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4AAAAICmsuuFBvMrwsi4alNNNC8c2HlJtC_4SyJeUvJMilm3XAAAAIODh4uPk5ebn6Onq6-zt7u_w8fLz9PX29_j5-vv8_f7_AAAABXBob25l")
        XCTAssertEqual(MobileSharingBase64URL.encode(MobileSharingTranscript.macKey(try data(pairingSecret))),
                       "GNYGK6Gilj7Ywjzf9gteSebL72uRZV4HGr9W0OJftpE")
        XCTAssertEqual(MobileSharingBase64URL.encode(attempt.request.mac.data),
                       "redYqpOeAgSKJdImOylqSQLzu7zXxKxhYfWr3BVFEZM")
        XCTAssertEqual(MobileSharingBase64URL.encode(attempt.request.sig.data),
                       "qCkEwwvTAO1wsZrc3q9F9B7AIArcovGXgE1msKa7r5QNTgjCEXCEzZHdBIwKwGF6h6R8hctXwx1Rxd20H5JxCg")
        XCTAssertEqual(MobileSharingBase64URL.encode(attempt.requestHash),
                       "J7_QqLsW2vuSxBGIHCWR8lnuPDKfkveV5oKQuXQxOxA")
        XCTAssertEqual(attempt.sas, "505580")
    }

    func testFrozenPairAnswerVerifiesAndPersistsRevocationOnlyGrant() throws {
        let credential = MobileSharingCredential(hostKey: try data(hostKey), deviceSeed: try data(deviceSeed))
        let attempt = try MobileSharingPairingAttempt(link: link(), credential: credential, deviceName: "phone",
                                                       now: Date(timeIntervalSince1970: 1_900_000_000),
                                                       nonce: try data(deviceNonce))
        let answer = MobileSharingPairAnswer(
            v: 2, type: "pair_answer", invitation_id: MobileSharingB64(try data(invitationID)),
            host_key: MobileSharingB64(try data(hostKey)), device_key: MobileSharingB64(try data(deviceKey)),
            device_nonce: MobileSharingB64(try data(deviceNonce)),
            request_hash: MobileSharingB64(try data("J7_QqLsW2vuSxBGIHCWR8lnuPDKfkveV5oKQuXQxOxA")),
            device_id: MobileSharingB64(try data("kJGSk5SVlpeYmZqbnJ2enw")),
            reconnect_capability: MobileSharingB64(try data("QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8")),
            scope: "web-v1", base_path: "/chat", host_label: "desk",
            mac: MobileSharingB64(try data("oZGEvpqORlY11rnDP2XyelRtML0wvQ9YXKDVgbP3gWY")),
            sig: MobileSharingB64(try data("SKgP9y-GFIEuP8b0k-EfOSExTsyJQOquWKdPVR5f7rmddTJSTrTNvuG6tsZ856G0ybZMPDBCARbmrkmtyYEOAQ")))
        XCTAssertEqual(MobileSharingBase64URL.encode(MobileSharingTranscript.pairAnswer(answer)),
                       "AAAAE3Rlcm0tbGxtL3BhaXJpbmcvdjIAAAALcGFpci1hbnN3ZXIAAAAEaG9zdAAAABCgoaKjpKWmp6ipqqusra6vAAAAIAOhB7_zzhC-HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4AAAAICmsuuFBvMrwsi4alNNNC8c2HlJtC_4SyJeUvJMilm3XAAAAIODh4uPk5ebn6Onq6-zt7u_w8fLz9PX29_j5-vv8_f7_AAAAICe_0Ki7Ftr7ksQRiBwlkfJZ7jwyn5L3leaCkLl0MTsQAAAAEJCRkpOUlZaXmJmam5ydnp8AAAAgQEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8AAAAGd2ViLXYxAAAABS9jaGF0AAAABGRlc2s")
        let paired = try attempt.verify(answer)
        XCTAssertEqual(paired.deviceSeed, try data(deviceSeed))
        XCTAssertEqual(paired.deviceID, "kJGSk5SVlpeYmZqbnJ2enw")
        XCTAssertEqual(paired.reconnectCapability, try data("QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8"))
        XCTAssertNil(Mirror(reflecting: paired).children.first { $0.label?.contains("expir") == true })
    }

    func testFrozenTransportRequestVectorMatchesCore() throws {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data(deviceSeed))
        var request = MobileSharingTransportRequest(
            challenge_id: MobileSharingB64(try data("EBESExQVFhcYGRobHB0eHw")),
            host_nonce: MobileSharingB64(try data("YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8")),
            device_key: MobileSharingB64(try data(deviceKey)),
            device_nonce: MobileSharingB64(try data("cHFyc3R1dnd4eXp7fH1-f4CBgoOEhYaHiImKi4yNjo8")),
            device_id: MobileSharingB64(try data("kJGSk5SVlpeYmZqbnJ2enw")),
            offer_sdp: "v=0\r\na=fingerprint:sha-256 AA:BB\r\n", sig: MobileSharingB64(Data()))
        let transcript = MobileSharingTranscript.transportRequest(request, hostKey: try data(hostKey))
        request.sig = MobileSharingB64(try privateKey.signature(for: transcript))
        XCTAssertEqual(MobileSharingBase64URL.encode(transcript),
                       "AAAAE3Rlcm0tbGxtL3BhaXJpbmcvdjIAAAARdHJhbnNwb3J0LXJlcXVlc3QAAAAGZGV2aWNlAAAAEBAREhMUFRYXGBkaGxwdHh8AAAAgA6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbgAAAAgYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8AAAAgKay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdcAAAAgcHFyc3R1dnd4eXp7fH1-f4CBgoOEhYaHiImKi4yNjo8AAAAQkJGSk5SVlpeYmZqbnJ2enwAAACJ2PTANCmE9ZmluZ2VycHJpbnQ6c2hhLTI1NiBBQTpCQg0K")
        XCTAssertEqual(MobileSharingBase64URL.encode(MobileSharingTranscript.hash(transcript)),
                       "NNiiHkgLqm4wNnYno_5egHqlvaRGitTYiBMcI716T_I")
        XCTAssertEqual(MobileSharingBase64URL.encode(request.sig.data),
                       "o_D8IXFdtoUdI4lCIxMWbUjRLDlvl_vnMbyGOrrW1qJ0JG8ncaIRn-mQhJK6XVHu9d8Ifuv68hFFxyBAJyfZAw")
    }

    func testLinkValidationIsBoundedStrictAndKeepsSecretsInFragment() throws {
        let parsed = try link()
        XCTAssertEqual(parsed.hostKey, try data(hostKey))
        XCTAssertEqual(parsed.invitationID, try data(invitationID))
        XCTAssertEqual(parsed.hostLabel, "desk")
        XCTAssertEqual(parsed.hostID.count, 43)

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
            XCTAssertThrowsError(try MobileSharingPairingLink.parse(invalid), invalid)
        }
    }

    func testMessageCodecRejectsUnknownFieldsAndOversize() throws {
        let good = Data("{\"device_name\":\"phone\",\"device_key\":\"\(deviceKey)\",\"device_nonce\":\"\(deviceNonce)\",\"invitation_id\":\"\(invitationID)\",\"mac\":\"redYqpOeAgSKJdImOylqSQLzu7zXxKxhYfWr3BVFEZM\",\"sig\":\"qCkEwwvTAO1wsZrc3q9F9B7AIArcovGXgE1msKa7r5QNTgjCEXCEzZHdBIwKwGF6h6R8hctXwx1Rxd20H5JxCg\",\"type\":\"pair_request\",\"v\":2}".utf8)
        let fields: Set<String> = ["v", "type", "invitation_id", "device_key", "device_nonce", "device_name", "mac", "sig"]
        XCTAssertNoThrow(try MobileSharingMessageCodec.decode(MobileSharingPairRequest.self, data: good,
                                                               expectedType: "pair_request", fields: fields))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        object["offer_sdp"] = "forbidden during pairing"
        XCTAssertThrowsError(try MobileSharingMessageCodec.decode(MobileSharingPairRequest.self,
                                                                   data: JSONSerialization.data(withJSONObject: object),
                                                                   expectedType: "pair_request", fields: fields))
        XCTAssertEqual(MobileSharingWire.maxMessageBytes, 256 * 1024)
        XCTAssertEqual(MobileSharingWire.maxBrokerFrameBytes, 256 * 1024 + 512)
    }

    func testFrozenBrokerAdviceMappingDistinguishesRevocationFromOffline() {
        func payload(_ code: String) -> Data { Data("{\"error\":\"\(code)\"}".utf8) }
        XCTAssertEqual(MobileSharingBrokerClient.apiError(status: 401, data: payload("unauthorized")), .unauthorized)
        XCTAssertEqual(MobileSharingBrokerClient.apiError(status: 404, data: payload("not_found")), .notFound)
        XCTAssertEqual(MobileSharingBrokerClient.apiError(status: 409, data: payload("peer_offline")), .peerOffline)
        XCTAssertEqual(MobileSharingBrokerClient.apiError(status: 429, data: payload("quota_exceeded")), .quotaExceeded)
    }
}
