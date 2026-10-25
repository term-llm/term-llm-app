import Foundation

// MARK: - Byte stream abstraction
//
// The NWConnection adapter (PeerLoopbackListener.swift) and in-memory test
// streams implement this.  All HTTP/1.1 parsing, authorization and streaming
// logic below is transport-agnostic so it is unit-testable everywhere.

protocol PeerByteStream: AnyObject, Sendable {
    /// Returns nil at EOF.
    func read(maxLength: Int) async throws -> Data?
    func write(_ data: Data) async throws
    func close()
}

// MARK: - Parsed request

struct PeerLoopbackRequest: Equatable, Sendable {
    var method: String
    var target: String
    var version: String
    var header: PeerHeader
    var body: Data

    var keepAlive: Bool {
        let tokens = header.values("Connection").flatMap { $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if version == "HTTP/1.0" { return tokens.contains("keep-alive") }
        return !tokens.contains("close")
    }
}

enum PeerLoopbackParseError: Error, Equatable {
    case headTooLarge
    case bodyTooLarge
    case malformed(String)
    case unsupportedTransferEncoding
}

/// Incremental HTTP/1.1 request parser (origin-form, Content-Length bodies).
struct PeerLoopbackRequestParser {
    var maxHeadBytes = 32 * 1024
    var maxBodyBytes = PeerWireLimits.default.maxRequestBodyBytes
    private(set) var buffer = Data()

    init(maxHeadBytes: Int = 32 * 1024, maxBodyBytes: Int = PeerWireLimits.default.maxRequestBodyBytes) {
        self.maxHeadBytes = maxHeadBytes
        self.maxBodyBytes = maxBodyBytes
    }

    mutating func append(_ data: Data) { buffer.append(data) }

    var bufferedBytes: Int { buffer.count }

    /// Returns a complete request and consumes it, or nil if more bytes are
    /// needed.  Throws on malformed/oversized input (connection must close).
    mutating func next() throws -> PeerLoopbackRequest? {
        // Tolerate leading CRLFs between requests (RFC 9112 §2.2).
        while buffer.starts(with: [0x0D, 0x0A]) { buffer.removeFirst(2) }
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headEnd = buffer.range(of: terminator) else {
            if buffer.count > maxHeadBytes { throw PeerLoopbackParseError.headTooLarge }
            return nil
        }
        let headLength = headEnd.lowerBound - buffer.startIndex
        guard headLength <= maxHeadBytes else { throw PeerLoopbackParseError.headTooLarge }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8),
              head.utf8.allSatisfy({ $0 < 0x80 }) else {
            throw PeerLoopbackParseError.malformed("non-ASCII head")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else { throw PeerLoopbackParseError.malformed("request line") }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let version = String(requestLine[2])
        guard PeerHeader.isValidName(method), method == method.uppercased() else {
            throw PeerLoopbackParseError.malformed("method")
        }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw PeerLoopbackParseError.malformed("version") }
        guard target.hasPrefix("/") || target == "*" else { throw PeerLoopbackParseError.malformed("target form") }

        var header = PeerHeader()
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let first = line.first, first != " ", first != "\t" else {
                throw PeerLoopbackParseError.malformed("obsolete line folding")
            }
            guard let colon = line.firstIndex(of: ":") else { throw PeerLoopbackParseError.malformed("header line") }
            let name = String(line[line.startIndex..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard PeerHeader.isValidName(name), PeerHeader.isValidValue(value) else {
                throw PeerLoopbackParseError.malformed("header token")
            }
            header.add(name, value)
        }
        guard header.values("Host").count == 1 else { throw PeerLoopbackParseError.malformed("host") }
        if !header.values("Transfer-Encoding").isEmpty { throw PeerLoopbackParseError.unsupportedTransferEncoding }
        let lengths = Set(header.values("Content-Length").flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
        guard lengths.count <= 1 else { throw PeerLoopbackParseError.malformed("content-length") }
        var length = 0
        if let raw = lengths.first {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), raw.count <= 12, let n = Int(raw) else {
                throw PeerLoopbackParseError.malformed("content-length")
            }
            length = n
        }
        guard length <= maxBodyBytes else { throw PeerLoopbackParseError.bodyTooLarge }
        let bodyStart = headEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])
        return PeerLoopbackRequest(method: method, target: target, version: version, header: header, body: body)
    }
}

