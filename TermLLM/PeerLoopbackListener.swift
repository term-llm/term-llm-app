#if canImport(Network)
import Foundation
import Network

/// Network.framework listener for the pair-only `http://localhost:<port>`
/// bridge.  Binds 127.0.0.1 on an ephemeral port and also occupies ::1 on the
/// SAME port: WebKit may resolve `localhost` to ::1 first, and an unrelated
/// ::1 listener on that port would otherwise receive the capability cookie.
/// If ::1 cannot be reserved (port taken) the attempt is discarded and a new
/// port tried; if the host has no IPv6 loopback at all, IPv4-only is used.
/// `acceptLocalOnly` plus an explicit remote-endpoint check reject anything
/// that is not loopback.
final class PeerNWLoopbackListener: PeerLoopbackListening, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.termllm.peer.loopback")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private let maxAttempts = 8

    init() {}

    func start(port preferredPort: UInt16?, onConnection: @escaping @Sendable (PeerByteStream) -> Void) async throws -> UInt16 {
        var lastError: Error = PeerWireError.channelClosed
        let attempts = preferredPort == nil ? maxAttempts : 4
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let requested = preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
            let v4 = try makeListener(host: .ipv4(.loopback), port: requested, onConnection: onConnection)
            let port: UInt16
            do {
                port = try await Self.ready(v4, queue: queue)
            } catch {
                v4.cancel()
                lastError = error
                if preferredPort != nil, attempt < attempts - 1 {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                continue
            }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { v4.cancel(); continue }
            do {
                let v6 = try makeListener(host: .ipv6(.loopback), port: nwPort, onConnection: onConnection)
                do {
                    _ = try await Self.ready(v6, queue: queue)
                    lock.withLock { listeners = [v4, v6] }
                    return port
                } catch let error as NWError {
                    v6.cancel()
                    if case .posix(let code) = error, code == .EADDRNOTAVAIL || code == .EAFNOSUPPORT {
                        // No IPv6 loopback: nothing can squat ::1 either.
                        lock.withLock { listeners = [v4] }
                        return port
                    }
                    v4.cancel()   // ::1:port held by someone else: pick another port
                    lastError = error
                } catch {
                    v6.cancel()
                    v4.cancel()
                    lastError = error
                }
            } catch {
                v4.cancel()
                lastError = error
            }
            if preferredPort != nil, attempt < attempts - 1 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw lastError
    }

    private func makeListener(host: NWEndpoint.Host, port: NWEndpoint.Port,
                              onConnection: @escaping @Sendable (PeerByteStream) -> Void) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            guard Self.isLoopback(connection.endpoint) else {
                connection.cancel()
                return
            }
            let stream = PeerNWByteStream(connection: connection)
            connection.start(queue: DispatchQueue(label: "com.termllm.peer.loopback.conn"))
            onConnection(stream)
        }
        return listener
    }

    private static func ready(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
                let once = PeerOnce()
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        if let port = listener?.port?.rawValue, port != 0 {
                            once.run { cont.resume(returning: port) }
                        }
                    case .failed(let error), .waiting(let error):
                        once.run { cont.resume(throwing: error) }
                    case .cancelled:
                        once.run { cont.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                if Task.isCancelled {
                    once.run { cont.resume(throwing: CancellationError()) }
                } else {
                    listener.start(queue: queue)
                }
            }
        }, onCancel: {
            listener.cancel()
        })
    }

    func stop() {
        let ls: [NWListener] = lock.withLock { let l = listeners; listeners = []; return l }
        ls.forEach { $0.cancel() }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback
        default: return false
        }
    }
}

final class PeerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first: Bool = lock.withLock { if done { return false }; done = true; return true }
        if first { body() }
    }
}

final class PeerNWByteStream: PeerByteStream, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) { self.connection = connection }

    func read(maxLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func close() { connection.cancel() }
}
#endif
