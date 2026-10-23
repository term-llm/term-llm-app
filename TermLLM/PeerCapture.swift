import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - DEBUG simulator capture adapter (peer-ci-interface.md, final v1)
//
// Private runtime JSON arrives ONLY through the launch environment
// `TERMLLM_PEER_CAPTURE_JSON` (set by the UI test via launchEnvironment).
// It is never logged, rendered or written back.  The pairing link inside it
// is opened through the real OS URL handler (UIApplication.open), which then
// goes through the same visible approval as any other link.
//
// Evidence records what actually crossed the peer bridge: the real
// `POST …/v1/responses` exchange (session/response IDs from response
// headers, SHA-256 of the user prompt text actually sent, SHA-256 of the
// streamed assistant text, per-response SSE event/text-delta counts and
// timestamps) plus real libwebrtc selected-pair/DataChannel counters.  Raw
// prompts, assistant text, headers, SDP, addresses and credentials are never
// stored.  Nothing here synthesizes values when observation is missing; a
// missing field is simply absent and the CI validator fails.

struct PeerCaptureConfiguration: Sendable {
    static let environmentKey = "TERMLLM_PEER_CAPTURE_JSON"
    static let readyFileName = "peer-capture-ready.json"
    static let evidenceFileName = "peer-capture-evidence.json"

    let runNonce: String
    let mode: String           // "direct" | "relay"
    let forceRelay: Bool
    let iceServers: [PeerICEServer]
    /// Private.  Only ever handed to UIApplication.open.
    let pairingLink: URL

    var label: String { "SCRIPTED PROVIDER · REAL TRANSPORT · SIMULATOR INSTALL" }
    var relayLabel: String? { mode == "relay" ? "SELF-HOSTED TURN · NOT CLOUDFLARE" : nil }

    /// nil outside DEBUG simulator builds or without valid runtime JSON.
    static func fromEnvironment() -> PeerCaptureConfiguration? {
        #if DEBUG && targetEnvironment(simulator)
        guard let json = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        return parse(Data(json.utf8))
        #else
        return nil
        #endif
    }

    private struct Raw: Decodable {
        let schema_version: Int
        let run_nonce: String
        let mode: String
        let force_relay: Bool
        let ice_servers: [PeerICEServer]
        let pairing_link: String
    }

    /// Strict; failure returns nil without describing the (secret) input.
    static func parse(_ data: Data) -> PeerCaptureConfiguration? {
        guard data.count <= 64 * 1024, let raw = try? JSONDecoder().decode(Raw.self, from: data),
              raw.schema_version == 1,
              (16...80).contains(raw.run_nonce.utf8.count),
              raw.run_nonce.utf8.allSatisfy({ c in
                  (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
              }),
              raw.mode == "direct" || raw.mode == "relay",
              raw.force_relay == (raw.mode == "relay"),
              !raw.ice_servers.isEmpty,
              raw.ice_servers.allSatisfy({ !$0.urls.isEmpty }),
              (try? PeerPairingLink.parse(raw.pairing_link)) != nil,
              let link = URL(string: raw.pairing_link) else { return nil }
        return PeerCaptureConfiguration(runNonce: raw.run_nonce, mode: raw.mode, forceRelay: raw.force_relay,
                                        iceServers: raw.ice_servers, pairingLink: link)
    }
}

// MARK: - SSE evidence (bounded, hash-only)

/// Incremental parser for the term-llm Responses SSE stream
/// (`id: N\nevent: <type>\ndata: <json>\n\n`).  Keeps only counts, IDs and a
/// running SHA-256 of `response.output_text.delta` text.
struct PeerSSEEvidenceParser {
    static let maxPendingBytes = 512 * 1024

    private var pending = Data()
    private var assistantHash = SHA256()
    private(set) var eventCount = 0
    private(set) var textDeltaCount = 0
    private(set) var responseID: String?
    private(set) var completed = false
    private(set) var overflowed = false

    var assistantSHA256: String { Self.hex(assistantHash.finalize()) }

