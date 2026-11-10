import Foundation

// MARK: - Direct node response models

/// Full health response from a direct node's GET /healthz endpoint.
/// Extends the protocol's HealthResponse with optional identity fields that
/// the node discloses only to authenticated callers.
struct DirectNodeHealth: Codable, Sendable, Equatable {
    let status: String
    let agent: String?
    let version: String?
    let capabilities: [String]?
}

/// Attention kinds supported by the direct node's /v1/attention endpoint.
enum DirectAttentionKind: String, Sendable, Codable, CaseIterable {
    case unseen        = "unseen"
    case running       = "running"
    case inputRequired = "input_required"
}

/// One item returned by GET /v1/attention.
/// Timestamps are ISO8601 strings (Go `time.Time` JSON marshaling).
struct DirectAttentionItem: Codable, Sendable, Equatable {
    let sessionID: String
    let sessionNumber: Int64?
    let responseID: String?
    let kind: String?
    let lifecycleState: String?
    let attentionSeq: Int64?
    let shortTitle: String?
    let longTitle: String?
    let outcome: String?
    let terminalAt: String?
    let startedAt: String?
    let interactionRequired: Bool?
    let pendingInteractionCount: Int?
    let pendingInteractionKinds: [String]?
    let interactionRequiredSince: String?
    let seenThroughSeq: Int64?
    let seenRev: Int64?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionNumber = "session_number"
        case responseID = "response_id"
        case kind
        case lifecycleState = "lifecycle_state"
        case attentionSeq = "attention_seq"
        case shortTitle = "short_title"
        case longTitle = "long_title"
        case outcome
        case terminalAt = "terminal_at"
        case startedAt = "started_at"
        case interactionRequired = "interaction_required"
        case pendingInteractionCount = "pending_interaction_count"
        case pendingInteractionKinds = "pending_interaction_kinds"
        case interactionRequiredSince = "interaction_required_since"
        case seenThroughSeq = "seen_through_seq"
        case seenRev = "seen_rev"
    }
}

/// Paginated response from GET /v1/attention.
struct DirectAttentionPage: Codable, Sendable, Equatable {
    let protocolVersion: Int?
    let storeInstanceID: String
    let snapshotVersion: Int64?
    let items: [DirectAttentionItem]
    let nextCursor: String?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case storeInstanceID = "store_instance_id"
        case snapshotVersion = "snapshot_version"
        case items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

/// One session row returned by GET /v1/sessions/status.
/// Timestamps are unix milliseconds (int64).
struct DirectNodeSessionEntry: Codable, Sendable, Equatable {
    let id: String
    let number: Int64?
    let projectID: String?
    let projectName: String?
    let shortTitle: String
    let longTitle: String?
    let pinned: Bool?
    let activeRun: Bool?
    let activeResponseID: String?
    let runEpoch: Int64?
    let startedRev: Int64?
    let startedAt: Int64?
    let transcriptRev: Int64?
    let messageCount: Int?
    let lastMessageAt: Int64?
    let attentionStoreInstanceID: String?
    let attentionSeq: Int64?
    let attentionResponseID: String?
    let seenThroughSeq: Int64?
    let seenRev: Int64?
    let seenSource: String?
    let attentionUnseen: Bool?
    let attentionOutcome: String?
    let attentionTerminalAt: Int64?
    let interactionRequired: Bool?
    let pendingInteractionCount: Int?
    let pendingInteractionKinds: [String]?

