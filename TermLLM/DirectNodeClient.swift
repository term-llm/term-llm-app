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
    case input_required = "input_required"
}

/// One item returned by GET /v1/attention.
/// Timestamps are ISO8601 strings (Go `time.Time` JSON marshaling).
struct DirectAttentionItem: Codable, Sendable, Equatable {
    let session_id: String
    let session_number: Int64?
    let response_id: String?
    let kind: String?
    let lifecycle_state: String?
    let attention_seq: Int64?
    let short_title: String?
    let long_title: String?
    let outcome: String?
    let terminal_at: String?
    let started_at: String?
    let interaction_required: Bool?
    let pending_interaction_count: Int?
    let pending_interaction_kinds: [String]?
    let interaction_required_since: String?
    let seen_through_seq: Int64?
    let seen_rev: Int64?
}

/// Paginated response from GET /v1/attention.
struct DirectAttentionPage: Codable, Sendable, Equatable {
    let protocol_version: Int?
    let store_instance_id: String
    let snapshot_version: Int64?
    let items: [DirectAttentionItem]
    let next_cursor: String?
    let has_more: Bool
}

/// One session row returned by GET /v1/sessions/status.
/// Timestamps are unix milliseconds (int64).
struct DirectNodeSessionEntry: Codable, Sendable, Equatable {
    let id: String
    let number: Int64?
    let project_id: String?
    let project_name: String?
    let short_title: String
    let long_title: String?
    let pinned: Bool?
    let active_run: Bool?
    let active_response_id: String?
    let run_epoch: Int64?
    let started_rev: Int64?
    let started_at: Int64?
    let transcript_rev: Int64?
    let message_count: Int?
    let last_message_at: Int64?
    let attention_store_instance_id: String?
    let attention_seq: Int64?
    let attention_response_id: String?
    let seen_through_seq: Int64?
    let seen_rev: Int64?
    let seen_source: String?
    let attention_unseen: Bool?
    let attention_outcome: String?
    let attention_terminal_at: Int64?
    let interaction_required: Bool?
    let pending_interaction_count: Int?
    let pending_interaction_kinds: [String]?
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
/// | on_unauthorized | Thread-safe, epoch-scoped — stale callbacks silenced after auth change |
/// | validate_bearer | GET /healthz with candidate bearer, NO ambient cookies; rejects bare-200 without identity markers |
/// | Redirects | Blocked by the underlying transport |
///
/// ## Supported HubServing methods
/// `healthz()`, `list_nodes()`, `list_attention(limit:)`, `mark_attention_seen(_:)`,
/// `list_delegations()`
///
/// ## Unsupported HubServing methods (throw HTTP 501)
/// Bulk attention clear, all node management, registration, auth / security /
/// passkey ceremonies, grant operations, native authorize.
///
/// ## Additional node-specific methods
/// `sessions_status()`, `list_node_attention(kind:limit:)`,
/// `node_health()`, `validate_bearer(token:)`, `resume_path(session_id:session_number:)`
final class DirectNodeClient: @unchecked Sendable {

    // MARK: - Properties

    /// Base URL of the node (e.g. `http://localhost:8767/direct/`).
    let base_url: URL

    /// Mount path derived from `base_url.path`, normalised (no trailing slash,
    /// empty string for root).  Web session cookie must be scoped to `mount_path + "/"`.
    let mount_path: String

    /// Exact lowercase host from base_url.  Cookie filtering rejects domain cookies.
    let expected_host: String

    /// Scheme + host[:port], omitting default ports.  Sent as Origin on mutations.
    let origin: String

    let is_https: Bool

    let cookie_source: @Sendable () async -> [HTTPCookie]
    let bearer_source: @Sendable () async -> String?

    private let transport: any HubTransport

    /// 401/403 callback — thread-safe and epoch-scoped.
    private let authLock = NSLock()
    private var _authCallback: (@Sendable () async -> Void)?
    private var _authEpoch: UInt64 = 0