    mutating func feed(_ chunk: Data) {
        guard !overflowed else { return }
        // SSE allows CRLF/CR line endings; normalise to LF.
        pending.append(contentsOf: chunk.filter { $0 != 0x0D })
        let separator = Data([0x0A, 0x0A])
        while let range = pending.range(of: separator) {
            let event = pending[pending.startIndex..<range.lowerBound]
            handle(Data(event))
            pending.removeSubrange(pending.startIndex..<range.upperBound)
        }
        if pending.count > Self.maxPendingBytes {
            overflowed = true
            pending = Data()
        }
    }

    private mutating func handle(_ raw: Data) {
        var name: String?
        var dataLines: [Substring] = []
        let text = String(decoding: raw, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(":") { continue }  // comment / keep-alive
            if line.hasPrefix("event:") {
                name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                dataLines.append(value)
            }
        }
        guard !dataLines.isEmpty else { return }
        eventCount += 1
        let payload = dataLines.joined(separator: "\n")
        let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
        let type = name ?? (object?["type"] as? String) ?? ""
        let response = object?["response"] as? [String: Any]
        switch type {
        case "response.output_text.delta":
            textDeltaCount += 1
            if let delta = object?["delta"] as? String { assistantHash.update(data: Data(delta.utf8)) }
            if responseID == nil { responseID = object?["response_id"] as? String }
        case "response.created":
            if let id = response?["id"] as? String { responseID = id }
        case "response.completed":
            completed = true
            if let id = response?["id"] as? String { responseID = id }
        default:
            break
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Recorder + observing forwarder

final class PeerCaptureRecorder: @unchecked Sendable {
    static let maxExchanges = 16

    final class Exchange: @unchecked Sendable {
        fileprivate let lock = NSLock()
        let startedAt: Double
        let promptSHA256: String?
        fileprivate(set) var status: Int?
        fileprivate(set) var sessionID: String?
        fileprivate(set) var responseID: String?
        fileprivate var parser = PeerSSEEvidenceParser()
        fileprivate(set) var completedAt: Double?

        init(startedAt: Double, promptSHA256: String?) {
            self.startedAt = startedAt
            self.promptSHA256 = promptSHA256
        }

        fileprivate func observe(_ event: PeerBodyEvent) {
            lock.withLock {
                switch event {
                case .chunk(let data):
                    parser.feed(data)
                    if parser.completed, completedAt == nil { completedAt = Date().timeIntervalSince1970 }
                case .end, .failed:
                    break
                }
            }
        }

        /// Only real observed values; absent fields stay absent.
        func evidence() -> [String: Any] {
            lock.withLock {
                var out: [String: Any] = [
                    "request_started_at": startedAt,
                    "completed": parser.completed && completedAt != nil && !parser.overflowed,
                    "sse_event_count": parser.eventCount,
                    "text_delta_count": parser.textDeltaCount,
                ]
                if let promptSHA256 { out["prompt_sha256"] = promptSHA256 }
                if let sessionID { out["session_id"] = sessionID }
                if let responseID { out["response_id"] = responseID }
                if let id = parser.responseID { out["sse_response_id"] = id }
                if let completedAt {
                    out["response_completed_at"] = completedAt
                    out["assistant_sha256"] = parser.assistantSHA256
                }
                if let status { out["http_status"] = status }
                return out
            }
        }

        var isCompleted: Bool { lock.withLock { parser.completed } }
    }

    private let lock = NSLock()
    private var exchanges: [Exchange] = []

    func wrap(_ inner: PeerHTTPForwarding) -> PeerHTTPForwarding {
        PeerCaptureForwarder(inner: inner, recorder: self)
    }

    fileprivate func begin(promptSHA256: String?) -> Exchange {
        let exchange = Exchange(startedAt: Date().timeIntervalSince1970, promptSHA256: promptSHA256)
        lock.withLock {
            exchanges.append(exchange)
            if exchanges.count > Self.maxExchanges { exchanges.removeFirst() }
        }
        return exchange
    }

    /// Most recent completed response, else the most recent attempt.
    func latestExchange() -> Exchange? {
        lock.withLock { exchanges.last(where: { $0.isCompleted }) ?? exchanges.last }
    }

    var hasCompletedResponse: Bool { lock.withLock { exchanges.contains { $0.isCompleted } } }
}

final class PeerCaptureForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let inner: PeerHTTPForwarding
    private let recorder: PeerCaptureRecorder

    init(inner: PeerHTTPForwarding, recorder: PeerCaptureRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        guard Self.isCreateResponse(request) else { return try await inner.forward(request, headTimeout: headTimeout) }
        let exchange = recorder.begin(promptSHA256: Self.promptSHA256(request.body))
        let response = try await inner.forward(request, headTimeout: headTimeout)
        exchange.lock.withLock {
            exchange.status = response.status
            exchange.sessionID = response.header.first("X-Session-Id")
            exchange.responseID = response.header.first("X-Response-Id")
        }
        let body = response.body.observing { [exchange] event in exchange.observe(event) }
        return PeerHTTPResponse(status: response.status, header: response.header, body: body, cancel: response.cancel)
    }

    static func isCreateResponse(_ request: PeerHTTPRequest) -> Bool {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        return request.method == "POST" && path.hasSuffix("/v1/responses")
    }

    /// SHA-256 of the text of the last user input item actually sent
    /// (`content` string, or concatenated `text` of content parts).
    static func promptSHA256(_ body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let input = object["input"] as? [[String: Any]],
              let user = input.last(where: { ($0["role"] as? String) == "user" }) else { return nil }
        let text: String
        if let s = user["content"] as? String {
            text = s
        } else if let parts = user["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            guard !texts.isEmpty else { return nil }
            text = texts.joined()
        } else {
            return nil
        }
        return PeerSSEEvidenceParser.hex(SHA256.hash(data: Data(text.utf8)))
    }
}

// MARK: - Evidence files (app Documents only)

enum PeerCaptureEvidence {
    static func sample(_ s: PeerSessionStats) -> [String: Any] {
        var out: [String: Any] = [
            "bytes_sent": Int(clamping: s.bytesSent),
            "bytes_received": Int(clamping: s.bytesReceived),
            "data_channel_bytes_sent": Int(clamping: s.dataChannelBytesSent),
            "data_channel_bytes_received": Int(clamping: s.dataChannelBytesReceived),
            "data_channel_messages_sent": Int(clamping: s.dataChannelMessagesSent),
            "data_channel_messages_received": Int(clamping: s.dataChannelMessagesReceived),
        ]
        if let v = s.selectedPairID { out["selected_pair_id"] = v }
        if let v = s.localCandidateType { out["local_type"] = v }
        if let v = s.remoteCandidateType { out["remote_type"] = v }
        if let v = s.localProtocol { out["protocol"] = v }
        if let v = s.selectedPairState { out["state"] = v }
        if let v = s.selectedPairNominated { out["nominated"] = v }
        if let v = s.localRelayProtocol { out["local_relay_protocol"] = v }
        if let v = s.remoteRelayProtocol { out["remote_relay_protocol"] = v }
        return out
    }

    static func document(config: PeerCaptureConfiguration, chat: [String: Any]?,
                         before: PeerSessionStats?, after: PeerSessionStats?, hubReturned: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "schema_version": 1,
            "run_nonce": config.runNonce,
            "mode": config.mode,
            // Declared by the private capture runtime (debug provider), not
            // inferred by the app; the parent audits the remote node.
            "provider_label": "SCRIPTED PROVIDER",
            "transport": "webrtc-datachannel",
            "force_relay": config.forceRelay,
            "hub_returned": hubReturned,
        ]
        if let chat { out["chat"] = chat }
        if let before { out["before_chat"] = sample(before) }
        if let after { out["after_chat"] = sample(after) }
        return out
    }

    static func documentsURL(_ name: String) throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    static func write(_ object: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: try documentsURL(name), options: [.atomic])
    }

    static func writeReady(_ config: PeerCaptureConfiguration) throws {
        try write(["schema_version": 1, "run_nonce": config.runNonce, "mode": config.mode],
                  name: PeerCaptureConfiguration.readyFileName)
    }
}
