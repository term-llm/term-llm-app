import Foundation
import Network
import WebKit
import XCTest
@testable import TermLLM

final class RuntimeLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

final class DiagnosticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    init(_ value: UInt64 = 1_000_000_000) { self.value = value }
    func now() -> UInt64 { lock.withLock { value } }
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
    func advance(milliseconds: UInt64) { lock.withLock { value += milliseconds * 1_000_000 } }
}

final class PausingDiagnosticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseStart = DispatchSemaphore(value: 0)
    private var calls = 0
    private var startPaused = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func now() -> UInt64 {
        let waiters: [CheckedContinuation<Void, Never>]? = lock.withLock {
            calls += 1
            guard calls == 2 else { return nil } // recorder initialization is the first call
            startPaused = true
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        if let waiters {
            waiters.forEach { $0.resume() }
            releaseStart.wait()
        }
        return 1_000_000_000
    }

    func waitForStart() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if startPaused { return true }
                startWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func resumeStart() {
        let shouldSignal: Bool = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldSignal { releaseStart.signal() }
    }
}

final class DiagnosticTestCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LinkedDevicesDiagnosticRecord] = []
    var records: [LinkedDevicesDiagnosticRecord] { lock.withLock { stored } }
    func append(_ record: LinkedDevicesDiagnosticRecord) { lock.withLock { stored.append(record) } }
}

final class FailingEnrollmentListener: PeerLoopbackListening, @unchecked Sendable {
    func start(port: UInt16?, onConnection: @escaping @Sendable (PeerByteStream) -> Void) async throws -> UInt16 {
        throw NWError.posix(.EADDRINUSE)
    }
    func stop() {}
}

final class ReceivingLoopbackListener: PeerLoopbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private var handleConnection: (@Sendable (PeerByteStream) -> Void)?

    func start(port: UInt16?, onConnection: @escaping @Sendable (PeerByteStream) -> Void) async throws -> UInt16 {
        lock.withLock { handleConnection = onConnection }
        return port ?? 43_300
    }

    func receive(_ stream: PeerByteStream) { lock.withLock { handleConnection }?(stream) }
    func stop() { lock.withLock { handleConnection = nil } }
}

final class ControlledLoopbackListener: PeerLoopbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var starts = 0
    private(set) var stopped = false
    var started: Bool { lock.withLock { continuation != nil } }
    var startCount: Int { lock.withLock { starts } }

    func start(port: UInt16?, onConnection: @escaping @Sendable (PeerByteStream) -> Void) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                starts += 1
                self.continuation = continuation
            }
        }
    }

    func resume(port: UInt16) {
        let continuation = lock.withLock { let value = self.continuation; self.continuation = nil; return value }
        continuation?.resume(returning: port)
    }

    func stop() { lock.withLock { stopped = true } }
}

final class RuntimeTestChannel: PeerFrameChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var closeHandler: (() -> Void)?
    var isOpen: Bool { true }
    var bufferedAmount: UInt64 { 0 }
    func send(_ message: Data) -> Bool { true }
    func close() { lock.withLock { closeHandler }?() }
    func setHandlers(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void,
                     onBufferedAmountChange: @escaping () -> Void) {
        lock.withLock { closeHandler = onClose }
    }
}

final class BackpressuredRuntimeTestChannel: PeerFrameChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var closeHandler: (() -> Void)?
    private var sends = 0
    var isOpen: Bool { true }
    var bufferedAmount: UInt64 { PeerWireLimits.default.sendHighWaterBytes + 1 }
    var sendCount: Int { lock.withLock { sends } }
    func send(_ message: Data) -> Bool { lock.withLock { sends += 1 }; return true }
    func close() { lock.withLock { closeHandler }?() }
    func setHandlers(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void,
                     onBufferedAmountChange: @escaping () -> Void) {
        lock.withLock { closeHandler = onClose }
    }
}

final class ControlledRuntimeTestChannel: PeerFrameChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var messages: [Data] = []
    private var sentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var messageHandler: ((Data) -> Void)?
    private var closeHandler: (() -> Void)?

    var isOpen: Bool { lock.withLock { open } }
    var bufferedAmount: UInt64 { 0 }
    var sentFrames: [PeerFrame] {
        lock.withLock { messages }.compactMap { try? PeerFrameCodec.decode($0) }
    }

    func send(_ message: Data) -> Bool {
        let outcome: (Bool, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard open else { return (false, []) }
            messages.append(message)
            let ready = sentWaiters.filter { $0.0 <= messages.count }.map { $0.1 }
            sentWaiters.removeAll { $0.0 <= messages.count }
            return (true, ready)
        }
        outcome.1.forEach { $0.resume() }
        return outcome.0
    }

    func waitForSentFrames(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if messages.count >= count { return true }
                sentWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func close() { remoteClose() }

    func setHandlers(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void,
                     onBufferedAmountChange: @escaping () -> Void) {
        lock.withLock {
            messageHandler = onMessage
            closeHandler = onClose
        }
    }

    func deliver(_ frame: PeerFrame, limits: PeerWireLimits = .default) throws {
        let handler = lock.withLock { messageHandler }
        handler?(try PeerFrameCodec.encode(frame, limits: limits))
    }

    func remoteClose() {
        let handler: (() -> Void)? = lock.withLock {
            guard open else { return nil }
            open = false
            return closeHandler
        }
        handler?()
    }
}

final class FailingRuntimeTestConnector: LinkedDevicesSessionConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var attemptCount: Int { lock.withLock { attempts } }

    func reconnect(credential: LinkedDevicesCredential,
                   closed callback: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            attempts += 1
            let ready = waiters.filter { $0.0 <= attempts }.map { $0.1 }
            waiters.removeAll { $0.0 <= attempts }
            return ready
        }
        ready.forEach { $0.resume() }
        throw LinkedDevicesUnavailable(message: "controlled reconnect failure")
    }

    func waitForAttempts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if attempts >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