    /// Fired as soon as the transport surfaces a 401/403, before body completion.
    var on_unauthorized: (@Sendable () async -> Void)? {
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
    ///   - base_url: Node origin + optional base path.
    ///   - cookie_source: Async closure returning all cookies from the WK store.
    ///     Only `term_llm_web_session` at the exact host + mount path is forwarded.
    ///   - bearer_source: Async closure returning an optional native bearer token
    ///     (e.g. from Keychain).  Injected for POST/PATCH/DELETE and GET /healthz.
    ///   - transport: Injectable transport for testing.  Defaults to
    ///     ``URLSessionHubTransport`` in production.
    init(
        base_url: URL,
        cookie_source: @escaping @Sendable () async -> [HTTPCookie],
        bearer_source: @escaping @Sendable () async -> String?,
        transport: (any HubTransport)? = nil
    ) {
        self.base_url = base_url
        self.cookie_source = cookie_source
        self.bearer_source = bearer_source
        self.is_https = base_url.scheme?.lowercased() == "https"
        self.expected_host = (base_url.host ?? "").lowercased()
        self.transport = transport ?? URLSessionHubTransport()

        // Use percentEncodedPath so mount_path is already percent-encoded and can
        // be safely concatenated with other pre-encoded segments in mounted().
        let raw = URLComponents(url: base_url, resolvingAgainstBaseURL: false)!.percentEncodedPath
        if raw == "/" || raw.isEmpty {
            self.mount_path = ""
        } else {
            self.mount_path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        }

        let defaultPort = base_url.scheme == "http" ? 80 : 443
        let port = base_url.port == defaultPort ? ""
            : base_url.port.map { ":\($0)" } ?? ""
        self.origin = "\(base_url.scheme ?? "https")://\(base_url.host ?? "localhost")\(port)"
    }

    // MARK: - Cookie filtering (term_llm_web_session only)

    /// Filters cookies for a direct node request.
    ///
    /// - **Name**: must be exactly `term_llm_web_session`.
    ///   All `term_llm_hub_*` cookies and other names are excluded.
    /// - **Exact host**: cookie domain must equal `expected_host`; domain cookies rejected.
    /// - **Path**: must equal the auth path (`mount_path + "/"` or `/` for root).
    ///   No root, sibling, or parent path leakage.
    /// - **Secure**: secure cookies only sent over HTTPS.
    /// - **Expiry**: expired cookies dropped.
    func filteredCookies(_ cookies: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        let now = Date()
        let authPath = mount_path.isEmpty ? "/" : mount_path + "/"
        return cookies.filter { cookie in
            guard cookie.name == "term_llm_web_session" else { return false }
            guard cookie.domain.lowercased() == expected_host else { return false }
            let cp = cookie.path.isEmpty ? "/" : cookie.path
            guard cp == authPath else { return false }
            if cookie.isSecure && !is_https { return false }
            if let expires = cookie.expiresDate, expires < now { return false }
            return true
        }
    }

    // MARK: - Session resume path

    /// Compute the browser resume URL for a session.
    ///
    /// Preserves session numbers (`/chat/42`) over opaque IDs (`/chat/<uuid>`).
    func resume_path(session_id: String, session_number: Int64?) -> String {
        let base = "\(mount_path)/chat/"
        if let n = session_number, n > 0 { return "\(base)\(n)" }
        return "\(base)\(session_id)"
    }

    // MARK: - Node-specific public methods

    /// GET /v1/sessions/search — full-text session search on this node.
    func search_sessions(query: String, limit: Int) async throws -> SessionSearchResponse {
        try await request("/v1/sessions/search?\(SessionSearchQuery.percentEncoded(query: query, limit: limit))")
    }

    /// GET /v1/sessions/status — list of sessions with attention and run state.
    func sessions_status() async throws -> DirectNodeSessionsStatus {
        try await request("/v1/sessions/status")
    }

    /// GET /v1/attention?kind=<kind>[&limit=<1…500>] — single-kind attention page.
    ///
    /// `limit` is clamped to `[1, 500]`.  Uses the same bounded 409-retry as
    /// ``list_attention`` (up to 3 attempts) for consistency.
    func list_node_attention(kind: DirectAttentionKind, limit: Int? = nil) async throws -> DirectAttentionPage {
        try await fetchAttentionWithRetry(kind: kind, limit: limit)
    }

    /// GET /healthz with the current bearer token; returns identity fields.
    func node_health() async throws -> DirectNodeHealth {
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
    /// `on_unauthorized` on a failed probe.
    ///
    /// - Throws: ``HubAPIError`` on non-2xx or on 200 without identity markers.
    func validate_bearer(token: String) async throws -> DirectNodeHealth {
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
        let cookies = filteredCookies(await cookie_source(), for: url)
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) {
            req.setValue(v, forHTTPHeaderField: k)
        }

        // Bearer (always for healthz — identity requires auth)
        if let t = await bearer_source() {
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
        var components = URLComponents(url: base_url, resolvingAgainstBaseURL: false)!
        // percentEncodedPath: mount_path is already percent-encoded (derived from
        // base_url.percentEncodedPath), and pathPart may contain pre-encoded segments
        // like %2F in session IDs.  Using the plain .path setter would re-encode %
        // as %25 (double-encoding); .percentEncodedPath leaves existing escapes intact.
        components.percentEncodedPath = "\(mount_path)\(pathPart)"
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
        let cookies = filteredCookies(await cookie_source(), for: url)
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // Bearer on ALL native requests (GET + mutations)
        if let t = await bearer_source() {
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
            short_title: entry.short_title,
            long_title: entry.long_title,
            pinned: entry.pinned,
            active_run: entry.active_run,
            interaction_required: entry.interaction_required,
            pending_interaction_count: entry.pending_interaction_count,
            pending_interaction_kinds: entry.pending_interaction_kinds,
            last_message_at: entry.last_message_at.map(Int.init),
            message_count: entry.message_count,
            resume_path: resume_path(
                session_id: entry.id,
                session_number: entry.number
            )
        )
    }

    private func inboxItem(
        from item: DirectAttentionItem,
        storeInstanceID: String
    ) -> HubAttentionInboxItem {
        HubAttentionInboxItem(
            node_id: "direct-node",
            node_name: "direct-node",
            session_id: item.session_id,
            store_instance_id: storeInstanceID,
            session_number: item.session_number.map(Int.init),
            title: item.short_title ?? "",
            outcome: item.outcome ?? item.lifecycle_state ?? "",
            terminal_at: item.terminal_at,
            attention_seq: Int(item.attention_seq ?? 0),
            resume_path: resume_path(
                session_id: item.session_id,
                session_number: item.session_number
            )
        )
    }

    private func inputRequiredItem(from item: DirectAttentionItem) -> HubInputRequiredItem {
        HubInputRequiredItem(
            node_id: "direct-node",
            node_name: "direct-node",
            session_id: item.session_id,
            session_number: item.session_number.map(Int.init),
            title: item.short_title ?? "",
            pending_interaction_count: item.pending_interaction_count ?? 0,
            pending_interaction_kinds: item.pending_interaction_kinds,
            required_since: item.interaction_required_since,
            resume_path: resume_path(
                session_id: item.session_id,
                session_number: item.session_number
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
    /// does **not** fail the call — it only means `agent` falls back to
    /// `"direct-node"`.  The node ID is the stable sentinel `"direct-node"`.
    /// Sessions are split into `active` (running or input-required) and `recent`.
    func list_nodes() async throws -> NodesResponse {
        // Concurrent: sessions/status (required) + healthz identity (best-effort)
        async let statusTask = sessions_status()
        async let healthTask = fetchHealthAuthenticated(useCallback: false)

        let status = try await statusTask
        let health = try? await healthTask

        let entries = status.sessions
        let agentName = health?.agent ?? "direct-node"

        let activeSessions = entries.filter { $0.active_run == true || $0.interaction_required == true }
        let recentSessions = entries.filter { $0.active_run != true && $0.interaction_required != true }

        let activeCount  = activeSessions.count
        let inputCount   = entries.filter { $0.interaction_required == true }.count
        let unseenCount  = entries.filter { $0.attention_unseen == true }.count

        let nodeSessions = HubNodeSessions(
            count_label: "\(entries.count)",
            has_more: false,
            active_count: activeCount,
            input_required_count: inputCount,
            unseen_count: unseenCount,
            attention_capability: nil,
            attention_last_success_at: nil,
            active: activeSessions.isEmpty ? nil : activeSessions.map { nodeSession(from: $0) },
            recent: recentSessions.isEmpty ? nil : recentSessions.map { nodeSession(from: $0) },
            resume_path: mount_path.isEmpty ? "/" : mount_path + "/"
        )

        let nodeStatus = HubNodeStatus(
            reachable: true,
            state: "ok",
            latency_ms: 0,
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
            url: base_url.absoluteString,
            base_path: mount_path.isEmpty ? "/" : mount_path + "/",
            proxy_path: mount_path.isEmpty ? "/" : mount_path + "/",
            new_session_path: mount_path.isEmpty ? "/?new=1" : "\(mount_path)/?new=1",
            has_token: false,
            status: nodeStatus,
            sessions: nodeSessions,
            diagnostics: nil
        )

        return NodesResponse(nodes: [node], resolver_error: nil)
    }

    func test_node(_ form: NodeFormData) async throws -> TestNodeResponse {
        throw HubAPIError(status: 501, message: "Node management is unavailable on a direct connection.")
    }

    func add_node(_ form: NodeFormData) async throws -> AddNodeResponse {
        throw HubAPIError(status: 501, message: "Node management is unavailable on a direct connection.")
    }

    func remove_node(id: String) async throws -> RemovedNodeResponse {
        throw HubAPIError(status: 501, message: "Node management is unavailable on a direct connection.")
    }

    func reorder_nodes(node_ids: [String]) async throws -> NodeOrderResponse {
        throw HubAPIError(status: 501, message: "Node management is unavailable on a direct connection.")
    }

    // MARK: Attention

    /// Fetches unseen + input_required + running attention items concurrently.
    ///
    /// All three kind requests run in parallel, each with bounded 409 retry
    /// (up to 3 attempts).  A failure on the running kind produces
    /// `total_running = 0` without failing the overall call.
    ///
    /// `limit` is clamped to `[1, 500]`.
    func list_attention(limit: Int? = nil) async throws -> AttentionResponse {
        let clamped = limit.map { min(max($0, 1), 500) }

        // Concurrent: unseen inbox + input_required list + running count
        async let unseenTask   = fetchAttentionWithRetry(kind: .unseen, limit: clamped)
        async let inputTask    = fetchAttentionWithRetry(kind: .input_required, limit: clamped)
        async let runningTask  = fetchAttentionWithRetry(kind: .running, limit: clamped)

        let unseenPage   = try await unseenTask
        let inputPage    = try await inputTask
        // Running: best-effort — failure → count 0
        let runningPage  = try? await runningTask
        let runningCount = runningPage?.items.count ?? 0

        let inbox = unseenPage.items.map {
            inboxItem(from: $0, storeInstanceID: unseenPage.store_instance_id)
        }
        let inputRequired = inputPage.items.map { inputRequiredItem(from: $0) }

        let attentionNode = HubAttentionNode(
            node_id: "direct-node",
            node_name: "direct-node",
            capability_state: "ok",
            stale: false,
            last_success_at: nil,
            last_error: nil,
            running_count: runningCount,
            input_required_count: inputPage.items.count,
            unseen_count: unseenPage.items.count,
            has_green_indicator: runningCount == 0 && inputPage.items.isEmpty
                && unseenPage.items.isEmpty && !unseenPage.has_more
        )

        return AttentionResponse(
            total_running: runningCount,
            total_input_required: inputPage.items.count,
            total_unseen: unseenPage.items.count,
            nodes: [attentionNode],
            input_required: inputRequired,
            inbox: inbox,
            has_more: unseenPage.has_more || inputPage.has_more
        )
    }

    /// No bulk-clear endpoint on a direct node.
    func clear_attention() async throws -> ClearAttentionResponse {
        throw HubAPIError(status: 501, message: "Bulk attention clear is unavailable on a direct connection.")
    }

    /// POST /v1/sessions/{session_id}/attention/seen
    ///
    /// Body: `{store_instance_id, through_seq}`.
    /// Header: `X-Term-LLM-Attention-Source: phone`.
    ///
    /// - Throws: ``HubAPIError(status: 409, …)`` on snapshot conflict — caller
    ///   should reconcile authoritative session state and bounded-retry.
    func mark_attention_seen(_ item: AttentionSeenRequest) async throws -> SeenAttentionResponse {
        guard !item.session_id.isEmpty, item.session_id != ".", item.session_id != ".." else {
            throw HubAPIError(status: 0, message: "Invalid session identifier for attention acknowledgement.")
        }
        struct SeenBody: Encodable {
            let store_instance_id: String
            let through_seq: Int
        }
        let seenBody = SeenBody(
            store_instance_id: item.store_instance_id,
            through_seq: item.attention_seq
        )
        let path = "/v1/sessions/\(item.session_id.directNodePathEncoded)/attention/seen"
        _ = try await executeRequest(
            path, method: .POST, body: seenBody,
            extraHeaders: ["X-Term-LLM-Attention-Source": "phone"]
        )
        return SeenAttentionResponse(cleared: 1)
    }

    // MARK: Delegations

    /// Returns an empty list — a direct node has no hub delegation graph.
    func list_delegations() async throws -> DelegationsResponse {
        DelegationsResponse(delegations: [])
    }

    // MARK: Registration — unsupported

    func registration_info() async throws -> RegistrationInfoResponse {
        throw HubAPIError(status: 501, message: "Registration is unavailable on a direct connection.")
    }

    // MARK: Auth / Session / Security — unsupported

    func session() async throws -> HubSessionResponse {
        throw HubAPIError(status: 501, message: "Session management is unavailable on a direct connection.")
    }

    func list_credentials() async throws -> CredentialsResponse {
        throw HubAPIError(status: 501, message: "Credential management is unavailable on a direct connection.")
    }

    func rename_credential(record_id: String, display_name: String) async throws -> HubCredential {
        throw HubAPIError(status: 501, message: "Credential management is unavailable on a direct connection.")
    }

    func remove_credential(record_id: String) async throws -> OkResponse {
        throw HubAPIError(status: 501, message: "Credential management is unavailable on a direct connection.")
    }

    func revoke_other_sessions() async throws -> RevokeSessionsResponse {
        throw HubAPIError(status: 501, message: "Session management is unavailable on a direct connection.")
    }

    func logout() async throws -> RedirectResponse {
        throw HubAPIError(status: 501, message: "Logout is unavailable on a direct connection.")
    }

    // MARK: Passkey ceremonies — unsupported

    func begin_login(return_path: String) async throws -> Data {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func finish_login(credential: Data) async throws -> RedirectResponse {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func begin_reauthentication() async throws -> Data {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func finish_reauthentication(credential: Data) async throws -> OkResponse {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func begin_additional_registration(display_name: String) async throws -> Data {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    func finish_additional_registration(credential: Data) async throws -> HubCredential {
        throw HubAPIError(status: 501, message: "Passkey authentication is unavailable on a direct connection.")
    }

    // MARK: Grant registration — unsupported

    func verify_grant(prefix: GrantPrefix, code: String) async throws -> OkResponse {
        throw HubAPIError(status: 501, message: "Grant registration is unavailable on a direct connection.")
    }

    func begin_grant_registration(prefix: GrantPrefix, display_name: String) async throws -> Data {
        throw HubAPIError(status: 501, message: "Grant registration is unavailable on a direct connection.")
    }

    func finish_grant_registration(
        prefix: GrantPrefix, credential: Data, return_path: String
    ) async throws -> RedirectResponse {
        throw HubAPIError(status: 501, message: "Grant registration is unavailable on a direct connection.")
    }

    // MARK: Native authorize — unsupported

    func authorize_native(challenge: String) async throws -> RedirectResponse {
        throw HubAPIError(status: 501, message: "Native authorize is unavailable on a direct connection.")
    }

    // MARK: Health

    /// GET /healthz with the current bearer token (injected for identity disclosure).
    ///
    /// Returns the protocol ``HealthResponse``; call ``node_health()`` for the
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
    func search_sessions(node_id: String, query: String, limit: Int) async throws -> SessionSearchResponse {
        try await search_sessions(query: query, limit: limit)
    }

    func sessions_status(node_id: String, ids: [String]) async throws -> DirectNodeSessionsStatus {
        guard let query = SessionSearchQuery.percentEncodedStatus(ids: ids) else { return DirectNodeSessionsStatus(sessions: []) }
        return try await request("/v1/sessions/status?\(query)")
    }
}