    enum CodingKeys: String, CodingKey {
        case id, number
        case projectID = "project_id"
        case projectName = "project_name"
        case shortTitle = "short_title"
        case longTitle = "long_title"
        case pinned
        case activeRun = "active_run"
        case activeResponseID = "active_response_id"
        case runEpoch = "run_epoch"
        case startedRev = "started_rev"
        case startedAt = "started_at"
        case transcriptRev = "transcript_rev"
        case messageCount = "message_count"
        case lastMessageAt = "last_message_at"
        case attentionStoreInstanceID = "attention_store_instance_id"
        case attentionSeq = "attention_seq"
        case attentionResponseID = "attention_response_id"
        case seenThroughSeq = "seen_through_seq"
        case seenRev = "seen_rev"
        case seenSource = "seen_source"
        case attentionUnseen = "attention_unseen"
        case attentionOutcome = "attention_outcome"
        case attentionTerminalAt = "attention_terminal_at"
        case interactionRequired = "interaction_required"
        case pendingInteractionCount = "pending_interaction_count"
        case pendingInteractionKinds = "pending_interaction_kinds"
    }
}

/// Response from GET /v1/sessions/status.
struct DirectNodeSessionsStatus: Codable, Sendable, Equatable {
    let sessions: [DirectNodeSessionEntry]
}

// MARK: - DirectNodeClient

/// A ``HubServing`` adapter that connects directly to a single term-llm node
/// without a hub intermediary.
///
/// ## Security invariants
///
/// | Concern | Mechanism |
/// |---|---|
/// | Cookie | Only `term_llm_web_session`, exact host, mount path + `/`, Secure (HTTPS only), unexpired |
/// | Hub cookie exclusion | `term_llm_hub_*` cookies are never forwarded; no root / sibling path leakage |
/// | Bearer for all requests | `Authorization: Bearer` injected on every native request (GET + POST) and GET /healthz |
/// | Origin | Set on every mutation (POST / PATCH / DELETE) |
/// | onUnauthorized | Thread-safe, epoch-scoped — stale callbacks silenced after auth change |
/// | validateBearer | GET /healthz with candidate bearer, NO ambient cookies; rejects bare-200 without identity markers |
/// | Redirects | Blocked by the underlying transport |
///
/// ## Supported HubServing methods
/// `healthz()`, `listNodes()`, `listAttention(limit:)`, `markAttentionSeen(_:)`,
/// `listDelegations()`
///
/// ## Unsupported HubServing methods (throw HTTP 501)
/// Bulk attention clear, all node management, registration, auth / security /
/// passkey ceremonies, grant operations, native authorize.
///
/// ## Additional node-specific methods
/// `sessionsStatus()`, `listNodeAttention(kind:limit:)`,
/// `nodeHealth()`, `validateBearer(token:)`, `resumePath(sessionID:sessionNumber:)`
final class DirectNodeClient: @unchecked Sendable {

    // MARK: - Properties

    /// Base URL of the node (e.g. `http://localhost:8767/direct/`).
    let baseURL: URL

    /// Mount path derived from `baseURL.path`, normalised (no trailing slash,
    /// empty string for root).  Web session cookie must be scoped to `mountPath + "/"`.
    let mountPath: String

    /// Exact lowercase host from baseURL.  Cookie filtering rejects domain cookies.
    let expectedHost: String

    /// Scheme + host[:port], omitting default ports.  Sent as Origin on mutations.
    let origin: String

    let isHTTPS: Bool

    let cookieSource: @Sendable () async -> [HTTPCookie]
    let bearerSource: @Sendable () async -> String?
    let displayNameSource: @Sendable () async -> String?

    private let transport: any HubTransport

    /// 401/403 callback — thread-safe and epoch-scoped.
    private let authLock = NSLock()
    private var _authCallback: (@Sendable () async -> Void)?
    private var _authEpoch: UInt64 = 0

    /// Fired as soon as the transport surfaces a 401/403, before body completion.
    var onUnauthorized: (@Sendable () async -> Void)? {
        get {
            authLock.lock()
            defer { authLock.unlock() }
            return _authCallback
        }
        set {
            authLock.lock()
            _authCallback = newValue
            _authEpoch &+= 1
            authLock.unlock()
        }
    }

    static let defaultTimeout: TimeInterval = 30

    // MARK: - Initializer

    /// - Parameters:
    ///   - baseURL: Node origin + optional base path.
    ///   - cookieSource: Async closure returning all cookies from the WK store.
    ///     Only `term_llm_web_session` at the exact host + mount path is forwarded.
    ///   - bearerSource: Async closure returning an optional native bearer token
    ///     (e.g. from Keychain).  Injected for POST/PATCH/DELETE and GET /healthz.
    ///   - transport: Injectable transport for testing.  Defaults to
    ///     ``URLSessionHubTransport`` in production.
    ///   - displayNameSource: Current saved connection name, used when health
    ///     does not supply a nonblank agent name.
    init(
        baseURL: URL,
        cookieSource: @escaping @Sendable () async -> [HTTPCookie],
        bearerSource: @escaping @Sendable () async -> String?,
        transport: (any HubTransport)? = nil,
        displayNameSource: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.baseURL = baseURL
        self.cookieSource = cookieSource
        self.bearerSource = bearerSource
        self.displayNameSource = displayNameSource
        self.isHTTPS = baseURL.scheme?.lowercased() == "https"
        self.expectedHost = (baseURL.host ?? "").lowercased()
        self.transport = transport ?? URLSessionHubTransport()

        // Use percentEncodedPath so mountPath is already percent-encoded and can
        // be safely concatenated with other pre-encoded segments in mounted().
        let raw = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!.percentEncodedPath
        if raw == "/" || raw.isEmpty {
            self.mountPath = ""
        } else {
            self.mountPath = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        }

        let defaultPort = baseURL.scheme == "http" ? 80 : 443
        let port = baseURL.port == defaultPort ? ""
            : baseURL.port.map { ":\($0)" } ?? ""
        self.origin = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "localhost")\(port)"
    }

