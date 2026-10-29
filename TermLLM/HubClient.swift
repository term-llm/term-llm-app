import Foundation

// MARK: - Error

struct HubAPIError: Error, Equatable, Sendable, LocalizedError {
    let status: Int
    let message: String
    let type: String

    init(status: Int, message: String, type: String = "") {
        self.status = status
        self.message = message
        self.type = type
    }

    var errorDescription: String? { message }
}

// MARK: - Grant prefix

enum GrantPrefix: String, Sendable {
    case bootstrap = "/api/auth/bootstrap"
    case recovery = "/api/auth/recovery"
}

// MARK: - Auth discovery

/// Hub page configuration extracted from the HTML `#root` element's
/// `data-hub-config` attribute.  Field names are camelCase matching the
/// server-emitted JSON.
struct HubPageConfiguration: Codable, Sendable, Equatable {
    let page: String            // dashboard | passkey-auth | bearer-login | security
    let authMode: String        // none | bearer | passkey
    let basePath: String
    let canAddNodes: Bool
    let passkeyAuth: Bool
    let invalidToken: Bool?
    let formAction: String?
    let cacheScope: String?
    let cacheDisplayAllowed: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = try c.decode(String.self, forKey: .page)
        authMode = try c.decode(String.self, forKey: .authMode)
        basePath = try c.decodeIfPresent(String.self, forKey: .basePath) ?? ""
        canAddNodes = try c.decodeIfPresent(Bool.self, forKey: .canAddNodes) ?? false
        passkeyAuth = try c.decodeIfPresent(Bool.self, forKey: .passkeyAuth) ?? false
        invalidToken = try c.decodeIfPresent(Bool.self, forKey: .invalidToken)
        formAction = try c.decodeIfPresent(String.self, forKey: .formAction)
        cacheScope = try c.decodeIfPresent(String.self, forKey: .cacheScope)
        cacheDisplayAllowed = try c.decodeIfPresent(Bool.self, forKey: .cacheDisplayAllowed)
    }

    /// Memberwise init for tests and internal construction.
    init(page: String, authMode: String, basePath: String = "",
         canAddNodes: Bool = false, passkeyAuth: Bool = false,
         invalidToken: Bool? = nil, formAction: String? = nil,
         cacheScope: String? = nil, cacheDisplayAllowed: Bool? = nil) {
        self.page = page; self.authMode = authMode; self.basePath = basePath
        self.canAddNodes = canAddNodes; self.passkeyAuth = passkeyAuth
        self.invalidToken = invalidToken; self.formAction = formAction
        self.cacheScope = cacheScope; self.cacheDisplayAllowed = cacheDisplayAllowed
    }
}

/// Result of fetching the Hub root when the server responds with a redirect
/// instead of an HTML page (e.g. passkey 302 → login URL).
struct HubRootRedirect: Sendable, Equatable {
    let status: Int
    let login_url: String?      // from X-Term-LLM-Login-URL header
    let location: String?       // from Location header
}

/// What ``HubClient/discover()`` returns.
enum HubDiscoveryResult: Sendable {
    case page(HubPageConfiguration)
    case redirect(HubRootRedirect)
}

// MARK: - Protocol

/// Typed Hub API surface for store injection.  Every method throws
/// ``HubAPIError`` on non-2xx responses.  Passkey ceremony begin/finish
/// traffic raw `Data` so the caller owns WebAuthn JSON encoding; the
/// transport never interprets it.
///
/// Concrete-only methods (on ``HubClient`` but **not** here) keep mock
/// burden small: ``discover()``, ``login_bearer(token:)``,
/// ``clear_local_auth()``, ``page_configuration()``.
protocol HubServing: Sendable {
    // Nodes
    func list_nodes() async throws -> NodesResponse
    func test_node(_ form: NodeFormData) async throws -> TestNodeResponse
    func add_node(_ form: NodeFormData) async throws -> AddNodeResponse
    func remove_node(id: String) async throws -> RemovedNodeResponse
    func reorder_nodes(node_ids: [String]) async throws -> NodeOrderResponse

    // Attention (limit: 1…500, server default when nil)
    func list_attention(limit: Int?) async throws -> AttentionResponse
    func clear_attention() async throws -> ClearAttentionResponse
    func mark_attention_seen(_ item: AttentionSeenRequest) async throws -> SeenAttentionResponse

    // Delegations (read-only)
    func list_delegations() async throws -> DelegationsResponse

    // Registration
    func registration_info() async throws -> RegistrationInfoResponse

    // Auth / Session / Security
    func session() async throws -> HubSessionResponse
    func list_credentials() async throws -> CredentialsResponse
    func rename_credential(record_id: String, display_name: String) async throws -> HubCredential
    func remove_credential(record_id: String) async throws -> OkResponse
    func revoke_other_sessions() async throws -> RevokeSessionsResponse
    func logout() async throws -> RedirectResponse

    // Passkey ceremonies – raw JSON Data, caller owns WebAuthn
    func begin_login(return_path: String) async throws -> Data
    func finish_login(credential: Data) async throws -> RedirectResponse
    func begin_reauthentication() async throws -> Data
    func finish_reauthentication(credential: Data) async throws -> OkResponse
    func begin_additional_registration(display_name: String) async throws -> Data
    func finish_additional_registration(credential: Data) async throws -> HubCredential

    // Grant registration (bootstrap / recovery)
    func verify_grant(prefix: GrantPrefix, code: String) async throws -> OkResponse
    func begin_grant_registration(prefix: GrantPrefix, display_name: String) async throws -> Data
    func finish_grant_registration(prefix: GrantPrefix, credential: Data, return_path: String) async throws -> RedirectResponse

    // Native authorize
    func authorize_native(challenge: String) async throws -> RedirectResponse

    // Health
    func healthz() async throws -> HealthResponse

    // Change feed long-poll (GET /api/changes). Optional: the default throws
    // ``HubChangesUnsupported`` so callers fall back to plain polling.
    func wait_for_changes(since: UInt64?, timeout: Int) async throws -> HubChangesResponse
}

struct HubChangesUnsupported: Error {}

extension HubServing {
    func wait_for_changes(since: UInt64?, timeout: Int) async throws -> HubChangesResponse {
        throw HubChangesUnsupported()
    }
}

// MARK: - Request / Response Models

struct HubChangesResponse: Codable, Sendable, Equatable {
    let version: UInt64
}

struct NodesResponse: Codable, Sendable, Equatable {
    let nodes: [HubNode]
    let resolver_error: String?
}