// MARK: - Gate (authorization)

/// How cookies cross the bridge.  `.isolate` (default) strips every browser
/// cookie toward the node and every Set-Cookie toward WebKit, so loopback
/// sessions on different ports (cookies are not port-scoped) cannot observe
/// one another's remote cookies.  The node authenticates the peer channel,
/// not browser cookies.
enum PeerCookiePolicy: Sendable, Equatable {
    case isolate
    case passThrough
}

struct PeerLoopbackGate: Sendable {
    static let cookiePrefix = "termllm_peer_"
    static let scopeDeniedReason = "scope_denied"

    let port: UInt16
    let capability: String
    /// Only targets under this path prefix are forwarded (e.g. `/chat/`).
    let scopePrefix: String

    /// Pair-only loopback hostname.  `localhost` matches the app's existing
    /// ATS localhost exception; the listener itself binds loopback only
    /// (127.0.0.1, with ::1 on the same port reserved).  Host, Origin and the
    /// capability cookie are all exact `localhost:<port>`.
    static let hostname = "localhost"

    var cookieName: String { "\(Self.cookiePrefix)\(port)" }
    var origin: String { "http://\(Self.hostname):\(port)" }
    var host: String { "\(Self.hostname):\(port)" }

    enum Decision: Equatable {
        case allow
        case reject(status: Int, reason: String)
    }

    func evaluate(_ request: PeerLoopbackRequest) -> Decision {
        // DNS-rebinding defence: exact Host only.
        guard request.header.first("Host") == host else { return .reject(status: 421, reason: "host") }
        if let origin = request.header.first("Origin") {
            guard request.header.values("Origin").count == 1, origin == self.origin else {
                return .reject(status: 403, reason: "origin")
            }
        } else if !["GET", "HEAD"].contains(request.method) {
            return .reject(status: 403, reason: "origin required")
        }
        if let site = request.header.first("Sec-Fetch-Site")?.lowercased(), !["same-origin", "none"].contains(site) {
            // Other localhost ports are "same-site"; they are still foreign.
            return .reject(status: 403, reason: "fetch site")
        }
        guard let presented = Self.cookieValues(request.header, named: cookieName).first,
              Self.constantTimeEqual(presented, capability),
              Self.cookieValues(request.header, named: cookieName).count == 1 else {
            // Local capability failure is 403: it says nothing about the
            // remote grant, so it must not trigger identity purge.
            return .reject(status: 403, reason: "capability")
        }
        if request.method == "CONNECT" || request.target == "*" { return .reject(status: 405, reason: "method") }
        if !request.header.values("Upgrade").isEmpty {
            return .reject(status: 501, reason: "WebSocket/Upgrade is not supported by the peer bridge (term-llm-http-v1)")
        }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        // Out-of-scope route: 403 route error.  Never 401 — that would read as
        // identity loss and purge the paired owner.
        guard Self.isWithinScope(path, scopePrefix) else { return .reject(status: 403, reason: Self.scopeDeniedReason) }
        guard PeerHTTPRequest.isValidPath(request.target) else { return .reject(status: 400, reason: "target") }
        return .allow
    }

    static func isWithinScope(_ path: String, _ prefix: String) -> Bool {
        if prefix == "/" || prefix.isEmpty { return true }
        let bare = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        guard path == bare || path.hasPrefix(bare + "/") else { return false }
        // No dot segments that could escape the scope upstream.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.contains { $0 == ".." || $0 == "." || $0.lowercased().contains("%2e") || $0.lowercased().contains("%2f") }
    }

    static func cookiePairs(_ header: PeerHeader) -> [(String, String)] {
        header.values("Cookie").flatMap { line in
            line.split(separator: ";").compactMap { part -> (String, String)? in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let eq = trimmed.firstIndex(of: "=") else { return nil }
                return (String(trimmed[..<eq]), String(trimmed[trimmed.index(after: eq)...]))
            }
        }
    }