    // MARK: - Cookie filtering (term_llm_web_session only)

    /// Filters cookies for a direct node request.
    ///
    /// - **Name**: must be exactly `term_llm_web_session`.
    ///   All `term_llm_hub_*` cookies and other names are excluded.
    /// - **Exact host**: cookie domain must equal `expectedHost`; domain cookies rejected.
    /// - **Path**: must equal the auth path (`mountPath + "/"` or `/` for root).
    ///   No root, sibling, or parent path leakage.
    /// - **Secure**: secure cookies only sent over HTTPS.
    /// - **Expiry**: expired cookies dropped.
    func filteredCookies(_ cookies: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        let now = Date()
        let authPath = mountPath.isEmpty ? "/" : mountPath + "/"
        return cookies.filter { cookie in
            guard cookie.name == "term_llm_web_session" else { return false }
            guard cookie.domain.lowercased() == expectedHost else { return false }
            let cp = cookie.path.isEmpty ? "/" : cookie.path
            guard cp == authPath else { return false }
            if cookie.isSecure && !isHTTPS { return false }
            if let expires = cookie.expiresDate, expires < now { return false }
            return true
        }
    }

    // MARK: - Session resume path

    /// Compute the browser resume URL for a session.
    ///
    /// Preserves session numbers (`/chat/42`) over opaque IDs (`/chat/<uuid>`).
    func resumePath(sessionID: String, sessionNumber: Int64?) -> String {
        let base = "\(mountPath)/chat/"
        if let n = sessionNumber, n > 0 { return "\(base)\(n)" }
        return "\(base)\(sessionID)"
    }

    // MARK: - Node-specific public methods

    /// GET /v1/sessions/search — full-text session search on this node.
    func searchSessions(query: String, limit: Int) async throws -> SessionSearchResponse {
        try await request("/v1/sessions/search?\(SessionSearchQuery.percentEncoded(query: query, limit: limit))")
    }

    /// GET /v1/sessions/status — list of sessions with attention and run state.
    func sessionsStatus() async throws -> DirectNodeSessionsStatus {
        try await request("/v1/sessions/status")
    }

    /// GET /v1/attention?kind=<kind>[&limit=<1…500>] — single-kind attention page.
    ///
    /// `limit` is clamped to `[1, 500]`.  Uses the same bounded 409-retry as
    /// ``listAttention`` (up to 3 attempts) for consistency.
    func listNodeAttention(kind: DirectAttentionKind, limit: Int? = nil) async throws -> DirectAttentionPage {
        try await fetchAttentionWithRetry(kind: kind, limit: limit)
    }

    /// GET /healthz with the current bearer token; returns identity fields.
    func nodeHealth() async throws -> DirectNodeHealth {
        try await fetchHealthAuthenticated(useCallback: true)
    }

    /// Validate a candidate bearer token via GET /healthz, **excluding ambient cookies**.
    ///
    /// Sends only `Authorization: Bearer <token>` — no cookies — so an existing
    /// passkey session cannot mask a bad token.  A bare HTTP 200 response without
    /// identity markers (`version` or `capabilities`) is treated as authentication
    /// failure; those fields are only included when the node trusts the caller.
    ///
    /// Does **not** modify the stored bearer credential, does **not** fire
    /// `onUnauthorized` on a failed probe.
    ///
    /// - Throws: ``HubAPIError`` on non-2xx or on 200 without identity markers.
    func validateBearer(token: String) async throws -> DirectNodeHealth {
        let url = mounted("/healthz")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false
        req.timeoutInterval = Self.defaultTimeout
        // Candidate bearer; explicitly NO cookies
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, http) = try await transport.execute(req,
            onUnauthorized: nil as (@Sendable () async -> Void)?)