struct NodeOrderResponse: Codable, Sendable, Equatable {
    let node_ids: [String]
}

struct TestNodeResponse: Codable, Sendable, Equatable {
    let status: HubNodeStatus
}

struct AddNodeResponse: Codable, Sendable, Equatable {
    let id: String
    let warning: String?
}

struct RemovedNodeResponse: Codable, Sendable, Equatable {
    let removed: String
}

struct NodeFormData: Codable, Sendable, Equatable {
    let name: String
    let url: String
    let token: String
}

// MARK: Attention

struct AttentionResponse: Codable, Sendable, Equatable {
    let total_running: Int
    let total_input_required: Int
    let total_unseen: Int
    let nodes: [HubAttentionNode]
    let input_required: [HubInputRequiredItem]
    let inbox: [HubAttentionInboxItem]
    let has_more: Bool
}

struct ClearAttentionResponse: Codable, Sendable, Equatable {
    let cleared: Int
    let failed: Int
}

struct SeenAttentionResponse: Codable, Sendable, Equatable {
    let cleared: Int
}

struct AttentionSeenRequest: Codable, Sendable, Equatable {
    let store_instance_id: String
    let session_id: String
    let attention_seq: Int
}

struct HubAttentionNode: Codable, Sendable, Equatable {
    let node_id: String
    let node_name: String
    let capability_state: String
    let stale: Bool
    let last_success_at: String?
    let last_error: String?
    let running_count: Int
    let input_required_count: Int
    let unseen_count: Int
    let has_green_indicator: Bool
}

struct HubAttentionInboxItem: Codable, Sendable, Equatable {
    let node_id: String
    let node_name: String
    let session_id: String
    let store_instance_id: String?
    let session_number: Int?
    let title: String
    let outcome: String
    let terminal_at: String?
    let attention_seq: Int
    let resume_path: String
}

struct HubInputRequiredItem: Codable, Sendable, Equatable {
    let node_id: String
    let node_name: String
    let session_id: String
    let session_number: Int?
    let title: String
    let pending_interaction_count: Int
    let pending_interaction_kinds: [String]?
    let required_since: String?
    let resume_path: String
    let stale: Bool?
}

// MARK: Delegations

struct DelegationsResponse: Codable, Sendable, Equatable {
    let delegations: [HubDelegation]
}

struct HubDelegation: Codable, Sendable, Equatable {
    let id: String
    let origin_node: String
    let target_node: String
    let agent_name: String?
    let prompt: String?
    let model: String?
    let cwd: String?
    let job_id: String?
    let run_id: String?
    let status: String
    let depth: Int
    let chain: [String]?
    let parent_delegation_id: String?
    let response: String?
    let error: String?
    let created_at: String
    let updated_at: String
}

// MARK: Registration

struct RegistrationInfoResponse: Codable, Sendable, Equatable {
    let enabled: Bool
    let token_configured: Bool?
    let can_persist_nodes: Bool?
    let registration_token: String?
}

// MARK: Auth / Session / Security

struct HubSessionResponse: Codable, Sendable, Equatable {
    let administrator: String
    let session: [String: JSONValue]
    let recently_authenticated: Bool
    let active_sessions: Int
}

struct CredentialsResponse: Codable, Sendable, Equatable {
    let credentials: [HubCredential]
}

struct HubCredential: Codable, Sendable, Equatable {
    let record_id: String
    let display_name: String
    let transports: [String]?
    let created_at: String
    let last_used_at: String
}

struct RevokeSessionsResponse: Codable, Sendable, Equatable {
    let revoked: Int
}

struct RedirectResponse: Codable, Sendable, Equatable {
    let ok: Bool?
    let redirect: String
}

struct OkResponse: Codable, Sendable, Equatable {
    let ok: Bool
}

struct HealthResponse: Codable, Sendable, Equatable {
    let status: String
}

// MARK: Node sub-models

struct HubNode: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let source: String
    let connection: String
    let url: String
    let base_path: String
    let proxy_path: String
    let new_session_path: String
    let has_token: Bool
    let status: HubNodeStatus
    let sessions: HubNodeSessions?
    let diagnostics: [HubNodeDiagnostic]?
}

struct HubNodeStatus: Codable, Sendable, Equatable {
    let reachable: Bool
    let state: String
    let latency_ms: Int
    let version: String?
    let agent: String?
    let capabilities: [String]?
    let details: [String: String]?
    let error: String?
}

struct HubNodeSessions: Codable, Sendable, Equatable {
    let count_label: String
    let has_more: Bool?
    let active_count: Int?
    let input_required_count: Int?
    let unseen_count: Int?
    let attention_capability: String?
    let attention_last_success_at: Int?
    let active: [HubNodeSession]?
    let recent: [HubNodeSession]?
    let resume_path: String?
}

struct HubNodeSession: Codable, Sendable, Equatable {
    let id: String
    let number: Int?
    let short_title: String
    let long_title: String?
    let pinned: Bool?
    let active_run: Bool?
    let interaction_required: Bool?
    let pending_interaction_count: Int?
    let pending_interaction_kinds: [String]?
    let last_message_at: Int?
    let message_count: Int?
    let resume_path: String
}

/// One match from a node's `GET /v1/sessions/search` (full-text over message
/// text, relevance ordered, one best hit per session). Timestamps are unix ms.
/// Search only finds sessions; run/input state comes from a status lookup.
struct SessionSearchEntry: Codable, Sendable, Equatable {
    let id: String
    let number: Int64?
    let short_title: String?
    let long_title: String?
    let pinned: Bool?
    let last_message_at: Int64?
    let message_count: Int?
    let snippet: String?
    let attention_unseen: Bool?
}

struct SessionSearchResponse: Codable, Sendable, Equatable {
    let sessions: [SessionSearchEntry]
}

/// Per-agent session search. Hubs proxy to each node; a Direct Node answers
/// for itself and ignores `node_id`.
protocol HubSessionSearching: Sendable {
    func search_sessions(node_id: String, query: String, limit: Int) async throws -> SessionSearchResponse
    /// `GET /v1/sessions/status?ids=…`: current run/input state for exactly
    /// these sessions. Older nodes ignore `ids`; callers match by ID.
    func sessions_status(node_id: String, ids: [String]) async throws -> DirectNodeSessionsStatus
}