    static func cookieValues(_ header: PeerHeader, named name: String) -> [String] {
        cookiePairs(header).filter { $0.0 == name }.map { $0.1 }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}

// MARK: - Header rewriting

enum PeerHeaderFilter {
    static let hopByHop: Set<String> = [
        "Connection", "Keep-Alive", "Proxy-Connection", "Transfer-Encoding", "Te", "Trailer",
        "Upgrade", "Proxy-Authorization", "Proxy-Authenticate",
    ]

    static func connectionTokens(_ header: PeerHeader) -> Set<String> {
        Set(header.values("Connection").flatMap { $0.split(separator: ",") }.map {
            PeerHeader.canonical($0.trimmingCharacters(in: .whitespaces))
        })
    }

    /// Browser -> node.
    static func outbound(_ header: PeerHeader, policy: PeerCookiePolicy, upstreamOrigin: String?) -> PeerHeader {
        var out = PeerHeader()
        let drop = hopByHop.union(connectionTokens(header)).union([
            "Host", "Authorization", "Cookie", "Origin", "Referer", "Content-Length", "Forwarded", "Via",
        ])
        for name in header.names where !drop.contains(name) && !name.hasPrefix("X-Forwarded-")
            && !name.hasPrefix("Proxy-") && !name.hasPrefix("Sec-") {
            for value in header.values(name) { out.add(name, value) }
        }
        if policy == .passThrough {
            let kept = PeerLoopbackGate.cookiePairs(header)
                .filter { !$0.0.hasPrefix(PeerLoopbackGate.cookiePrefix) }
                .map { "\($0.0)=\($0.1)" }
            if !kept.isEmpty { out.set("Cookie", kept.joined(separator: "; ")) }
        }
        // The node sees its own origin (never the loopback one) when the
        // integration supplies it; otherwise Origin/Referer are withheld.
        if let upstreamOrigin {
            if header.first("Origin") != nil { out.set("Origin", upstreamOrigin) }
            if let referer = header.first("Referer"), let url = URL(string: referer), let path = url.path.isEmpty ? Optional("/") : Optional(url.path) {
                let query = url.query.map { "?\($0)" } ?? ""
                out.set("Referer", upstreamOrigin + path + query)
            }
        }
        return out
    }

    /// Node -> browser.
    static func inbound(_ header: PeerHeader, policy: PeerCookiePolicy) -> PeerHeader {
        var out = PeerHeader()
        let drop = hopByHop.union(connectionTokens(header)).union(["Content-Length", "Alt-Svc", "Strict-Transport-Security"])
        for name in header.names where !drop.contains(name) {
            if name == "Set-Cookie" {
                guard policy == .passThrough else { continue }
                for value in header.values(name) {
                    let cookieName = value.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if !cookieName.hasPrefix(PeerLoopbackGate.cookiePrefix) { out.add(name, value) }
                }
                continue
            }
            for value in header.values(name) { out.add(name, value) }
        }
        return out
    }
}

// MARK: - Connection input pump

/// Single reader per connection: buffers bytes for the parser and reports
/// EOF promptly (so an SSE stream is cancelled when WebKit disconnects).
final class PeerConnectionInput: @unchecked Sendable {
    private let stream: PeerByteStream
    private let lock = NSLock()
    private var pending = Data()
    private var eof = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private var eofHandlers: [() -> Void] = []
    private var pump: Task<Void, Never>?
    private let highWater: Int

    init(stream: PeerByteStream, highWater: Int) {
        self.stream = stream
        self.highWater = highWater
    }

    func start() {
        pump = Task { [weak self] in await self?.run() }
    }

    /// Stops reading and releases any `take()` waiter (treated as EOF).
    func stop() {
        pump?.cancel()
        finish(nil)
    }

    private func run() async {
        while !Task.isCancelled {
            // Stop reading while the parser has plenty unconsumed (bounded).
            while lock.withLock({ pending.count >= highWater }) && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            do {
                guard let chunk = try await stream.read(maxLength: 16 * 1024) else { finish(nil); return }
                lock.withLock { pending.append(chunk) }
                wake()
            } catch {
                finish(error)
                return
            }
        }
    }