        guard (200...299).contains(http.statusCode) else {
            let parsed = try? JSONDecoder().decode(DirectErrorBody.self, from: data)
            let fallback = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw HubAPIError(
                status: http.statusCode,
                message: parsed?.error?.message ?? parsed?.message ?? fallback,
                type: parsed?.error?.type ?? ""
            )
        }
        if data.isEmpty {
            throw HubAPIError(status: 200, message: "Node returned empty health response.")
        }
        let health = try JSONDecoder().decode(DirectNodeHealth.self, from: data)
        // A bare 200 without identity means the node is open or the token was not used.
        // Passkey sessions return identity too, but those are excluded by the no-cookie policy.
        guard health.version != nil || health.capabilities != nil else {
            throw HubAPIError(
                status: 401,
                message: "Bearer token not accepted: node returned anonymous health (no identity markers)."
            )
        }
        return health
    }

    // MARK: - Shared health fetch

    private func fetchHealthAuthenticated(useCallback: Bool) async throws -> DirectNodeHealth {
        let authCapture: (epoch: UInt64, callback: (@Sendable () async -> Void)?)
        if useCallback {
            authCapture = captureAuthorization()
        } else {
            let snapshot = captureAuthorization()
            authCapture = (epoch: snapshot.epoch, callback: nil)
        }

        let url = mounted("/healthz")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false
        req.timeoutInterval = Self.defaultTimeout

        // Cookies
        let cookies = filteredCookies(await cookieSource(), for: url)
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        // Bearer (always for healthz — identity requires auth)
        if let t = await bearerSource() {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }

        guard authorizationIsCurrent(authCapture.epoch), !Task.isCancelled else { throw CancellationError() }
        let (data, http) = try await transport.execute(req, onUnauthorized: authCapture.callback)

        guard (200...299).contains(http.statusCode) else {
            let parsed = try? JSONDecoder().decode(DirectErrorBody.self, from: data)
            let fallback = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw HubAPIError(
                status: http.statusCode,
                message: parsed?.error?.message ?? parsed?.message ?? fallback,
                type: parsed?.error?.type ?? ""
            )
        }
        if data.isEmpty {
            throw HubAPIError(status: 200, message: "Node returned empty health response.")
        }
        return try JSONDecoder().decode(DirectNodeHealth.self, from: data)
    }

    // MARK: - Private transport helpers

    private func mounted(_ path: String) -> URL {
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        let pathPart: String
        let queryPart: String?
        if let qIndex = suffix.firstIndex(of: "?") {
            pathPart = String(suffix[..<qIndex])
            queryPart = String(suffix[suffix.index(after: qIndex)...])
        } else {
            pathPart = suffix
            queryPart = nil
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // percentEncodedPath: mountPath is already percent-encoded (derived from
        // baseURL.percentEncodedPath), and pathPart may contain pre-encoded segments
        // like %2F in session IDs.  Using the plain .path setter would re-encode %
        // as %25 (double-encoding); .percentEncodedPath leaves existing escapes intact.
        components.percentEncodedPath = "\(mountPath)\(pathPart)"
        // percentEncodedQuery: query string is built from safe ASCII values only;
        // using the plain .query setter would unnecessarily re-escape & and =.
        components.percentEncodedQuery = queryPart
        return components.url!
    }

    private enum Method: String { case GET, POST, PATCH, DELETE }

    private func captureAuthorization() -> (epoch: UInt64, callback: (@Sendable () async -> Void)?) {
        authLock.lock()
        let epoch = _authEpoch
        let callback = _authCallback
        authLock.unlock()
        guard let callback else { return (epoch, nil) }
        return (epoch, { [weak self] in
            guard self?.authorizationIsCurrent(epoch) == true else { return }
            await callback()
        })
    }

    private func authorizationIsCurrent(_ epoch: UInt64) -> Bool {
        authLock.lock()
        defer { authLock.unlock() }
        return _authEpoch == epoch
    }

    private func request<T: Decodable>(
        _ path: String,
        method: Method = .GET,
        body: (any Encodable)? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        let data = try await executeRequest(path, method: method, body: body,
                                            extraHeaders: extraHeaders)
        if data.isEmpty {
            throw HubAPIError(status: 200, message: "Node returned an empty response.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func executeRequest(
        _ path: String,
        method: Method = .GET,
        body: (any Encodable)? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        let authorization = captureAuthorization()
        let url = mounted(path)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = Self.defaultTimeout

        if method != .GET {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // Cookie: term_llm_web_session only
        let cookies = filteredCookies(await cookieSource(), for: url)
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // Bearer on ALL native requests (GET + mutations)
        if let t = await bearerSource() {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }

        guard authorizationIsCurrent(authorization.epoch), !Task.isCancelled else { throw CancellationError() }
        let (data, http) = try await transport.execute(request,
                                                        onUnauthorized: authorization.callback)

        guard (200...299).contains(http.statusCode) else {
            let parsed = try? JSONDecoder().decode(DirectErrorBody.self, from: data)
            let fallback: String
            if let text = String(data: data, encoding: .utf8), !text.isEmpty { fallback = text }
            else { fallback = "Node request failed (\(http.statusCode))." }
            throw HubAPIError(
                status: http.statusCode,
                message: parsed?.error?.message ?? parsed?.message ?? fallback,
                type: parsed?.error?.type ?? ""
            )
        }
        return data
    }

    // MARK: - Attention helpers

    private func attentionQuery(kind: DirectAttentionKind, limit: Int?) -> String {
        var q = "?kind=\(kind.rawValue)"
        if let l = limit { q += "&limit=\(min(max(l, 1), 500))" }
        return q
    }

    /// Fetch a single attention page; caller provides already-clamped limit.
    private func fetchAttentionOnce(kind: DirectAttentionKind, limit: Int?) async throws -> DirectAttentionPage {
        let q = attentionQuery(kind: kind, limit: limit.map { min(max($0, 1), 500) })
        return try await request("/v1/attention\(q)")
    }

    /// Fetch with bounded 409 retry (up to `maxAttempts`).
    /// A 409 means the attention snapshot changed; retry re-reads a fresh snapshot.
    private func fetchAttentionWithRetry(
        kind: DirectAttentionKind,
        limit: Int?,
        maxAttempts: Int = 3
    ) async throws -> DirectAttentionPage {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                // Bounded exponential back-off: 0, 100 ms, 200 ms
                try await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
            }
            do {
                return try await fetchAttentionOnce(kind: kind, limit: limit)
            } catch let err as HubAPIError where err.status == 409 {
                lastError = err
            }
        }
        throw lastError ?? HubAPIError(status: 409, message: "Attention snapshot conflict after \(maxAttempts) attempts.")
    }

    // MARK: - Adaptation: DirectAttentionPage → HubServing types

    private func nodeSession(from entry: DirectNodeSessionEntry) -> HubNodeSession {
        HubNodeSession(
            id: entry.id,
            number: entry.number.map(Int.init),
            shortTitle: entry.shortTitle,
            longTitle: entry.longTitle,
            pinned: entry.pinned,
            activeRun: entry.activeRun,
            interactionRequired: entry.interactionRequired,
            pendingInteractionCount: entry.pendingInteractionCount,
            pendingInteractionKinds: entry.pendingInteractionKinds,
            lastMessageAt: entry.lastMessageAt.map(Int.init),
            messageCount: entry.messageCount,
            resumePath: resumePath(
                sessionID: entry.id,
                sessionNumber: entry.number
            )
        )
    }

    private func inboxItem(
        from item: DirectAttentionItem,
        storeInstanceID: String
    ) -> HubAttentionInboxItem {
        HubAttentionInboxItem(
            nodeID: "direct-node",
            nodeName: "direct-node",
            sessionID: item.sessionID,
            storeInstanceID: storeInstanceID,
            sessionNumber: item.sessionNumber.map(Int.init),
            title: item.shortTitle ?? "",
            outcome: item.outcome ?? item.lifecycleState ?? "",
            terminalAt: item.terminalAt,
            attentionSeq: Int(item.attentionSeq ?? 0),
            resumePath: resumePath(
                sessionID: item.sessionID,
                sessionNumber: item.sessionNumber
            )
        )
    }

    private func inputRequiredItem(from item: DirectAttentionItem) -> HubInputRequiredItem {
        HubInputRequiredItem(
            nodeID: "direct-node",
            nodeName: "direct-node",
            sessionID: item.sessionID,
            sessionNumber: item.sessionNumber.map(Int.init),
            title: item.shortTitle ?? "",
            pendingInteractionCount: item.pendingInteractionCount ?? 0,
            pendingInteractionKinds: item.pendingInteractionKinds,
            requiredSince: item.interactionRequiredSince,
            resumePath: resumePath(
                sessionID: item.sessionID,
                sessionNumber: item.sessionNumber
            ),
            stale: nil
        )
    }
}

// MARK: - HubServing conformance

extension DirectNodeClient: HubServing {

    // MARK: Nodes

    /// Adapts GET /v1/sessions/status (and optional GET /healthz) into a single
    /// synthetic ``HubNode``.
    ///
    /// Health is fetched concurrently with sessions/status.  A health failure
    /// does **not** fail the call. A missing or blank agent falls back to the
    /// current saved display name, then "direct-node". The node ID remains the
    /// stable sentinel "direct-node".
    /// Sessions are split into `active` (running or input-required) and `recent`.
    func listNodes() async throws -> NodesResponse {
        // Concurrent: sessions/status (required) + healthz identity (best-effort)
        async let statusTask = sessionsStatus()
        async let healthTask = fetchHealthAuthenticated(useCallback: false)

        let status = try await statusTask
        let health = try? await healthTask

        let entries = status.sessions
        let healthAgent = health?.agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agentName: String
        if !healthAgent.isEmpty {
            agentName = healthAgent
        } else {
            let displayName = await displayNameSource()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            agentName = displayName.isEmpty ? "direct-node" : displayName
        }

        let activeSessions = entries.filter { $0.activeRun == true || $0.interactionRequired == true }
        let recentSessions = entries.filter { $0.activeRun != true && $0.interactionRequired != true }

        let activeCount  = activeSessions.count
        let inputCount   = entries.filter { $0.interactionRequired == true }.count
        let unseenCount  = entries.filter { $0.attentionUnseen == true }.count

        let nodeSessions = HubNodeSessions(
            countLabel: "\(entries.count) \(entries.count == 1 ? "conversation" : "conversations")",
            hasMore: false,
            activeCount: activeCount,
            inputRequiredCount: inputCount,
            unseenCount: unseenCount,
            attentionCapability: nil,
            attentionLastSuccessAt: nil,
            active: activeSessions.isEmpty ? nil : activeSessions.map { nodeSession(from: $0) },
            recent: recentSessions.isEmpty ? nil : recentSessions.map { nodeSession(from: $0) },
            resumePath: mountPath.isEmpty ? "/" : mountPath + "/"
        )

        let nodeStatus = HubNodeStatus(
            reachable: true,
            state: "ok",
            latencyMs: 0,
            version: health?.version,
            agent: agentName,
            capabilities: health?.capabilities,
            details: nil,
            error: nil
        )

        let node = HubNode(
            id: "direct-node",
            name: agentName,
            source: "direct",
            connection: "direct",
            url: baseURL.absoluteString,
            basePath: mountPath.isEmpty ? "/" : mountPath + "/",
            proxyPath: mountPath.isEmpty ? "/" : mountPath + "/",
            newSessionPath: mountPath.isEmpty ? "/?new=1" : "\(mountPath)/?new=1",
            hasToken: false,
            status: nodeStatus,
            sessions: nodeSessions,
            diagnostics: nil
        )

        return NodesResponse(nodes: [node], resolverError: nil)
    }

    func testNode(_ form: NodeFormData) async throws -> TestNodeResponse {
        throw HubAPIError(status: 501, message: "Node management is unavailable on a direct connection.")
    }

    func addNode(_ form: NodeFormData) async throws -> AddNodeResponse {
        throw HubAPIError(status: 501, message: "Node management is unavailable on a direct connection.")
    }

    func removeNode(id: String) async throws -> RemovedNodeResponse {
        throw HubAPIError(status: 501, message: "Node management is unavailable on a direct connection.")
    }

    func reorderNodes(nodeIDs: [String]) async throws -> NodeOrderResponse {
        throw HubAPIError(status: 501, message: "Node management is unavailable on a direct connection.")
    }

    // MARK: Attention

    /// Fetches unseen + input_required + running attention items concurrently.
    ///
    /// All three kind requests run in parallel, each with bounded 409 retry
    /// (up to 3 attempts).  A failure on the running kind produces
    /// `totalRunning = 0` without failing the overall call.
    ///
    /// `limit` is clamped to `[1, 500]`.
    func listAttention(limit: Int? = nil) async throws -> AttentionResponse {
        let clamped = limit.map { min(max($0, 1), 500) }

        // Concurrent: unseen inbox + input_required list + running count
        async let unseenTask   = fetchAttentionWithRetry(kind: .unseen, limit: clamped)
        async let inputTask    = fetchAttentionWithRetry(kind: .inputRequired, limit: clamped)
        async let runningTask  = fetchAttentionWithRetry(kind: .running, limit: clamped)

        let unseenPage   = try await unseenTask
        let inputPage    = try await inputTask
        // Running: best-effort — failure → count 0
        let runningPage  = try? await runningTask
        let runningCount = runningPage?.items.count ?? 0

        let inbox = unseenPage.items.map {
            inboxItem(from: $0, storeInstanceID: unseenPage.storeInstanceID)
        }
        let inputRequired = inputPage.items.map { inputRequiredItem(from: $0) }

        let attentionNode = HubAttentionNode(
            nodeID: "direct-node",
            nodeName: "direct-node",
            capabilityState: "ok",
            stale: false,
            lastSuccessAt: nil,
            lastError: nil,
            runningCount: runningCount,
            inputRequiredCount: inputPage.items.count,
            unseenCount: unseenPage.items.count,
            hasGreenIndicator: runningCount == 0 && inputPage.items.isEmpty
                && unseenPage.items.isEmpty && !unseenPage.hasMore
        )

        return AttentionResponse(
            totalRunning: runningCount,
            totalInputRequired: inputPage.items.count,
            totalUnseen: unseenPage.items.count,
            nodes: [attentionNode],
            inputRequired: inputRequired,
            inbox: inbox,
            hasMore: unseenPage.hasMore || inputPage.hasMore
        )
    }

    /// No bulk-clear endpoint on a direct node.
    func clearAttention() async throws -> ClearAttentionResponse {
        throw HubAPIError(status: 501, message: "Bulk attention clear is unavailable on a direct connection.")
    }

    /// POST /v1/sessions/{session_id}/attention/seen
    ///
    /// Body: `{store_instance_id, through_seq}`.
    /// Header: `X-Term-LLM-Attention-Source: phone`.
    ///
    /// - Throws: ``HubAPIError(status: 409, …)`` on snapshot conflict — caller
    ///   should reconcile authoritative session state and bounded-retry.
    func markAttentionSeen(_ item: AttentionSeenRequest) async throws -> SeenAttentionResponse {
        guard !item.sessionID.isEmpty, item.sessionID != ".", item.sessionID != ".." else {
            throw HubAPIError(status: 0, message: "Invalid session identifier for attention acknowledgement.")
        }
        struct SeenBody: Encodable {
            let storeInstanceID: String
            let throughSeq: Int

            enum CodingKeys: String, CodingKey {
                case storeInstanceID = "store_instance_id"
                case throughSeq = "through_seq"
            }
        }
        let seenBody = SeenBody(
            storeInstanceID: item.storeInstanceID,
            throughSeq: item.attentionSeq
        )
        let path = "/v1/sessions/\(item.sessionID.directNodePathEncoded)/attention/seen"
        _ = try await executeRequest(
            path, method: .POST, body: seenBody,
            extraHeaders: ["X-Term-LLM-Attention-Source": "phone"]
        )
        return SeenAttentionResponse(cleared: 1)
    }

    // MARK: Delegations

    /// Returns an empty list — a direct node has no hub delegation graph.
    func listDelegations() async throws -> DelegationsResponse {
        DelegationsResponse(delegations: [])
    }

    // MARK: Registration — unsupported

    func registrationInfo() async throws -> RegistrationInfoResponse {
        throw HubAPIError(status: 501, message: "Registration is unavailable on a direct connection.")
    }

    // MARK: Auth / Session / Security — unsupported

    func session() async throws -> HubSessionResponse {
        throw HubAPIError(status: 501, message: "Session management is unavailable on a direct connection.")
    }

    func listCredentials() async throws -> CredentialsResponse {
        throw HubAPIError(status: 501, message: "Credential management is unavailable on a direct connection.")
    }

    func renameCredential(recordID: String, displayName: String) async throws -> HubCredential {
        throw HubAPIError(status: 501, message: "Credential management is unavailable on a direct connection.")
    }

    func removeCredential(recordID: String) async throws -> OkResponse {
        throw HubAPIError(status: 501, message: "Credential management is unavailable on a direct connection.")
    }

    func revokeOtherSessions() async throws -> RevokeSessionsResponse {
        throw HubAPIError(status: 501, message: "Session management is unavailable on a direct connection.")
    }

    func logout() async throws -> RedirectResponse {
        throw HubAPIError(status: 501, message: "Logout is unavailable on a direct connection.")
    }

    // MARK: Passkey ceremonies — unsupported

    func beginLogin(returnPath: String) async throws -> Data {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func finishLogin(credential: Data) async throws -> RedirectResponse {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func beginReauthentication() async throws -> Data {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func finishReauthentication(credential: Data) async throws -> OkResponse {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func beginAdditionalRegistration(displayName: String) async throws -> Data {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func finishAdditionalRegistration(credential: Data) async throws -> HubCredential {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    // MARK: Grant registration — unsupported

    func verifyGrant(prefix: GrantPrefix, code: String) async throws -> OkResponse {
        throw HubAPIError(status: 501, message: "Grant registration is unavailable on a direct connection.")
    }

    func beginGrantRegistration(prefix: GrantPrefix, displayName: String) async throws -> Data {
        throw HubAPIError(status: 501, message: "Grant registration is unavailable on a direct connection.")
    }

    func finishGrantRegistration(
        prefix: GrantPrefix, credential: Data, returnPath: String
    ) async throws -> RedirectResponse {
        throw HubAPIError(status: 501, message: "Grant registration is unavailable on a direct connection.")
    }

    // MARK: Native authorize — unsupported

    func authorizeNative(challenge: String) async throws -> RedirectResponse {
        throw HubAPIError(status: 501, message: "Native authorize is unavailable on a direct connection.")
    }

    // MARK: Health

    /// GET /healthz with the current bearer token (injected for identity disclosure).
    ///
    /// Returns the protocol ``HealthResponse``; call ``nodeHealth()`` for the
    /// full identity payload including `agent`, `version`, and `capabilities`.
    func healthz() async throws -> HealthResponse {
        let health = try await fetchHealthAuthenticated(useCallback: true)
        return HealthResponse(status: health.status)
    }
}

// MARK: - Private helpers

/// Error body the node (and hub) send on non-2xx responses.
private struct DirectErrorBody: Decodable {
    let message: String?
    let error: ErrorDetail?

    struct ErrorDetail: Decodable {
        let message: String?
        let type: String?
    }
}

private extension String {
    /// Percent-encodes a string for use as a **single URL path segment**.
    ///
    /// Unlike `.urlPathAllowed`, this set additionally excludes `/` so that slashes
    /// inside a session ID (e.g. `"sess/id"`) are encoded as `%2F` rather than
    /// being interpreted as path separators.  `%` itself is not in `.urlPathAllowed`
    /// so it is always encoded, preventing double-encoding when the string already
    /// contains `%XX` sequences.
    var directNodePathEncoded: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

extension DirectNodeClient: HubSessionSearching {
    func searchSessions(nodeID: String, query: String, limit: Int) async throws -> SessionSearchResponse {
        try await searchSessions(query: query, limit: limit)
    }

    func sessionsStatus(nodeID: String, ids: [String]) async throws -> DirectNodeSessionsStatus {
        guard let query = SessionSearchQuery.percentEncodedStatus(ids: ids) else { return DirectNodeSessionsStatus(sessions: []) }
        return try await request("/v1/sessions/status?\(query)")
    }
}

extension DirectNodeClient: HubSessionBrowsing {
    /// GET /v1/sessions — the web sidebar's listing, every project, paged.
    func listSessions(nodeID: String, limit: Int, cursor: String?) async throws -> AgentSessionPage {
        try await request("/v1/sessions?\(AgentSessionQuery.percentEncoded(limit: limit, cursor: cursor))")
    }

    /// PATCH /v1/sessions/{id} — rename, archive or pin one conversation.
    func updateSession(nodeID: String, sessionID: String, patch: AgentSessionPatch) async throws -> AgentSessionPatchResult {
        guard AgentSessionQuery.isSafeSessionID(sessionID) else {
            throw HubAPIError(status: 0, message: "Unsafe session identifier.")
        }
        return try await request("/v1/sessions/\(sessionID.directNodePathEncoded)", method: .PATCH, body: patch)
    }

    /// PATCH /v1/sessions/pinned-order — the listed pins swap into the ranks
    /// they already hold; the answer is the complete committed order.
    func reorderPinnedSessions(nodeID: String, sessionIDs: [String]) async throws -> PinnedSessionOrder {
        guard sessionIDs.allSatisfy(AgentSessionQuery.isSafeSessionID) else {
            throw HubAPIError(status: 0, message: "Unsafe session identifier.")
        }
        return try await request("/v1/sessions/pinned-order", method: .PATCH, body: ["session_ids": sessionIDs])
    }
}