enum SessionSearchQuery {
    static let maximumLimit = 50
    /// Strict encoding: `+`, `&`, `=` and `%` in user text must not alter the
    /// server's query parsing.
    static func percentEncoded(query: String, limit: Int) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "q=\(q)&limit=\(min(max(limit, 1), maximumLimit))"
    }

    static let maximumStatusIDs = 100
    /// IDs are joined with commas, so an ID containing one is not requested.
    static func percentEncodedStatus(ids: [String]) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = ids.filter { !$0.isEmpty && !$0.contains(",") }.prefix(maximumStatusIDs)
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        return encoded.isEmpty ? nil : "ids=" + encoded.joined(separator: ",")
    }

    /// Node IDs are untrusted path segments; mirror the chat-route charset.
    static func isSafeNodeID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." &&
            id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
}

struct HubNodeDiagnostic: Codable, Sendable, Equatable {
    let severity: String
    let code: String
    let message: String
}

// MARK: - Transport

// MARK: - Injectable transport

/// Minimal transport abstraction so tests can inject a mock without
/// URLProtocol (which cannot reliably exercise URLSessionDataDelegate
/// header callbacks).  Production uses ``URLSessionHubTransport``.
protocol HubTransport: Sendable {
    /// Execute a request and return (data, response).  The transport is
    /// responsible for blocking redirects and invoking the unauthorized
    /// callback as soon as the SDK exposes a 401/403, before body completion.
    /// Bare wire headers may not be exposed until a body byte arrives.
    func execute(
        _ request: URLRequest,
        onUnauthorized: (@Sendable () async -> Void)?
    ) async throws -> (Data, HTTPURLResponse)
}

/// Production transport owns the callback-based data task. Completion-handler
/// tasks and the async data/bytes convenience APIs can buffer 401 bodies before
/// exposing the response; neither is used here.
struct URLSessionHubTransport: HubTransport {
    static let maximumResponseBytes = 8 * 1024 * 1024

    /// Optional non-sensitive callback diagnostics. Never contains URLs,
    /// headers, credentials, response contents, realms, or hostnames.
    enum Event: Sendable {
        case response(Int)
        case challenge(status: Int?)
        case data(Int)
        case completed(errorCode: Int?)
    }
    var observe: (@Sendable (Event) -> Void)? = nil

    static func processHeaders(_ response: HTTPURLResponse,
                               onUnauthorized: (@Sendable () async -> Void)?) async {
        if response.statusCode == 401 || response.statusCode == 403 {
            await onUnauthorized?()
        }
    }

