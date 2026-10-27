import Foundation
import os

/// Closed, redacted events for opt-in local Linked devices diagnostics.
/// No case can carry a URL, raw path, durable identifier, header, body, SDP, address, or error string.
enum LinkedDevicesDiagnosticEvent: Sendable, Equatable {
    enum Method: String, Sendable, Equatable {
        case get, head, post, put, patch, delete, options, other

        init(_ value: String) {
            switch value.uppercased() {
            case "GET": self = .get
            case "HEAD": self = .head
            case "POST": self = .post
            case "PUT": self = .put
            case "PATCH": self = .patch
            case "DELETE": self = .delete
            case "OPTIONS": self = .options
            default: self = .other
            }
        }
    }

    enum Route: String, Sendable, Equatable {
        case health
        case sessions
        case sessionsStatus = "sessions_status"
        case responses
        case responseEvents = "response_events"
        case responseCancel = "response_cancel"
        case other

        /// Classifies only fixed suffix shapes and never returns input text.
        static func classify(_ path: String) -> Route {
            let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.suffix(1).elementsEqual(["healthz"]) { return .health }
            if parts.suffix(3).elementsEqual(["v1", "sessions", "status"]) { return .sessionsStatus }
            if parts.suffix(2).elementsEqual(["v1", "sessions"]) { return .sessions }
            if parts.suffix(2).elementsEqual(["v1", "responses"]) { return .responses }
            if parts.count >= 4, parts[parts.count - 4] == "v1", parts[parts.count - 3] == "responses" {
                if parts.last == "events" { return .responseEvents }
                if parts.last == "cancel" { return .responseCancel }
            }
            return .other
        }
    }

    enum Reason: String, Sendable, Equatable {
        case completed
        case cancelled
        case timeout
        case channelClosed = "channel_closed"
        case protocolViolation = "protocol_violation"
        case unauthorized
        case revoked
        case identityChanged = "identity_changed"
        case networkUnavailable = "network_unavailable"
        case remoteFailure = "remote_failure"
        case bufferLimit = "buffer_limit"
        case other
    }

    enum CandidateType: String, Sendable, Equatable {
        case host, srflx, prflx, relay, unknown

        init(_ value: String?) {
            switch value?.lowercased() {
            case "host": self = .host
            case "srflx": self = .srflx
            case "prflx": self = .prflx
            case "relay": self = .relay
            default: self = .unknown
            }
        }
    }

    enum PeerPhase: String, Sendable, Equatable {
        case new, connecting, connected, disconnected, failed, closed

        init(_ phase: PeerConnectionPhase) {
            switch phase {
            case .new: self = .new
            case .connecting: self = .connecting
            case .connected: self = .connected
            case .disconnected: self = .disconnected
            case .failed: self = .failed
            case .closed: self = .closed
            }
        }
    }

    case recoveryAttempt
    case recoveryFailed(Reason)
    case brokerConnected
    case brokerDisconnected(Reason)
    case identityVerified
    case peerPhase(PeerPhase)
    case candidate(local: CandidateType, remote: CandidateType)
    case dataChannelOpen
    case retired
    case requestStarted(request: UInt64, method: Method, route: Route)
    case responseHeaders(request: UInt64, status: Int)
    case requestTerminal(request: UInt64, outcome: RequestOutcome, reason: Reason, bytes: Int)

    enum RequestOutcome: String, Sendable, Equatable {
        case finished, cancelled, failed, truncated
    }
}

struct LinkedDevicesDiagnosticRecord: Sendable, Equatable {
    enum Stage: String, Sendable, Equatable {
        case recoveryAttempt = "recovery_attempt"
        case recoveryFailed = "recovery_failed"
        case brokerConnected = "broker_connected"
        case brokerDisconnected = "broker_disconnected"
        case identityVerified = "identity_verified"
        case peerPhase = "peer_phase"
        case candidate
        case dataChannelOpen = "data_channel_open"
        case retired
        case requestStarted = "request_started"
        case responseHeaders = "response_headers"
        case requestTerminal = "request_terminal"
    }

    let elapsedMilliseconds: UInt64
    let durationMilliseconds: UInt64?
    let connection: UInt64
    let request: UInt64?
    let stage: Stage
    let method: LinkedDevicesDiagnosticEvent.Method?
    let route: LinkedDevicesDiagnosticEvent.Route?
    let peerPhase: LinkedDevicesDiagnosticEvent.PeerPhase?
    let outcome: LinkedDevicesDiagnosticEvent.RequestOutcome?
    let reason: LinkedDevicesDiagnosticEvent.Reason?
    let status: Int?
    let bytes: Int?
    let localCandidate: LinkedDevicesDiagnosticEvent.CandidateType?
    let remoteCandidate: LinkedDevicesDiagnosticEvent.CandidateType?
}

struct LinkedDevicesDiagnosticConnection: Sendable {
    let sequence: UInt64
    private let observe: @Sendable (LinkedDevicesDiagnosticEvent) -> Void

    init(sequence: UInt64, observe: @escaping @Sendable (LinkedDevicesDiagnosticEvent) -> Void) {
        self.sequence = sequence
        self.observe = observe
    }

    func emit(_ event: LinkedDevicesDiagnosticEvent) { observe(event) }
}

/// Process-local recorder. It retains only start times for currently active requests.
final class LinkedDevicesDiagnostics: @unchecked Sendable {
    static let defaultsKey = "linkedDevicesDiagnostics"
    private static let maximumMilliseconds: UInt64 = 24 * 60 * 60 * 1_000
    private static let maximumBytes = 1_073_741_824
    private static let maximumActiveRequests = 1_024