final class RuntimeTestConnector: LinkedDevicesSessionConnecting, @unchecked Sendable {
    let closed = RuntimeLockedFlag()
    func reconnect(credential: LinkedDevicesCredential,
                   closed callback: @escaping @Sendable () -> Void) async throws -> LinkedDevicesLiveConnection {
        let authorization = PeerAuthorizationState(PeerAuthorization(
            peerID: LinkedDevicesBase64URL.encode(credential.hostKey), sessionID: UUID().uuidString,
            expiresAt: .distantFuture, scopePrefix: credential.basePath ?? "/"))
        let multiplexer = PeerHTTPMultiplexer(channel: RuntimeTestChannel())
        let closedFlag = closed
        return LinkedDevicesLiveConnection(forwarder: multiplexer, authorization: authorization,
                                           stats: { PeerSessionStats() }, close: {
            closedFlag.set(); multiplexer.close(); authorization.revoke(); callback()
        })
    }
}

final class DelayedLinkedDevicesForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PeerHTTPResponse, Never>?
    private let status: Int
    init(status: Int = 200) { self.status = status }
    var started: Bool { lock.withLock { continuation != nil } }
    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }
    func finish() {
        let continuation = lock.withLock { let value = self.continuation; self.continuation = nil; return value }
        continuation?.resume(returning: PeerHTTPResponse(status: status, header: PeerHeader(),
                                                         body: .fixed([Data("ok".utf8)]), cancel: {}))
    }
}

final class ConcurrentDelayedLinkedDevicesForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<PeerHTTPResponse, Never>] = []
    private var requests: [PeerHTTPRequest] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var dispatchCount: Int { lock.withLock { requests.count } }
    var methods: [String] { lock.withLock { requests.map(\.method) } }

    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        await withCheckedContinuation { continuation in
            let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
                requests.append(request)
                continuations.append(continuation)
                let ready = waiters.filter { $0.0 <= requests.count }.map { $0.1 }
                waiters.removeAll { $0.0 <= requests.count }
                return ready
            }
            ready.forEach { $0.resume() }
        }
    }

    func waitForDispatches(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if requests.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func finishAll(status: Int = 200, body: Data = Data("old".utf8)) {
        let pending = lock.withLock { let value = continuations; continuations.removeAll(); return value }
        for continuation in pending {
            continuation.resume(returning: PeerHTTPResponse(status: status, header: PeerHeader(),
                                                             body: .fixed([body]), cancel: {}))
        }
    }
}

final class ProductionStaleAuthorizationForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PeerHTTPResponse, Never>?
    var started: Bool { lock.withLock { continuation != nil } }

    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        if request.path.contains("/v1/sessions/status") {
            return await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }
        return PeerHTTPResponse(status: 500, header: PeerHeader(),
                                body: .fixed([Data("{}".utf8)]), cancel: {})
    }

    func finishUnauthorized() {
        let continuation = lock.withLock { let value = self.continuation; self.continuation = nil; return value }
        continuation?.resume(returning: PeerHTTPResponse(status: 401, header: PeerHeader(),
                                                         body: .fixed([Data("{\"message\":\"old\"}".utf8)]),
                                                         cancel: {}))
    }
}

final class MemoryPeerByteStream: PeerByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Data?]
    private(set) var closed = false
    private var output = Data()
    init(input: Data) { reads = [input, nil] }
    func read(maxLength: Int) async throws -> Data? {
        lock.withLock { reads.isEmpty ? nil : reads.removeFirst() }
    }
    func write(_ data: Data) async throws { lock.withLock { output.append(data) } }
    func close() { lock.withLock { closed = true } }
    var written: Data { lock.withLock { output } }
}

final class LinkedDevicesForwarder: PeerHTTPForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    let status: Int
    let chunks: [Data]
    let bodyError: Error?
    let contentType: String
    init(status: Int = 200, chunks: [Data] = [Data("{\"ok\":true}".utf8)],
         bodyError: Error? = nil, contentType: String = "application/json") {
        self.status = status
        self.chunks = chunks
        self.bodyError = bodyError
        self.contentType = contentType
    }
    var paths: [String] { lock.withLock { recordedPaths } }
    func forward(_ request: PeerHTTPRequest, headTimeout: TimeInterval?) async throws -> PeerHTTPResponse {
        lock.withLock { recordedPaths.append(request.path) }
        var header = PeerHeader()
        header.set("Content-Type", contentType)
        return PeerHTTPResponse(status: status, header: header,
                                body: .fixed(chunks, error: bodyError), cancel: {})
    }
}

enum RealLoopbackTestError: Error {
    case timedOut
    case unexpectedEOF
}

/// A synchronous storage read gate, deliberately outside any storage lock.
/// Never block MainActor on regression: record a bad read and let XCTest fail.
final class CredentialReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var paused = false
    private var reads = 0
    private var mainThreadReads = 0
    var readCount: Int { lock.withLock { reads } }
    var mainThreadReadCount: Int { lock.withLock { mainThreadReads } }
    func pause() { lock.withLock { paused = true } }
    func releaseOne() { semaphore.signal() }
    func resume() { lock.withLock { paused = false }; semaphore.signal() }
    func read() {
        let onMain = Thread.isMainThread
        let shouldWait = lock.withLock {
            reads += 1
            if onMain { mainThreadReads += 1 }
            return paused && !onMain
        }
        if shouldWait { semaphore.wait() }
    }
}