    private func finish(_ error: Error?) {
        let handlers: [() -> Void] = lock.withLock {
            if eof { return [] }
            eof = true
            failure = error
            let h = eofHandlers
            eofHandlers.removeAll()
            return h
        }
        wake()
        handlers.forEach { $0() }
    }

    private func wake() {
        let w: CheckedContinuation<Void, Never>? = lock.withLock { let w = waiter; waiter = nil; return w }
        w?.resume()
    }

    /// Takes buffered bytes, waiting for more if none.  Returns nil at EOF.
    func take() async -> Data? {
        while true {
            let result: (Data?, Bool) = lock.withLock {
                if !pending.isEmpty { let d = pending; pending = Data(); return (d, true) }
                if eof { return (nil, true) }
                return (nil, false)
            }
            if result.1 { return result.0 }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready: Bool = lock.withLock {
                    if !pending.isEmpty || eof { return true }
                    waiter = c
                    return false
                }
                if ready { c.resume() }
            }
        }
    }

    /// Runs `handler` once on EOF (immediately if already at EOF).
    func onEOF(_ handler: @escaping () -> Void) {
        let fire: Bool = lock.withLock {
            if eof { return true }
            eofHandlers.append(handler)
            return false
        }
        if fire { handler() }
    }

    func clearEOFHandlers() { lock.withLock { eofHandlers.removeAll() } }
}

// MARK: - Connection handler

/// Serves one loopback HTTP/1.1 connection: parse -> gate -> forward over the
/// peer channel -> stream the response (chunked) back to WebKit.
final class PeerLoopbackConnection: @unchecked Sendable {
    struct Configuration: Sendable {
        var gate: PeerLoopbackGate
        var cookiePolicy: PeerCookiePolicy = .isolate
        var upstreamOrigin: String?
        var headTimeout: TimeInterval = 30
        var limits: PeerWireLimits = .default
    }

    private let stream: PeerByteStream
    private let forwarder: PeerHTTPForwarding
    private let configuration: Configuration
    private let isAuthorized: @Sendable () -> Bool
    private let input: PeerConnectionInput
    private let lock = NSLock()
    private var activeCancel: (@Sendable () -> Void)?
    private var closed = false

    init(stream: PeerByteStream, forwarder: PeerHTTPForwarding, configuration: Configuration,
         isAuthorized: @escaping @Sendable () -> Bool) {
        self.stream = stream
        self.forwarder = forwarder
        self.configuration = configuration
        self.isAuthorized = isAuthorized
        self.input = PeerConnectionInput(stream: stream, highWater: 32 * 1024 + configuration.limits.maxRequestBodyBytes)
    }

    /// Tear down immediately (revoke): cancels in-flight remote stream.
    func close() {
        let cancel: (@Sendable () -> Void)? = lock.withLock {
            if closed { return nil }
            closed = true
            let c = activeCancel
            activeCancel = nil
            return c
        }
        cancel?()
        input.stop()
        stream.close()
    }

    func serve() async {
        input.start()
        var parser = PeerLoopbackRequestParser(maxBodyBytes: configuration.limits.maxRequestBodyBytes)
        defer { close() }
        while !lock.withLock({ closed }) {
            let request: PeerLoopbackRequest
            do {
                if let r = try parser.next() {
                    request = r
                } else {
                    guard let more = await input.take() else { return }
                    parser.append(more)
                    continue
                }
            } catch let error as PeerLoopbackParseError {
                let status: Int
                switch error {
                case .headTooLarge: status = 431
                case .bodyTooLarge: status = 413
                case .unsupportedTransferEncoding: status = 501
                case .malformed: status = 400
                }
                try? await writeSimple(status: status, message: "Bad request", keepAlive: false, head: false)
                return
            } catch {
                return
            }
            let keepAlive = request.keepAlive
            let ok = await handle(request, keepAlive: keepAlive)
            if !ok || !keepAlive { return }
        }
    }