    func execute(
        _ request: URLRequest,
        onUnauthorized: (@Sendable () async -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        let transfer = Transfer(onUnauthorized: onUnauthorized, observe: observe)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request, continuation: continuation)
            }
        }, onCancel: {
            transfer.cancel()
        })
    }

    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let onUnauthorized: (@Sendable () async -> Void)?
        private let observe: (@Sendable (Event) -> Void)?
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var task: URLSessionDataTask?
        private var response: HTTPURLResponse?
        private var body = Data()
        private var finished = false
        private var purgeTask: Task<Void, Never>?

        init(onUnauthorized: (@Sendable () async -> Void)?, observe: (@Sendable (Event) -> Void)?) {
            self.onUnauthorized = onUnauthorized
            self.observe = observe
            super.init()
        }

        func start(_ request: URLRequest,
                   continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            // Deliberately NO completion handler: this per-task delegate owns
            // response, data and terminal delivery, including incomplete HTTP
            // bodies. The session is shared so connections are reused.
            let task = HubClient.sharedSession.dataTask(with: request)
            task.delegate = self
            self.task = task
            lock.unlock()
            task.resume()
        }

        func cancel() { finish(.failure(CancellationError())) }

        private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            let task = self.task
            self.continuation = nil
            self.task = nil
            lock.unlock()
            task?.cancel()
            continuation?.resume(with: result)
        }

        /// Response delivery and HTTP-auth challenges may both expose the
        /// same 401. Join one purge task so neither path can overtake it or
        /// fire the scoped callback twice.
        private func authorizationTask(for response: HTTPURLResponse) -> Task<Void, Never>? {
            guard response.statusCode == 401 || response.statusCode == 403 else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return nil }
            if let purgeTask { return purgeTask }
            let callback = onUnauthorized
            let purge = Task { await URLSessionHubTransport.processHeaders(response, onUnauthorized: callback) }
            purgeTask = purge
            return purge
        }

        private func prepareResponse(_ http: HTTPURLResponse) -> URLSession.ResponseDisposition {
            lock.lock()
            guard !finished else { lock.unlock(); return .cancel }
            guard http.expectedContentLength <= Int64(URLSessionHubTransport.maximumResponseBytes) else {
                lock.unlock()
                finish(.failure(Self.tooLarge(http.statusCode)))
                return .cancel
            }
            response = http
            body.reserveCapacity(Int(max(0, http.expectedContentLength)))
            lock.unlock()
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(HubAPIError(status: 0, message: "Hub returned a non-HTTP response.")))
                completionHandler(.cancel)
                return
            }
            observe?(.response(http.statusCode))
            let purge = authorizationTask(for: http)
            Task {
                await purge?.value
                completionHandler(self.prepareResponse(http))
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            observe?(.data(data.count))
            lock.lock()
            guard !finished else { lock.unlock(); return }
            guard data.count <= URLSessionHubTransport.maximumResponseBytes - body.count else {
                let status = response?.statusCode ?? 0
                lock.unlock()
                finish(.failure(Self.tooLarge(status)))
                return
            }
            body.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            observe?(.completed(errorCode: error.map { ($0 as NSError).code }))
            if let error { finish(.failure(error)); return }
            lock.lock()
            let response = self.response
            let data = body
            lock.unlock()
            if let response { finish(.success((data, response))) }
            else { finish(.failure(HubAPIError(status: 0, message: "Hub completed without an HTTP response."))) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let http = challenge.failureResponse as? HTTPURLResponse
            observe?(.challenge(status: http?.statusCode))
            // Some SDK auth paths expose the 401 as a challenge before a data
            // response. Revoke from those headers too, without trusting any
            // supplied credential or altering TLS/server-trust policy.
            let purge = http.flatMap { authorizationTask(for: $0) }
            Task {
                await purge?.value
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        private static func tooLarge(_ status: Int) -> HubAPIError {
            HubAPIError(status: status, message: "Hub response exceeds the 8 MiB safety limit.")
        }
    }
}

/// Ephemeral HTTP transport for the Hub browser-facing API.
///
/// ## Security invariants
///
/// | Concern | Mechanism |
/// |---|---|
/// | Cookie source | Caller-supplied async closure; transport filters to **exact** host (no broad domain), mount-path boundary, Secure flag (HTTPS only), and unexpired |
/// | Cookie jar | `URLSessionConfiguration.ephemeral`, `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`, `httpCookieStorage = nil`, `urlCredentialStorage = nil` |
/// | Redirects | Blocked via `URLSessionTaskDelegate` returning `nil` |
/// | Origin | Set on every mutation (POST / PATCH / DELETE) |
/// | 401/403 purge | Revoke as soon as the SDK exposes the response, before body completion; bare wire headers may remain buffered |
/// | Response cookies | `Set-Cookie` headers are parsed, filtered to hub auth scope, and sunk to WK via `cookie_sink` — no ambient jar |
/// | Timeout | Bounded at 30 s per request |
/// | Cookie scope | Auth cookies restricted to exact host + configured mount path; no sibling-root leakage, no `/foo` matching `/foobar` |
/// | Passkey ceremonies | begin/finish return/accept raw `Data`; caller owns WebAuthn |
/// | Bearer login | Validates via `Authorization` header; constructs scoped HTTPOnly cookie; sinks to WK |
///
/// ## Limitations
///
/// On the tested SDK, headers alone for 200/403/401 are not exposed; the first
/// body byte makes the response visible. Bare-header stalls can therefore wait
/// until the network timeout. This is not instant wire-header revocation.
///
/// Reauthentication requires WebAuthn which this transport cannot perform.
/// Callers must present the browser for passkey ceremonies.
final class HubClient: @unchecked Sendable {

    /// Base URL of the Hub (e.g. `https://hub.example.com/ui/`).
    let base_url: URL

    /// Mount path derived from `base_url.path`, normalized (no trailing slash,
    /// empty string for root).  Auth cookies are scoped to `mount_path + "/"`.
    let mount_path: String

    /// Exact lowercase host from base_url.  Cookie filtering rejects domain
    /// cookies that don't match exactly.
    let expected_host: String

    let cookie_source: @Sendable () async -> [HTTPCookie]
    let cookie_sink: @Sendable ([HTTPCookie]) async -> Void
    let origin: String
    let is_https: Bool
    private let transport: any HubTransport

    /// Fired as soon as the SDK exposes a 401/403, before waiting for body
    /// completion. A zero-byte body can delay SDK exposure until timeout;
    /// no callback can revoke from wire headers the SDK has not surfaced.
    private let authorizationCallbackLock = NSLock()
    private var authorizationCallback: (@Sendable () async -> Void)?
    private var authorizationEpoch: UInt64 = 0
    var on_unauthorized: (@Sendable () async -> Void)? {
        get {
            authorizationCallbackLock.lock()
            defer { authorizationCallbackLock.unlock() }
            return authorizationCallback
        }
        set {
            authorizationCallbackLock.lock()
            authorizationCallback = newValue
            authorizationEpoch &+= 1
            authorizationCallbackLock.unlock()
        }
    }

    /// Installed by the source owner as one immutable auth-generation closure.
    /// The request snapshot carries it across response delivery and actor hops.
    typealias CookieImporter = @Sendable ([HTTPCookie], @escaping @Sendable () -> Bool) async throws -> Void
    private var cookieImporter: CookieImporter?
    var scoped_cookie_importer: CookieImporter? {
        get { authorizationCallbackLock.lock(); defer { authorizationCallbackLock.unlock() }; return cookieImporter }
        set {
            authorizationCallbackLock.lock()
            cookieImporter = newValue
            authorizationEpoch &+= 1
            authorizationCallbackLock.unlock()
        }
    }
    private struct Authorization {
        let epoch: UInt64
        let callback: (@Sendable () async -> Void)?
        let importer: CookieImporter?
    }
    private func captureAuthorization() -> Authorization {
        authorizationCallbackLock.lock()
        let epoch = authorizationEpoch
        let callback = authorizationCallback
        let importer = cookieImporter
        authorizationCallbackLock.unlock()
        let guarded: (@Sendable () async -> Void)?
        if let callback {
            guarded = { @Sendable [weak self] in
                guard self?.authorizationIsCurrent(epoch) == true else { return }
                await callback()
            }
        } else { guarded = nil }
        return Authorization(epoch: epoch, callback: guarded, importer: importer)
    }
    private func importCookies(_ cookies: [HTTPCookie], authorization: Authorization) async throws {
        let isCurrent: @Sendable () -> Bool = { [weak self] in self?.authorizationIsCurrent(authorization.epoch) == true }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        if let importer = authorization.importer { try await importer(cookies, isCurrent) }
        else { await cookie_sink(cookies) }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
    }

    private func authorizationIsCurrent(_ epoch: UInt64) -> Bool {
        authorizationCallbackLock.lock()
        defer { authorizationCallbackLock.unlock() }
        return authorizationEpoch == epoch
    }

    /// Default request timeout in seconds.
    static let defaultTimeout: TimeInterval = 30

    /// - Parameters:
    ///   - base_url: Hub origin + optional base path.
    ///   - cookie_source: Async closure returning all cookies (typically from
    ///     `WKWebsiteDataStore`).  The transport filters them strictly.
    ///   - cookie_sink: Async closure to persist cookies into WK.
    ///   - transport: Injectable transport for testing.  Defaults to
    ///     ``URLSessionHubTransport`` in production.
    init(
        base_url: URL,
        cookie_source: @escaping @Sendable () async -> [HTTPCookie],
        cookie_sink: @escaping @Sendable ([HTTPCookie]) async -> Void = { _ in },
        transport: (any HubTransport)? = nil
    ) {
        self.base_url = base_url
        self.cookie_source = cookie_source
        self.cookie_sink = cookie_sink
        self.is_https = base_url.scheme?.lowercased() == "https"
        self.expected_host = (base_url.host ?? "").lowercased()
        self.transport = transport ?? URLSessionHubTransport()

        // mount_path: "/ui" from "https://hub.example.com/ui/", "" for root
        let raw = base_url.path
        if raw == "/" || raw.isEmpty {
            self.mount_path = ""
        } else {
            self.mount_path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        }

        // Origin = scheme://host[:port]  (omit default ports)
        let defaultPort = base_url.scheme == "http" ? 80 : 443
        let port = base_url.port == defaultPort ? "" : base_url.port.map { ":\($0)" } ?? ""
        self.origin = "\(base_url.scheme ?? "https")://\(base_url.host ?? "localhost")\(port)"
    }

    // MARK: - Concrete-only methods (not on HubServing)

    /// Fetch the Hub root and extract the page configuration.
    ///
    /// - On 200 with parseable `data-hub-config`: returns `.page(…)`.
    /// - On 401 with an HTML body containing `data-hub-config` (bearer login
    ///   page): returns `.page(…)` after firing `on_unauthorized`.
    /// - On 3xx (blocked redirect) or 401 without parseable HTML: returns
    ///   `.redirect(…)` with header metadata.
    ///
    /// Throws ``HubAPIError`` for other non-2xx or unparseable responses.
    func discover() async throws -> HubDiscoveryResult {
        // Snapshot the current auth epoch's callback before any suspension.
        // A later sign-in replaces it; an old request must not revoke new auth.
        let authorization = captureAuthorization()
        let url = mounted("/")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = Self.defaultTimeout

        let cookies = filteredCookies(await cookie_source(), for: url)
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in cookieHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        guard authorizationIsCurrent(authorization.epoch), !Task.isCancelled else { throw CancellationError() }
        // Purge when the SDK exposes the response, even if the rest of the
        // login page body stalls. Bare headers may remain SDK-buffered.
        let (data, http) = try await transport.execute(request, onUnauthorized: authorization.callback)

        // Process response Set-Cookie through scoped sink
        if authorizationIsCurrent(authorization.epoch) {
            try await sinkResponseCookies(from: http, for: url, authorization: authorization)
        }

        // 3xx: blocked redirect
        if (300...399).contains(http.statusCode) {
            return .redirect(HubRootRedirect(
                status: http.statusCode,
                login_url: http.value(forHTTPHeaderField: "X-Term-LLM-Login-URL"),
                location: http.value(forHTTPHeaderField: "Location")
            ))
        }

        // 401: might be bearer login page with HTML config, or passkey redirect
        if http.statusCode == 401 {
            if let html = String(data: data, encoding: .utf8),
               let config = try? Self.parseDataHubConfig(html: html) {
                return .page(config)
            }
            return .redirect(HubRootRedirect(
                status: 401,
                login_url: http.value(forHTTPHeaderField: "X-Term-LLM-Login-URL"),
                location: http.value(forHTTPHeaderField: "Location")
            ))
        }

        if http.statusCode == 403 {
            throw HubAPIError(status: 403, message: "Hub root returned HTTP 403.")
        }

        guard (200...299).contains(http.statusCode) else {
            throw HubAPIError(status: http.statusCode, message: "Hub root returned HTTP \(http.statusCode).")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw HubAPIError(status: http.statusCode, message: "Hub root returned non-UTF-8 content.")
        }

        let config = try Self.parseDataHubConfig(html: html)
        return .page(config)
    }

    /// Convenience wrapper that calls ``discover()`` and extracts the
    /// ``HubPageConfiguration``, throwing if the root redirected.
    func page_configuration() async throws -> HubPageConfiguration {
        switch try await discover() {
        case .page(let config):
            return config
        case .redirect(let r):
            throw HubAPIError(
                status: r.status,
                message: "Hub root redirected instead of serving a page (HTTP \(r.status))."
            )
        }
    }

    /// Authenticate with a bearer token.  Validates the token by making an
    /// `Authorization: Bearer <token>` request to `/api/nodes`.  On success,
    /// constructs a scoped, HTTPOnly `term_llm_hub_token` cookie and sinks
    /// it into WK via `cookie_sink`.
    ///
    /// The token is never placed in a query string.  No token is stored
    /// outside WK's cookie jar.
    func login_bearer(token: String) async throws {
        let authorization = captureAuthorization()
        let url = mounted("/api/nodes")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = Self.defaultTimeout

        // No on_unauthorized — this is a login attempt, not an authenticated request
        let (_, http) = try await transport.execute(request, onUnauthorized: nil)

        guard (200...299).contains(http.statusCode) else {
            throw HubAPIError(status: http.statusCode, message: "Bearer token rejected (HTTP \(http.statusCode)).")
        }

        // Construct a scoped auth cookie matching the server's SetAuthCookie,
        // but with Secure added on HTTPS.  HTTPOnly is set via the raw
        // Set-Cookie header parsing path since HTTPCookie(properties:) cannot
        // express it directly.
        let cookiePath = mount_path.isEmpty ? "/" : mount_path + "/"
        let host = expected_host
        guard !host.isEmpty else {
            throw HubAPIError(status: 0, message: "Hub URL has no host.")
        }
        let cookie = Self.makeAuthCookie(
            name: "term_llm_hub_token",
            value: token,
            host: host,
            path: cookiePath,
            secure: is_https
        )
        guard let cookie else {
            throw HubAPIError(status: 0, message: "Failed to construct auth cookie.")
        }
        guard authorizationIsCurrent(authorization.epoch), !Task.isCancelled else { throw CancellationError() }
        try await importCookies([cookie], authorization: authorization)
    }

    /// Clear local auth cookies for this Hub's host and mount path.  Used for
    /// bearer/none logout (no server-side logout endpoint in those modes).
    /// Removes `term_llm_hub_token` and `term_llm_hub_session` by sinking
    /// expired replacements scoped to exact host + mount path.
    func clear_local_auth() async {
        let authorization = captureAuthorization()
        let cookiePath = mount_path.isEmpty ? "/" : mount_path + "/"
        let host = expected_host
        guard !host.isEmpty else { return }
        let names = ["term_llm_hub_token", "term_llm_hub_session"]
        var expired: [HTTPCookie] = []
        for name in names {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: "",
                .domain: host,
                .path: cookiePath,
                .expires: Date(timeIntervalSince1970: 0),
                .maximumAge: "0",
            ]
            if is_https { properties[.secure] = true }
            if let cookie = HTTPCookie(properties: properties) {
                expired.append(cookie)
            }
        }
        if !expired.isEmpty {
            try? await importCookies(expired, authorization: authorization)
        }
    }

    // MARK: - HTML parsing

    /// Extracts the `data-hub-config` JSON from Hub root HTML.  The value is
    /// HTML-escaped inside the attribute (e.g. `&#34;` for `"`).
    static func parseDataHubConfig(html: String) throws -> HubPageConfiguration {
        guard let attrRange = html.range(of: #"data-hub-config=""#) else {
            throw HubAPIError(status: 0, message: "Hub root HTML does not contain data-hub-config.")
        }
        let afterOpen = attrRange.upperBound
        guard let closeQuote = html[afterOpen...].firstIndex(of: "\"") else {
            throw HubAPIError(status: 0, message: "Malformed data-hub-config attribute (no closing quote).")
        }
        let escaped = String(html[afterOpen..<closeQuote])
        let unescaped = escaped
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let data = unescaped.data(using: .utf8) else {
            throw HubAPIError(status: 0, message: "data-hub-config is not valid UTF-8 after unescaping.")
        }
        do {
            return try JSONDecoder().decode(HubPageConfiguration.self, from: data)
        } catch {
            throw HubAPIError(status: 0, message: "data-hub-config JSON is malformed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cookie filtering

    /// Hub auth cookie name prefixes that must be restricted to the exact
    /// configured mount path.  These cookies carry session/token material and
    /// must never leak between a root Hub and a nested Hub, or vice-versa.
    /// Only hub-scoped names are sent; `term_llm_web_*` cookies belong to the
    /// per-node web UI and are excluded from native transport requests.
    private static let hubAuthCookieNames: Set<String> = [
        "term_llm_hub_token",
        "term_llm_hub_session",
        "term_llm_hub_login",
        "term_llm_hub_bootstrap",
        "term_llm_hub_recovery",
        "term_llm_hub_reauth",
        "term_llm_hub_registration",
    ]

    /// Filters raw WK cookies to those allowed for a specific request URL.
    ///
    /// Strict rules to prevent cross-hub cookie leakage:
    /// - **Exact host**: cookie domain must equal `expected_host` exactly.
    ///   Domain cookies (`.example.com`) are rejected.
    /// - **Auth cookies**: known hub auth cookie names are restricted to the
    ///   exact configured mount path (`mount_path + "/"`).  A root Hub's
    ///   `term_llm_hub_token` at path `/` is never sent to a nested Hub at
    ///   `/nested/`, and vice-versa.  `term_llm_web_*` cookies are excluded
    ///   entirely (they belong to per-node web UI, not native transport).
    /// - **Other cookies**: RFC 6265 §5.1.4 path-match.  Cookie path `/hub/`
    ///   matches request `/hub/api/nodes` but NOT `/hubstuff/api`.
    /// - **Secure**: secure cookies only sent over HTTPS.
    /// - **Expiry**: expired cookies are dropped.
    func filteredCookies(_ cookies: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        let now = Date()
        let requestPath = url.path.isEmpty ? "/" : url.path
        let authPath = mount_path.isEmpty ? "/" : mount_path + "/"
        return cookies.filter { cookie in
            // Exact host match — reject domain cookies
            let cookieDomain = cookie.domain.lowercased()
            guard cookieDomain == expected_host else { return false }

            // Reject web-session cookies (belong to per-node UI, not hub transport)
            if cookie.name.hasPrefix("term_llm_web_") { return false }

            let cp = cookie.path.isEmpty ? "/" : cookie.path

            if Self.hubAuthCookieNames.contains(cookie.name) {
                // Auth cookies: exact mount-path ownership only.
                // Cookie path must equal the canonical auth path for this hub.
                guard cp == authPath else { return false }
            } else {
                // Non-auth cookies: RFC 6265 §5.1.4 path match
                if requestPath != cp {
                    guard requestPath.hasPrefix(cp) else { return false }
                    if !cp.hasSuffix("/") {
                        guard cp.count < requestPath.count else { return false }
                        let idx = requestPath.index(requestPath.startIndex, offsetBy: cp.count)
                        guard requestPath[idx] == "/" else { return false }
                    }
                }
            }

            // Secure cookies over HTTPS only
            if cookie.isSecure && !is_https { return false }

            // Expiry
            if let expires = cookie.expiresDate, expires < now { return false }

            return true
        }
    }

    // MARK: - Cookie construction

    /// Constructs an HTTPOnly auth cookie.  `HTTPCookie(properties:)` does not
    /// expose an HTTPOnly flag, so we round-trip through `Set-Cookie` header
    /// parsing which does honour `HttpOnly`.
    static func makeAuthCookie(
        name: String, value: String, host: String, path: String, secure: Bool
    ) -> HTTPCookie? {
        var header = "\(name)=\(value); Path=\(path); HttpOnly; SameSite=Strict"
        header += "; Max-Age=\(365 * 24 * 60 * 60)"
        if secure { header += "; Secure" }
        // HTTPCookie.cookies(withResponseHeaderFields:for:) parses Set-Cookie
        let url = URL(string: "\(secure ? "https" : "http")://\(host)\(path)")!
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": header],
            for: url
        )
        return cookies.first
    }

    // MARK: - Private transport

    /// Resolves an API path (which may contain a query string) to a full URL
    /// under the configured mount path.  The query portion is split out and
    /// set on URLComponents.query so `?` is not percent-encoded into the path.
    private func mounted(_ path: String, percentEncodedQuery: String? = nil) -> URL {
        let suffix = path.hasPrefix("/") ? path : "/\(path)"

        // Split path from query
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
        components.path = "\(mount_path)\(pathPart)"
        components.query = queryPart
        if let percentEncodedQuery { components.percentEncodedQuery = percentEncodedQuery }
        return components.url!
    }

    private enum Method: String { case GET, POST, PATCH, DELETE }

    /// Long-lived ephemeral session shared by every production Hub/node
    /// request so TCP/TLS connections (and HTTP/2) are reused across polls.
    /// No cookie jar, no credential storage and no response cache, so nothing
    /// survives between requests except pooled connections. Each request
    /// attaches its own per-task delegate (`URLSessionTask.delegate`); the
    /// session delegate only exists as a redirect-blocking backstop.
    static let sharedSession: URLSession = ephemeralSession(delegate: SessionRedirectBlocker())

    /// Creates an ephemeral URLSession with no cookie jar, no credential
    /// storage, no response cache, and the given delegate.
    static func ephemeralSession(delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = defaultTimeout
        config.timeoutIntervalForResource = defaultTimeout
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private final class SessionRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Core typed transport.
    private func request<T: Decodable>(
        _ path: String,
        method: Method = .GET,
        body: (any Encodable)? = nil,
        rawBody: Data? = nil
    ) async throws -> T {
        let data = try await executeRequest(path, method: method, body: body, rawBody: rawBody)
        if data.isEmpty {
            throw HubAPIError(status: 200, message: "Hub returned an empty response.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Raw-data variant for passkey ceremony JSON the caller interprets.
    private func requestRaw(
        _ path: String,
        method: Method = .POST,
        body: Data? = nil
    ) async throws -> Data {
        let data = try await executeRequest(path, method: method, rawBody: body)
        if data.isEmpty {
            throw HubAPIError(status: 200, message: "Hub returned an empty response.")
        }
        return data
    }

    /// Shared request execution: cookie filtering, Origin injection,
    /// SDK-response-time 401 purge, redirect blocking, bounded timeout,
    /// response Set-Cookie processing through scoped cookie_sink.
    private func executeRequest(
        _ path: String,
        method: Method = .GET,
        body: (any Encodable)? = nil,
        rawBody: Data? = nil,
        percentEncodedQuery: String? = nil,
        revokesOnUnauthorized: Bool = true
    ) async throws -> Data {
        let authorization = captureAuthorization()
        let url = mounted(path, percentEncodedQuery: percentEncodedQuery)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = Self.defaultTimeout

        // Origin on mutations
        if method != .GET {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }

        // Body
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else if let rawBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        }

        // Cookie injection: strict host + mount-path + secure + expiry filter
        let allCookies = await cookie_source()
        let cookies = filteredCookies(allCookies, for: url)
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in cookieHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        guard authorizationIsCurrent(authorization.epoch), !Task.isCancelled else { throw CancellationError() }
        let (data, http) = try await transport.execute(request, onUnauthorized: revokesOnUnauthorized ? authorization.callback : nil)

        // Process response Set-Cookie headers through scoped cookie_sink.
        // No ambient jar — the only cookie persistence is through this sink.
        if authorizationIsCurrent(authorization.epoch) {
            try await sinkResponseCookies(from: http, for: url, authorization: authorization)
        }

        if !(200...299).contains(http.statusCode) {
            let parsed = try? JSONDecoder().decode(HubErrorBody.self, from: data)
            let fallback: String
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                fallback = text
            } else {
                fallback = "Hub request failed (\(http.statusCode))."
            }
            throw HubAPIError(
                status: http.statusCode,
                message: parsed?.error?.message ?? parsed?.message ?? fallback,
                type: parsed?.error?.type ?? ""
            )
        }

        return data
    }

    /// Parse Set-Cookie headers from the response, filter to hub auth scope
    /// (exact host, exact mount path, HTTPS secure), and sink to WK.
    private func sinkResponseCookies(from http: HTTPURLResponse, for url: URL, authorization: Authorization) async throws {
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { out, pair in
            if let key = pair.key as? String, let val = pair.value as? String {
                out[key] = val
            }
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !responseCookies.isEmpty else { return }

        let authPath = mount_path.isEmpty ? "/" : mount_path + "/"
        let accepted = responseCookies.filter { cookie in
            // Exact host only
            guard cookie.domain.lowercased() == expected_host else { return false }
            // Hub auth cookies only — don't sink arbitrary cookies
            guard Self.hubAuthCookieNames.contains(cookie.name) else { return false }
            // Must be scoped to this hub's mount path
            let cp = cookie.path.isEmpty ? "/" : cookie.path
            guard cp == authPath else { return false }
            // HTTPS: accept secure cookies only on HTTPS; on HTTP accept non-secure
            if cookie.isSecure && !is_https { return false }
            return true
        }
        if !accepted.isEmpty {
            try await importCookies(accepted, authorization: authorization)
        }
    }
}

// MARK: - HubServing conformance

extension HubClient: HubServing {

    // MARK: Nodes

    func list_nodes() async throws -> NodesResponse {
        try await request("/api/nodes")
    }

    func test_node(_ form: NodeFormData) async throws -> TestNodeResponse {
        try await request("/api/nodes/test", method: .POST, body: form)
    }

    func add_node(_ form: NodeFormData) async throws -> AddNodeResponse {
        try await request("/api/nodes", method: .POST, body: form)
    }

    func remove_node(id: String) async throws -> RemovedNodeResponse {
        try await request("/api/nodes/\(id.urlPathEncoded)", method: .DELETE)
    }

    func reorder_nodes(node_ids: [String]) async throws -> NodeOrderResponse {
        try await request("/api/nodes/order", method: .PATCH, body: ["node_ids": node_ids])
    }

    // MARK: Attention

    func list_attention(limit: Int? = nil) async throws -> AttentionResponse {
        if let limit {
            let clamped = min(max(limit, 1), 500)
            return try await request("/api/attention?limit=\(clamped)")
        }
        return try await request("/api/attention")
    }

    func clear_attention() async throws -> ClearAttentionResponse {
        try await request("/api/attention/clear", method: .POST, body: EmptyBody())
    }

    func mark_attention_seen(_ item: AttentionSeenRequest) async throws -> SeenAttentionResponse {
        try await request("/api/attention/seen", method: .POST, body: item)
    }

    // MARK: Delegations

    func list_delegations() async throws -> DelegationsResponse {
        try await request("/api/delegations")
    }

    // MARK: Changes

    func wait_for_changes(since: UInt64?, timeout: Int) async throws -> HubChangesResponse {
        guard let since else { return try await request("/api/changes") }
        return try await request("/api/changes?since=\(since)&timeout=\(timeout)")
    }

    // MARK: Registration

    func registration_info() async throws -> RegistrationInfoResponse {
        try await request("/api/registration-info")
    }

    // MARK: Auth / Session / Security

    func session() async throws -> HubSessionResponse {
        try await request("/api/auth/session")
    }

    func list_credentials() async throws -> CredentialsResponse {
        try await request("/api/auth/credentials")
    }

    func rename_credential(record_id: String, display_name: String) async throws -> HubCredential {
        try await request(
            "/api/auth/credentials/\(record_id.urlPathEncoded)",
            method: .PATCH,
            body: ["display_name": display_name]
        )
    }

    func remove_credential(record_id: String) async throws -> OkResponse {
        try await request("/api/auth/credentials/\(record_id.urlPathEncoded)", method: .DELETE)
    }

    func revoke_other_sessions() async throws -> RevokeSessionsResponse {
        try await request("/api/auth/sessions/revoke-others", method: .POST, body: EmptyBody())
    }

    func logout() async throws -> RedirectResponse {
        try await request("/api/auth/logout", method: .POST, body: EmptyBody())
    }

    // MARK: Passkey ceremonies

    func begin_login(return_path: String) async throws -> Data {
        let body = try JSONEncoder().encode(["return_path": return_path])
        return try await requestRaw("/api/auth/login/begin", body: body)
    }

    func finish_login(credential: Data) async throws -> RedirectResponse {
        try await request("/api/auth/login/finish", method: .POST, rawBody: credential)
    }

    func begin_reauthentication() async throws -> Data {
        let body = try JSONEncoder().encode(EmptyBody())
        return try await requestRaw("/api/auth/reauth/begin", body: body)
    }

    func finish_reauthentication(credential: Data) async throws -> OkResponse {
        try await request("/api/auth/reauth/finish", method: .POST, rawBody: credential)
    }

    func begin_additional_registration(display_name: String) async throws -> Data {
        let body = try JSONEncoder().encode(["display_name": display_name])
        return try await requestRaw("/api/auth/credentials/register/begin", body: body)
    }

    /// Server returns HTTP 201 with the newly created ``HubCredential``.
    func finish_additional_registration(credential: Data) async throws -> HubCredential {
        try await request("/api/auth/credentials/register/finish", method: .POST, rawBody: credential)
    }

    // MARK: Grant registration

    func verify_grant(prefix: GrantPrefix, code: String) async throws -> OkResponse {
        try await request("\(prefix.rawValue)/verify", method: .POST, body: ["code": code])
    }

    func begin_grant_registration(prefix: GrantPrefix, display_name: String) async throws -> Data {
        let body = try JSONEncoder().encode(["display_name": display_name])
        return try await requestRaw("\(prefix.rawValue)/register/begin", body: body)
    }

    func finish_grant_registration(prefix: GrantPrefix, credential: Data, return_path: String) async throws -> RedirectResponse {
        let query = return_path.isEmpty ? "" : "?return=\(return_path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? return_path)"
        return try await request("\(prefix.rawValue)/register/finish\(query)", method: .POST, rawBody: credential)
    }

    // MARK: Native authorize

    func authorize_native(challenge: String) async throws -> RedirectResponse {
        try await request("/api/auth/native/authorize", method: .POST, body: ["challenge": challenge])
    }

    // MARK: Health

    func healthz() async throws -> HealthResponse {
        try await request("/healthz")
    }
}

// MARK: - Session search

extension HubClient: HubSessionSearching {
    /// Fan-out leg through the Hub's node proxy, which injects the node token.
    /// A 401/403 here may come from the node rather than the Hub session, so it
    /// fails this agent only; ordinary Hub polling owns Hub sign-in revocation.
    func search_sessions(node_id: String, query: String, limit: Int) async throws -> SessionSearchResponse {
        guard SessionSearchQuery.isSafeNodeID(node_id) else {
            throw HubAPIError(status: 0, message: "Unsafe node identifier.")
        }
        let data = try await executeRequest(
            "/node/\(node_id)/v1/sessions/search",
            percentEncodedQuery: SessionSearchQuery.percentEncoded(query: query, limit: limit),
            revokesOnUnauthorized: false
        )
        if data.isEmpty { throw HubAPIError(status: 200, message: "Hub returned an empty response.") }
        return try JSONDecoder().decode(SessionSearchResponse.self, from: data)
    }

    func sessions_status(node_id: String, ids: [String]) async throws -> DirectNodeSessionsStatus {
        guard SessionSearchQuery.isSafeNodeID(node_id) else {
            throw HubAPIError(status: 0, message: "Unsafe node identifier.")
        }
        guard let query = SessionSearchQuery.percentEncodedStatus(ids: ids) else { return DirectNodeSessionsStatus(sessions: []) }
        let data = try await executeRequest(
            "/node/\(node_id)/v1/sessions/status",
            percentEncodedQuery: query,
            revokesOnUnauthorized: false
        )
        if data.isEmpty { throw HubAPIError(status: 200, message: "Hub returned an empty response.") }
        return try JSONDecoder().decode(DirectNodeSessionsStatus.self, from: data)
    }
}

// MARK: - Session browsing

extension HubClient: HubSessionBrowsing {
    /// Through the Hub's node proxy, like search: a 401/403 may come from the
    /// node rather than the Hub session, so it fails this request only.
    func list_sessions(node_id: String, limit: Int, cursor: String?) async throws -> AgentSessionPage {
        guard SessionSearchQuery.isSafeNodeID(node_id) else {
            throw HubAPIError(status: 0, message: "Unsafe node identifier.")
        }
        let data = try await executeRequest(
            "/node/\(node_id)/v1/sessions",
            percentEncodedQuery: AgentSessionQuery.percentEncoded(limit: limit, cursor: cursor),
            revokesOnUnauthorized: false
        )
        if data.isEmpty { throw HubAPIError(status: 200, message: "Hub returned an empty response.") }
        return try JSONDecoder().decode(AgentSessionPage.self, from: data)
    }

    func update_session(node_id: String, session_id: String, patch: AgentSessionPatch) async throws -> AgentSessionPatchResult {
        guard SessionSearchQuery.isSafeNodeID(node_id) else {
            throw HubAPIError(status: 0, message: "Unsafe node identifier.")
        }
        guard AgentSessionQuery.isSafeSessionID(session_id) else {
            throw HubAPIError(status: 0, message: "Unsafe session identifier.")
        }
        let data = try await executeRequest(
            "/node/\(node_id)/v1/sessions/\(session_id)",
            method: .PATCH,
            body: patch,
            revokesOnUnauthorized: false
        )
        if data.isEmpty { throw HubAPIError(status: 200, message: "Hub returned an empty response.") }
        return try JSONDecoder().decode(AgentSessionPatchResult.self, from: data)
    }

    func reorder_pinned_sessions(node_id: String, session_ids: [String]) async throws -> PinnedSessionOrder {
        guard SessionSearchQuery.isSafeNodeID(node_id) else {
            throw HubAPIError(status: 0, message: "Unsafe node identifier.")
        }
        guard session_ids.allSatisfy(AgentSessionQuery.isSafeSessionID) else {
            throw HubAPIError(status: 0, message: "Unsafe session identifier.")
        }
        let data = try await executeRequest(
            "/node/\(node_id)/v1/sessions/pinned-order",
            method: .PATCH,
            body: ["session_ids": session_ids],
            revokesOnUnauthorized: false
        )
        if data.isEmpty { throw HubAPIError(status: 200, message: "Hub returned an empty response.") }
        return try JSONDecoder().decode(PinnedSessionOrder.self, from: data)
    }
}

// MARK: - Private helpers

private struct EmptyBody: Encodable {}

private struct HubErrorBody: Decodable {
    let message: String?
    let error: HubErrorDetail?

    struct HubErrorDetail: Decodable {
        let message: String?
        let type: String?
    }
}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