    private struct RequestKey: Hashable { let connection: UInt64; let request: UInt64 }
    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let sink: @Sendable (LinkedDevicesDiagnosticRecord) -> Void
    private let startedAt: UInt64
    private var nextConnection: UInt64 = 1
    private var requestStarts: [RequestKey: UInt64] = [:]

    init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         sink: @escaping @Sendable (LinkedDevicesDiagnosticRecord) -> Void) {
        self.clock = clock
        self.sink = sink
        startedAt = clock()
    }

    /// UserDefaults also honors `-linkedDevicesDiagnostics YES` launch arguments.
    static func configured(defaults: UserDefaults = .standard) -> LinkedDevicesDiagnostics? {
        guard defaults.bool(forKey: defaultsKey) else { return nil }
        return LinkedDevicesDiagnostics { record in
            linkedDevicesLog.info("\(Self.format(record), privacy: .public)")
        }
    }

    func connection() -> LinkedDevicesDiagnosticConnection {
        let sequence: UInt64 = lock.withLock {
            let value = nextConnection
            nextConnection = nextConnection == UInt64.max ? 1 : nextConnection + 1
            return value
        }
        return LinkedDevicesDiagnosticConnection(sequence: sequence) { [weak self] event in
            self?.record(connection: sequence, event: event)
        }
    }

    private func record(connection: UInt64, event: LinkedDevicesDiagnosticEvent) {
        let now = clock()
        let result: LinkedDevicesDiagnosticRecord? = lock.withLock {
            let elapsed = Self.milliseconds(from: startedAt, to: now)
            var request: UInt64?
            var duration: UInt64?
            var stage: LinkedDevicesDiagnosticRecord.Stage
            var method: LinkedDevicesDiagnosticEvent.Method?
            var route: LinkedDevicesDiagnosticEvent.Route?
            var peerPhase: LinkedDevicesDiagnosticEvent.PeerPhase?
            var outcome: LinkedDevicesDiagnosticEvent.RequestOutcome?
            var reason: LinkedDevicesDiagnosticEvent.Reason?
            var status: Int?
            var bytes: Int?
            var localCandidate: LinkedDevicesDiagnosticEvent.CandidateType?
            var remoteCandidate: LinkedDevicesDiagnosticEvent.CandidateType?

            switch event {
            case .recoveryAttempt: stage = .recoveryAttempt
            case .recoveryFailed(let value): stage = .recoveryFailed; reason = value
            case .brokerConnected: stage = .brokerConnected
            case .brokerDisconnected(let value): stage = .brokerDisconnected; reason = value
            case .identityVerified: stage = .identityVerified
            case .peerPhase(let value): stage = .peerPhase; peerPhase = value
            case .candidate(let local, let remote):
                stage = .candidate; localCandidate = local; remoteCandidate = remote
            case .dataChannelOpen: stage = .dataChannelOpen
            case .retired: stage = .retired
            case .requestStarted(let value, let requestMethod, let requestRoute):
                let key = RequestKey(connection: connection, request: value)
                guard requestStarts[key] == nil,
                      requestStarts.count < Self.maximumActiveRequests else { return nil }
                request = value; stage = .requestStarted; method = requestMethod; route = requestRoute
                requestStarts[key] = now
            case .responseHeaders(let value, let responseStatus):
                let key = RequestKey(connection: connection, request: value)
                guard requestStarts[key] != nil else { return nil }
                request = value; stage = .responseHeaders
                status = (100...999).contains(responseStatus) ? responseStatus : nil
            case .requestTerminal(let value, let requestOutcome, let requestReason, let byteCount):
                let key = RequestKey(connection: connection, request: value)
                guard let began = requestStarts.removeValue(forKey: key) else { return nil }
                request = value; stage = .requestTerminal; outcome = requestOutcome; reason = requestReason
                duration = Self.milliseconds(from: began, to: now)
                bytes = min(max(0, byteCount), Self.maximumBytes)
            }
            return LinkedDevicesDiagnosticRecord(
                elapsedMilliseconds: elapsed, durationMilliseconds: duration,
                connection: connection, request: request, stage: stage, method: method, route: route,
                peerPhase: peerPhase, outcome: outcome, reason: reason, status: status, bytes: bytes,
                localCandidate: localCandidate, remoteCandidate: remoteCandidate)
        }
        if let result { sink(result) }
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        min(end >= start ? (end - start) / 1_000_000 : 0, maximumMilliseconds)
    }

    static func format(_ record: LinkedDevicesDiagnosticRecord) -> String {
        var fields = ["[linked-devices]", "+\(record.elapsedMilliseconds)ms", "stage=\(record.stage.rawValue)",
                      "connection=\(record.connection)"]
        if let request = record.request { fields.append("request=\(request)") }
        if let duration = record.durationMilliseconds { fields.append("duration_ms=\(duration)") }
        if let method = record.method { fields.append("method=\(method.rawValue)") }
        if let route = record.route { fields.append("route=\(route.rawValue)") }
        if let phase = record.peerPhase { fields.append("phase=\(phase.rawValue)") }
        if let outcome = record.outcome { fields.append("outcome=\(outcome.rawValue)") }
        if let reason = record.reason { fields.append("reason=\(reason.rawValue)") }
        if let status = record.status { fields.append("status=\(status)") }
        if let bytes = record.bytes { fields.append("bytes=\(bytes)") }
        if let candidate = record.localCandidate { fields.append("local_candidate=\(candidate.rawValue)") }
        if let candidate = record.remoteCandidate { fields.append("remote_candidate=\(candidate.rawValue)") }
        return fields.joined(separator: " ")
    }
}

private let linkedDevicesLog = Logger(subsystem: "com.termllm.app", category: "linked-devices")