    /// Returns false when the connection must close.
    private func handle(_ request: PeerLoopbackRequest, keepAlive: Bool) async -> Bool {
        let isHead = request.method == "HEAD"
        guard isAuthorized() else {
            try? await writeSimple(status: 401, message: "Peer session revoked", keepAlive: false, head: isHead)
            return false
        }
        if case .reject(let status, let reason) = configuration.gate.evaluate(request) {
            // Capability/host/origin failures reveal nothing upstream.
            let message = status == 501 ? reason : "Forbidden"
            var extra = PeerHeader()
            if reason == PeerLoopbackGate.scopeDeniedReason {
                extra.set(PeerScopeDenied.headerName, PeerScopeDenied.headerValue)
            }
            try? await writeSimple(status: status, message: message, keepAlive: false, head: isHead, extra: extra)
            return false
        }
        let forwarded = PeerHTTPRequest(
            method: request.method, path: request.target,
            header: PeerHeaderFilter.outbound(request.header, policy: configuration.cookiePolicy,
                                              upstreamOrigin: configuration.upstreamOrigin),
            body: request.body)
        let response: PeerHTTPResponse
        do {
            response = try await forwarder.forward(forwarded, headTimeout: configuration.headTimeout)
        } catch {
            let status: Int
            switch error as? PeerWireError {
            case .timedOut?: status = 504
            case .tooManyStreams?: status = 503
            case .requestBodyTooLarge?: status = 413
            case .invalidRequest?: status = 400
            case .unauthorized?: status = 401
            default: status = 502
            }
            try? await writeSimple(status: status, message: "Peer unavailable", keepAlive: keepAlive, head: isHead)
            return keepAlive && status != 401
        }
        lock.withLock { activeCancel = response.cancel }
        input.onEOF { response.cancel() }
        defer {
            input.clearEOFHandlers()
            lock.withLock { activeCancel = nil }
        }

        let noBody = isHead || response.status == 204 || response.status == 304 || (100..<200).contains(response.status)
        let chunked = !noBody && request.version == "HTTP/1.1"
        var header = PeerHeaderFilter.inbound(response.header, policy: configuration.cookiePolicy)
        if chunked { header.set("Transfer-Encoding", "chunked") }
        let persistent = keepAlive && (chunked || noBody)
        header.set("Connection", persistent ? "keep-alive" : "close")
        do {
            try await stream.write(Self.head(status: response.status, header: header))
            if noBody {
                response.cancel()  // nothing will be relayed; release the remote stream
                return persistent
            }
            for try await chunk in response.body where !chunk.isEmpty {
                guard isAuthorized() else { response.cancel(); return false }
                if chunked {
                    var framed = Data(String(chunk.count, radix: 16).utf8)
                    framed.append(contentsOf: [0x0D, 0x0A])
                    framed.append(chunk)
                    framed.append(contentsOf: [0x0D, 0x0A])
                    try await stream.write(framed)
                } else {
                    try await stream.write(chunk)
                }
            }
            if chunked { try await stream.write(Data("0\r\n\r\n".utf8)) }
            return persistent
        } catch {
            // Mid-stream failure: abort the connection without a terminating
            // chunk so WebKit observes a truncated (failed) response.
            response.cancel()
            return false
        }
    }

    private func writeSimple(status: Int, message: String, keepAlive: Bool, head: Bool,
                             extra: PeerHeader = PeerHeader()) async throws {
        let body = Data((message + "\n").utf8)
        var header = extra
        header.set("Content-Type", "text/plain; charset=utf-8")
        header.set("Content-Length", String(body.count))
        header.set("Cache-Control", "no-store")
        header.set("Connection", keepAlive ? "keep-alive" : "close")
        var data = Self.head(status: status, header: header)
        if !head { data.append(body) }
        try await stream.write(data)
    }

    static func head(status: Int, header: PeerHeader) -> Data {
        var text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for name in header.names {
            for value in header.values(name) where PeerHeader.isValidValue(value) {
                text += "\(name): \(value)\r\n"
            }
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        case 421: return "Misdirected Request"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status"
        }
    }
}
