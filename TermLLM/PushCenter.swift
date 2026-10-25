import Combine
import CryptoKit
import Foundation
import UIKit
import OSLog
import UserNotifications

private let pushLog = Logger(subsystem: "com.termllm.app", category: "push")

/// APNs gateway this build's device tokens belong to. Builds signed with a
/// development profile (run from Xcode) use the sandbox; TestFlight, App Store
/// and Ad Hoc builds use production.
enum PushEnvironment: String, Codable {
    case production, development

    static let current: PushEnvironment = {
        #if targetEnvironment(simulator)
        return .development
        #else
        // App Store and TestFlight installs carry no embedded profile.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .production }
        return parse(provisioningProfile: data) ?? .production
        #endif
    }()

    /// Reads `aps-environment` from the plist inside a CMS-signed profile.
    static func parse(provisioningProfile data: Data) -> PushEnvironment? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else { return nil }
        return PushEnvironment(rawValue: value)
    }
}

enum PushPermission: String {
    case granted, denied
    case `default`
}

/// What the web UI posts to its node's `/v1/push/subscribe`.
struct NativePushSubscription: Equatable {
    let endpoint: String
    let p256dh: String
    let auth: String
    let applicationServerKey: String

    var bridgeValue: [String: Any] {
        ["endpoint": endpoint, "keys": ["p256dh": p256dh, "auth": auth], "applicationServerKey": applicationServerKey]
    }
}

struct PushNavigation: Equatable {
    let id: UUID
    let url: URL
    /// nil requires a new-scene activity claim; no current scene may consume it.
    var windowID: String? = nil
    var isCompletion = false
    var excludedWindowIDs: Set<String> = []
    /// Saved connection that owns `url`; nil for legacy single-server routing.
    var connectionID: UUID? = nil

    func canPresent(in windowID: String?, server: URL?) -> Bool {
        guard let windowID, self.windowID == windowID, let server else { return false }
        return HubNavigation.isWithinMount(url, server: server)
    }
}

enum PushError: LocalizedError, Equatable {
    case notAllowed
    case invalidServerKey
    case relayUnavailable
    case relayRejected(Int)
    case relayEnvironmentUnsupported(PushEnvironment)
    case invalidRelayResponse
    case registrationTimedOut
    case registrationFailed(String)
    case keychain

    var errorDescription: String? {
        switch self {
        case .notAllowed: return "Notifications are not enabled for term-llm."
        case .invalidServerKey: return "This server's notification key is invalid."
        case .relayUnavailable: return "The notification relay is not configured in this build."
        case .relayRejected(let status): return "The notification relay rejected the registration (HTTP \(status))."
        case .relayEnvironmentUnsupported(let environment):
            return "The notification relay does not support \(environment.rawValue) push. Use a relay and APNs key matching this build's signing environment."
        case .invalidRelayResponse: return "The notification relay returned an invalid response."
        case .registrationTimedOut: return "iOS did not provide a push token. Check your connection and try again."
        case .registrationFailed(let message): return "iOS push registration failed: \(message)"
        case .keychain: return "The notification keys could not be stored on this device."
        }
    }
}

/// Registers a device token with the push relay and returns the Web Push
/// endpoint bound to one server's VAPID key (see push-relay/README.md).
struct PushRelayClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let baseURL: URL
    let transport: Transport

    static let defaultTransport: Transport = { request in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PushError.invalidRelayResponse }
        return (data, response)
    }

    /// HTTPS, or HTTP for loopback hosts (local relay development only).
    static func validatedBaseURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, !raw.contains("$("),
              var components = URLComponents(string: raw), let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(host): break
        default: return nil
        }
        components.path = ""
        return components.url
    }

    func register(deviceToken: String, environment: PushEnvironment, applicationServerKey: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "v1/register"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_token": deviceToken,
            "environment": environment.rawValue,
            "application_server_key": applicationServerKey,
        ])
        let (data, response) = try await transport(request)
        if response.statusCode == 422,
           let error = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           error["code"] as? String == "unsupported_environment" {
            throw PushError.relayEnvironmentUnsupported(environment)
        }
        guard (200..<300).contains(response.statusCode) else { throw PushError.relayRejected(response.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoint = object["endpoint"] as? String,
              endpoint.hasPrefix(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/push/")
        else { throw PushError.invalidRelayResponse }
        return endpoint
    }
}

protocol PushAuthorizer: Sendable {
    func status() async -> UNAuthorizationStatus
    func request() async throws -> Bool
}

struct SystemPushAuthorizer: PushAuthorizer {
    func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func request() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
}

/// App-wide native push state. One APNs registration and one device key pair
/// serve every server and hub node; each node's web UI enrolls itself through
/// `NativePushBridge` when its page loads (see push-relay/README.md).
@MainActor
final class PushCenter: NSObject, ObservableObject {
    static let shared = PushCenter()

    struct Record: Codable, Equatable {
        var endpoint: String
        var applicationServerKey: String
        var deviceToken: String
        var environment: PushEnvironment
        var relay: String
        var retired: Bool?
        var subscriptionID: String?
    }

    static let enabledKey = "push.enabled"
    static let optOutsKey = "push.optOuts"
    static let recordsKey = "push.records"
    static let pendingConsentKey = "push.pendingConsent"
    static let deviceTokenKey = "push.deviceToken"
    static let relayOverrideKey = "push.relayURL"

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var enabled: Bool
    /// Bumped when app-level state changes; the browser tells the page to reconcile.
    @Published private(set) var changeCount = 0
    @Published private(set) var pendingNavigation: PushNavigation?
    @Published var storageIssue: String?
    /// Badge failures are independent of durable push consent/storage failures.
    @Published private(set) var badgeIssue: String?
    @Published var pendingCleanupCount = 0
    @Published var navigationIssue: String?
    let deliveries: PushDeliveryStore
    let windows = PushWindowRegistry()
    let inbox: PushNotificationInbox
    /// Injected by tests; production requests the exact scene or a fresh scene.
    var activateScene: (UISceneSession?, NSUserActivity, @escaping (Error) -> Void) -> Void = { session, activity, failed in
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: activity, options: nil, errorHandler: failed)
    }
    static let navigationActivity = "com.termllm.app.notification"
    static let windowSessionsKey = "push.windowSessions"
    /// Legacy diagnostic only. A URL is never attendance or read authority.
    var visibleURL: URL?
    var isActive: () -> Bool = { UIApplication.shared.applicationState == .active }
    /// Injected by tests; false on iPhone, where only one scene can exist.
    var supportsMultipleScenes: () -> Bool = { UIApplication.shared.supportsMultipleScenes }

    private let defaults: UserDefaults
    private let identities: PushIdentityStore
    private let authorizer: PushAuthorizer
    private let relayTransport: PushRelayClient.Transport
    private let registerForRemote: @MainActor () -> Void
    private let environment: PushEnvironment
    private let tokenTimeout: Duration
    private var optOuts: Set<String>
    var records: [String: Record]
    private var deviceToken: String?
    private var tokenWaiters: [CheckedContinuation<String, Error>] = []
    private var tokenTimeoutTask: Task<Void, Never>?
    private var enrollmentGeneration: UInt64 = 0
    private let badgeSetter: @MainActor (Int) async throws -> Void
    private var attentionBadgeCount: Int?
    private var explicitlyClearedBadge = false
    private var desiredBadgeCount: Int?
    private var appliedBadgeCount: Int?
    private var badgeRevision: UInt64 = 0
    private var badgeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         identities: PushIdentityStore = PushIdentityStore(),
         authorizer: PushAuthorizer = SystemPushAuthorizer(),
         relayTransport: @escaping PushRelayClient.Transport = PushRelayClient.defaultTransport,
         registerForRemote: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
         environment: PushEnvironment = .current,
         tokenTimeout: Duration = .seconds(20),
         deliveries: PushDeliveryStore = PushDeliveryStore(),
         inbox: PushNotificationInbox = SystemPushNotificationInbox(),
         badgeSetter: @escaping @MainActor (Int) async throws -> Void = { count in
             try await UNUserNotificationCenter.current().setBadgeCount(count)
         }) {
        self.badgeSetter = badgeSetter
        self.deliveries = deliveries
        self.inbox = inbox
        self.defaults = defaults
        self.identities = identities
        self.authorizer = authorizer
        self.relayTransport = relayTransport
        self.registerForRemote = registerForRemote
        self.environment = environment
        self.tokenTimeout = tokenTimeout
        enabled = defaults.bool(forKey: Self.enabledKey)
        optOuts = Set(defaults.stringArray(forKey: Self.optOutsKey) ?? [])
        records = defaults.data(forKey: Self.recordsKey)
            .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
        super.init()
        do {
            // Replay an explicit interrupted preference request before any old
            // shared snapshot can replace local off. This retry marker is not a
            // substitute for acknowledged shared-keychain durability.
            if let data = defaults.data(forKey: Self.pendingConsentKey) {
                let pending = try JSONDecoder().decode(PushConsentJournal.Snapshot.self, from: data)
                if pending.enabled == false { enabled = false }
                optOuts.formUnion(pending.optOuts)
                try deliveries.persistConsent(enabled: pending.enabled, optOuts: pending.optOuts)
                enabled = pending.enabled == true; optOuts = pending.optOuts
                if let value = pending.enabled { defaults.set(value, forKey: Self.enabledKey) }
                persistOptOuts()
                defaults.removeObject(forKey: Self.pendingConsentKey)
            }
            if let saved = try deliveries.consentSnapshot() {
                enabled = saved.enabled == true; optOuts = saved.optOuts
            }
            try deliveries.migrate(enabled: defaults.object(forKey: Self.enabledKey) == nil ? nil : enabled, optOuts: optOuts)
            // One locked read/write for the whole launch reconciliation rather
            // than one shared-file transaction per record (each re-reads the
            // file and consent journal). Records before a failing one still
            // commit, matching the previous per-record transactions.
            var recoveredRetirements = false
            var recordFailure: Error?
            let (shared, pending) = try deliveries.transaction { state -> (PushDeliveryStore.State, Int) in
                let shared = state
                for (key, record) in records {
                    guard let separator = key.firstIndex(of: "|") else { continue }
                    let localOff = shared.enabled == false || shared.optOuts.contains(key)
                    if localOff, record.retired != true { records[key]?.retired = true; recoveredRetirements = true }
                    let origin = String(key[..<separator])
                    let scope = String(key[key.index(after: separator)...])
                    do {
                        try PushDeliveryStore.remember(in: &state, origin: origin, scope: scope,
                                                       endpoint: record.endpoint, subscriptionID: record.subscriptionID)
                    } catch { recordFailure = error; break }
                    if record.retired == true || localOff { PushDeliveryStore.retire(in: &state, origin: origin, scope: scope) }
                }
                return (shared, state.enrollments.filter(\.pendingCleanup).count)
            }
            enabled = shared.enabled == true
            optOuts = shared.optOuts
            if let recordFailure { throw recordFailure }
            if recoveredRetirements { persistRecords() }
            pendingCleanupCount = pending
        } catch { reportStorageFailure() }
    }

    var relayURL: URL? {
        PushRelayClient.validatedBaseURL(defaults.string(forKey: Self.relayOverrideKey))
            ?? PushRelayClient.validatedBaseURL(Bundle.main.object(forInfoDictionaryKey: "TermLLMPushRelayURL") as? String)
    }

    private var isAuthorized: Bool {
        [.authorized, .provisional, .ephemeral].contains(authorization)
    }

    // MARK: App lifecycle

    func applicationDidLaunch() {
        Task {
            await refreshAuthorization()
            // Apple recommends registering on every launch; tokens can change.
            if enabled && isAuthorized { registerForRemote() }
        }
    }

    /// Re-reads iOS permission (e.g. after returning from Settings).
    func refreshAuthorization() async {
        let status = await authorizer.status()
        if status != authorization {
            authorization = status
            notifyChange()
        }
        // Also retry a failed badge write when returning from Settings, even
        // when authorization itself has not changed.
        reconcileAttentionBadge()
    }

    /// App-wide verified Attention total, not a per-scene or push-payload count.
    /// Unknown totals preserve the last verified value (and an existing OS
    /// badge on initial load). Polling never requests notification permission.
    func updateAttentionBadge(count: Int?) {
        if let count { attentionBadgeCount = max(0, count) }
        reconcileAttentionBadge()
    }

    private func reconcileAttentionBadge() {
        if let count = attentionBadgeCount {
            desiredBadgeCount = enabled && isAuthorized ? count : 0
        } else if explicitlyClearedBadge {
            desiredBadgeCount = 0
        } else {
            // Neither a verified total nor an explicit off action: no guessed
            // zero, including during the initial authorization refresh.
            return
        }
        badgeRevision &+= 1
        guard badgeTask == nil, desiredBadgeCount != appliedBadgeCount else { return }
        badgeTask = Task { await drainAttentionBadge() }
    }

    private func drainAttentionBadge() async {
        defer { badgeTask = nil }
        // Only one setter may be in flight. Re-read the latest target after
        // each completion so a slow positive write cannot overtake zero/off.
        while let count = desiredBadgeCount, count != appliedBadgeCount {
            let revision = badgeRevision
            // A throwing OS write may have partially succeeded; do not trust
            // an older successful value to deduplicate the next attempt.
            appliedBadgeCount = nil
            do {
                try await badgeSetter(count)
                appliedBadgeCount = count
                badgeIssue = nil
            } catch {
                badgeIssue = "The app icon badge could not be updated: \(error.localizedDescription)"
                // No busy retry loop. A newer update or foreground refresh
                // retries, including when its target count is unchanged.
                if revision == badgeRevision { return }
            }
        }
    }

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        let previous = defaults.string(forKey: Self.deviceTokenKey)
        deviceToken = token
        defaults.set(token, forKey: Self.deviceTokenKey)
        finishTokenWait(.success(token))
        // Endpoints embed the token: pages must re-enroll.
        if let previous, previous != token { notifyChange() }
    }

    func didFailToRegister(_ error: Error) {
        finishTokenWait(.failure(PushError.registrationFailed(error.localizedDescription)))
    }

    // MARK: App settings

    /// The app-wide switch. Turning it on asks iOS for permission if needed.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        if on {
            return await turnOn()
        } else {
            enrollmentGeneration &+= 1
            let persisted = persistConsent(enabled: false, optOuts: optOuts)
            enabled = false
            explicitlyClearedBadge = true
            reconcileAttentionBadge()
            defaults.set(false, forKey: Self.enabledKey)
            for key in records.keys { records[key]?.retired = true }
            persistRecords()
            refreshPendingCleanup()
            await clearNotifications()
            notifyChange()
            return persisted
        }
    }

    private func persistConsent(enabled: Bool?, optOuts: Set<String>) -> Bool {
        do {
            let pending = PushConsentJournal.Snapshot(enabled: enabled, optOuts: optOuts)
            defaults.set(try JSONEncoder().encode(pending), forKey: Self.pendingConsentKey)
            try deliveries.persistConsent(enabled: enabled, optOuts: optOuts)
            defaults.removeObject(forKey: Self.pendingConsentKey)
            storageIssue = nil
            return true
        } catch { reportStorageFailure(); return false }
    }

    private func turnOn(optOuts desired: Set<String>? = nil) async -> Bool {
        let wasEnabled = enabled
        enrollmentGeneration &+= 1
        let next = desired ?? optOuts
        guard persistConsent(enabled: true, optOuts: next) else { return false }
        optOuts = next
        persistOptOuts()
        enabled = true
        defaults.set(true, forKey: Self.enabledKey)
        var status = await authorizer.status()
        if status == .notDetermined {
            _ = try? await authorizer.request()
            status = await authorizer.status()
        }
        let changed = status != authorization || !wasEnabled
        authorization = status
        reconcileAttentionBadge()
        if isAuthorized { registerForRemote() }
        if changed { notifyChange() }
        return true
    }

    // MARK: Web UI bridge (one scope per server or hub node)

    static func scopeKey(origin: String, scope: String) -> String { origin + "|" + scope }

    func permission(origin: String, scope: String) -> PushPermission {
        if authorization == .denied { return .denied }
        guard isAuthorized, enabled, !optOuts.contains(Self.scopeKey(origin: origin, scope: scope)) else { return .default }
        return .granted
    }

    /// The web UI's Enable: clears this node's opt-out and turns notifications on.
    func requestPermission(origin: String, scope: String) async -> PushPermission {
        var next = optOuts
        next.remove(Self.scopeKey(origin: origin, scope: scope))
        guard await turnOn(optOuts: next) else { return .default }
        return permission(origin: origin, scope: scope)
    }

    func subscription(origin: String, scope: String, label: String? = nil, nodeBasePath: String? = nil) -> NativePushSubscription? {
        guard permission(origin: origin, scope: scope) == .granted,
              let record = records[Self.scopeKey(origin: origin, scope: scope)], record.retired != true,
              record.environment == environment, record.relay == relayURL?.absoluteString,
              deviceToken == nil || record.deviceToken == deviceToken,
              let identity = try? identities.load(), let p256dh = try? identity.publicKeyBase64URL() else { return nil }
        if let pending = try? deliveries.pending(origin: origin, scope: scope), pending.contains(where: {
            $0.endpoint == record.endpoint && ($0.subscriptionID == record.subscriptionID || record.subscriptionID == nil)
        }) { return nil } // explicit enable must drain retired server handles first
        // Refresh metadata even for a cached endpoint so existing installs gain
        // scoped routing on their next page visit without re-enrolling.
        guard let rawKey = Data(base64URLEncoded: record.applicationServerKey) else { return nil }
        do {
            try identities.setRoute(tag: WebPushCrypto.sourceTag(applicationServerKey: rawKey), origin: origin,
                                    scope: scope, label: label, nodeBasePath: nodeBasePath)
        } catch { return nil }
        let tag = WebPushCrypto.sourceTag(applicationServerKey: rawKey)
        return NativePushSubscription(endpoint: record.endpoint, p256dh: p256dh,
                                      auth: identity.authenticationSecret(tag: tag, origin: origin, scope: scope).base64URLEncodedString(),
                                      applicationServerKey: record.applicationServerKey)
    }

    func subscribe(origin: String, scope: String, applicationServerKey: String, label: String? = nil, nodeBasePath: String? = nil) async throws -> NativePushSubscription {
        guard permission(origin: origin, scope: scope) == .granted else { throw PushError.notAllowed }
        let generation = enrollmentGeneration
        guard let rawKey = Data(base64URLEncoded: applicationServerKey), rawKey.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: rawKey)) != nil else { throw PushError.invalidServerKey }
        guard let relay = relayURL else { throw PushError.relayUnavailable }
        let identity: PushIdentity
        do { identity = try identities.loadOrCreate() } catch { throw PushError.keychain }
        let token = try await currentDeviceToken()
        let key = rawKey.base64URLEncodedString()
        let endpoint = try await PushRelayClient(baseURL: relay, transport: relayTransport)
            .register(deviceToken: token, environment: environment, applicationServerKey: key)
        // No server enrollment exists until this method returns an endpoint.
        // A stale relay registration is stateless; never retire a newer consent
        // epoch's enrollment just because an older request finished late.
        guard generation == enrollmentGeneration, permission(origin: origin, scope: scope) == .granted else {
            throw PushError.notAllowed
        }
        do {
            try deliveries.remember(origin: origin, scope: scope, endpoint: endpoint)
        } catch { reportStorageFailure() }
        do {
            try identities.setRoute(tag: WebPushCrypto.sourceTag(applicationServerKey: rawKey), origin: origin,
                                    scope: scope, label: label, nodeBasePath: nodeBasePath)
        } catch { throw PushError.keychain }
        records[Self.scopeKey(origin: origin, scope: scope)] = Record(
            endpoint: endpoint, applicationServerKey: key, deviceToken: token,
            environment: environment, relay: relay.absoluteString)
        persistRecords()
        let tag = WebPushCrypto.sourceTag(applicationServerKey: rawKey)
        return NativePushSubscription(endpoint: endpoint, p256dh: try identity.publicKeyBase64URL(),
                                      auth: identity.authenticationSecret(tag: tag, origin: origin, scope: scope).base64URLEncodedString(),
                                      applicationServerKey: key)
    }

    /// Forgets this node's record (key rotation, permission withdrawn). Not an opt-out.
    @discardableResult
    func unsubscribe(origin: String, scope: String) -> Bool {
        enrollmentGeneration &+= 1
        var persisted = true
        // A transport forget is not proof of a successful authenticated DELETE.
        do { try deliveries.retire(origin: origin, scope: scope) } catch { reportStorageFailure(); persisted = false }
        refreshPendingCleanup()
        let key = Self.scopeKey(origin: origin, scope: scope)
        if records[key] != nil { records[key]?.retired = true; persistRecords() }
        return persisted
    }

    /// The user turned notifications off for this node in its web UI.
    @discardableResult
    func disable(origin: String, scope: String) -> Bool {
        let key = Self.scopeKey(origin: origin, scope: scope)
        var next = optOuts; next.insert(key)
        let global = defaults.object(forKey: Self.enabledKey) == nil ? (try? deliveries.consentSnapshot())?.enabled : enabled
        let persisted = persistConsent(enabled: global, optOuts: next)
        optOuts = next; persistOptOuts()
        let retired = unsubscribe(origin: origin, scope: scope)
        Task { await clearNotifications(origin: origin, scope: scope) }
        notifyChange()
        return persisted && retired
    }

    // MARK: Notifications shown and tapped

    /// Saved connections are the routing table: the connection whose mount
    /// contains the page owns the tap, even when another one is selected.
    /// Without saved connections (legacy/tests) the configured server's origin
    /// is the only owner. A tap nobody owns just opens the app, quietly.
    func open(urlString raw: String?, scope: String? = nil, configuredServer: URL?, connections: [HubConnection] = [],
              selectedConnectionID: UUID? = nil, windowID: String? = nil, isCompletion: Bool = false) {
        guard let raw, var url = URL(string: raw) else { return }
        var connectionID: UUID?
        if connections.isEmpty {
            guard let server = configuredServer, let origin = Self.origin(url), origin == Self.origin(server) else {
                pushLog.info("Notification tap has no matching server; opening the app only")
                return
            }
        } else {
            guard let resolved = Self.resolveDestination(url, scope: scope, in: connections, selectedID: selectedConnectionID) else {
                pushLog.info("Notification tap matches no saved connection; opening the app only")
                return
            }
            if resolved.url != url { pushLog.info("Notification page rebased onto the saved connection's mount") }
            url = resolved.url
            connectionID = resolved.connection.id
        }
        let sessions = defaults.dictionary(forKey: Self.windowSessionsKey) as? [String: String] ?? [:]
        let session = windowID.flatMap { id in
            windows.scene(windowID: id)?.session ?? UIApplication.shared.openSessions.first { $0.persistentIdentifier == sessions[id] }
        }
        // If the exact scene is gone, only the scene activity may claim a fresh
        // destination. Existing sibling BrowserViews cannot consume nil owner.
        // When no sibling can be substituted, the scene iOS shows replaces the
        // gone owner: single-scene apps (iPhone) cannot create a fresh scene,
        // and with every window closed the launching scene is the fresh one.
        // Route those like manual taps instead of requesting a scene that
        // iOS refuses (single-scene) or that duplicates the launching window.
        let ownerGone = (isCompletion || windowID != nil) && session == nil
        let shownSceneReplacesOwner = ownerGone && (!supportsMultipleScenes() || windows.existingWindowIDs().isEmpty)
        let completion = (isCompletion || windowID != nil) && !shownSceneReplacesOwner
        let navigation = PushNavigation(id: UUID(), url: url,
            windowID: completion ? (session == nil ? nil : windowID) : windows.keyWindowID(), isCompletion: completion,
            excludedWindowIDs: completion && session == nil ? windows.existingWindowIDs() : [],
            connectionID: connectionID)
        pendingNavigation = navigation
        navigationIssue = nil
        // Manual/legacy alerts have no owner claim: use the current key scene,
        // or wait for it to attach on cold launch. Never create a scene for them.
        guard completion else { return }
        let activity = NSUserActivity(activityType: Self.navigationActivity)
        activity.userInfo = ["navigation_id": navigation.id.uuidString]
        activateScene(session, activity) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingNavigation?.id == navigation.id else { return }
                self.pendingNavigation = nil
                self.navigationIssue = "iOS could not open the notification's owning or fresh window. No other conversation was substituted."
            }
        }
    }

    /// Most specific saved mount containing `url`; the selected connection wins
    /// ties. Connections awaiting kind review cannot open pages, so never own.
    static func owningConnection(for url: URL, in connections: [HubConnection], selectedID: UUID?) -> HubConnection? {
        connections
            .filter { !$0.isMobileSharing && $0.needsKindReview != true && HubNavigation.isWithinMount(url, server: $0.url) }
            .max { a, b in
                if a.mountPath.count != b.mountPath.count { return a.mountPath.count < b.mountPath.count }
                return a.id != selectedID && b.id == selectedID
            }
    }

    /// What a push is really about, read off its page path: the agent
    /// (`node/<id>`) and the conversation (`chat/<selector>`), if any.
    struct PushIntent: Equatable {
        var nodeID: String?
        var sessionSelector: String?

        static func parse(path: String, scope: String?) -> PushIntent {
            var intent = PushIntent()
            let segments = path.split(separator: "/").map(String.init)
            for (index, segment) in segments.enumerated() where index + 1 < segments.count {
                if segment == "node", intent.nodeID == nil { intent.nodeID = segments[index + 1] }
                if segment == "chat" { intent.sessionSelector = segments[index + 1] }
            }
            // A node behind a hub enrolls under its public `…/node/<id>` scope
            // even when its own payload paths only know its local prefix.
            if intent.nodeID == nil, let scope {
                let scoped = (scope.removingPercentEncoding ?? scope).split(separator: "/").map(String.init)
                if let index = scoped.firstIndex(of: "node"), index + 1 < scoped.count { intent.nodeID = scoped[index + 1] }
            }
            return intent
        }
    }

    /// A push names "session X on agent Y", but its sender rarely knows the
    /// public mount the app reaches it through: a node behind a hub sends its
    /// local prefix, and a hub under `/hub/` may report paths without it.
    /// Resolve the page against the saved connection on that origin and rebuild
    /// it on the connection's real mount. An already-valid page is kept as is;
    /// anything the connection cannot serve lands on the agent's front page,
    /// or the connection root, never on a 404.
    static func resolveDestination(_ url: URL, scope: String?, in connections: [HubConnection],
                                   selectedID: UUID?) -> (url: URL, connection: HubConnection)? {
        let candidates = connections.filter { !$0.isMobileSharing && $0.needsKindReview != true && sameOrigin($0.url, url) }
        guard !candidates.isEmpty else { return nil }
        let intent = PushIntent.parse(path: url.path, scope: scope)
        if let owner = owningConnection(for: url, in: candidates, selectedID: selectedID) {
            // A direct node serves every page under its mount. A hub serves its
            // own root and `node/<id>/…`; any other path is a sender's guess.
            if owner.kind == .directNode { return (url, owner) }
            let relative = url.path.dropFirst(owner.mountPath.count - 1).split(separator: "/", omittingEmptySubsequences: false)
            if url.path == owner.mountPath || url.path + "/" == owner.mountPath
                || (relative.count >= 3 && relative[1] == "node" && !relative[2].isEmpty) {
                return (url, owner)
            }
            return (rebuilt(intent, on: owner), owner)
        }
        // Same origin, but outside every saved mount: the mount itself is what
        // the sender got wrong. A hub can reach any agent the push names.
        let owner = candidates.first { $0.id == selectedID && ($0.kind == .hub || intent.nodeID == nil) }
            ?? candidates.first { $0.kind == .hub }
            ?? candidates.first { $0.id == selectedID }
            ?? candidates[0]
        return (rebuilt(intent, on: owner), owner)
    }

    private static func rebuilt(_ intent: PushIntent, on connection: HubConnection) -> URL {
        let direct = connection.kind == .directNode
        var root = connection.mountPath
        if !direct {
            guard let nodeID = intent.nodeID else { return connection.url }
            root += "node/" + nodeID + "/"
        }
        if let selector = intent.sessionSelector,
           let chat = HubNavigation.chatDestination(root + "chat/" + selector, server: connection.url,
                                                    nodeID: intent.nodeID, direct: direct) {
            return chat
        }
        return HubNavigation.chatDestination(root, server: connection.url, nodeID: intent.nodeID, direct: direct)
            ?? connection.url
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = origin(lhs), let right = origin(rhs) else { return false }
        return left == right
    }

    func routeManualToKeyScene() {
        guard var navigation = pendingNavigation, !navigation.isCompletion, navigation.windowID == nil,
              let key = windows.keyWindowID() else { return }
        navigation.windowID = key
        pendingNavigation = navigation
    }

    func isKeyScene(_ windowID: String) -> Bool { windows.keyWindowID() == windowID }

    static func windowID(for scene: UIWindowScene) -> String {
        PushWindowRegistry.identifier(persistentIdentifier: scene.session.persistentIdentifier)
    }

    func registerWindow(_ windowID: String, scene: UIWindowScene) {
        windows.register(windowID: windowID, scene: scene)
        let stored = defaults.dictionary(forKey: Self.windowSessionsKey) as? [String: String] ?? [:]
        // Retain only live/restorable scene sessions; no unbounded scene history.
        let live = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        var sessions = stored.filter { live.contains($0.value) }
        sessions[windowID] = scene.session.persistentIdentifier
        // Callers re-register on page loads and bridge messages; only touch
        // the defaults store when the persisted map actually changes.
        if sessions != stored { defaults.set(sessions, forKey: Self.windowSessionsKey) }
        DispatchQueue.main.async { [weak self] in self?.routeManualToKeyScene() }
    }

    func claimNavigation(_ activity: NSUserActivity, windowID: String) {
        guard activity.activityType == Self.navigationActivity,
              let id = activity.userInfo?["navigation_id"] as? String,
              var navigation = pendingNavigation, navigation.isCompletion, navigation.id.uuidString == id,
              navigation.windowID == nil || navigation.windowID == windowID else { return }
        if navigation.windowID == nil, navigation.excludedWindowIDs.contains(windowID) {
            pendingNavigation = nil
            navigationIssue = "iOS did not create a fresh notification window. An existing conversation was not substituted."
            return
        }
        navigation.windowID = windowID
        pendingNavigation = navigation
    }

    func navigationHandled(_ id: UUID) {
        if pendingNavigation?.id == id { pendingNavigation = nil }
    }

    static func samePage(_ lhs: URL, _ rhs: URL) -> Bool {
        func path(_ url: URL) -> String { url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path }
        guard let origin = origin(lhs) else { return false }
        return origin == Self.origin(rhs) && path(lhs) == path(rhs)
    }

    /// Like `location.origin`; nil for URLs without a scheme and host.
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host, !host.isEmpty else { return nil }
        return WebMCPBridge.originString(scheme: scheme, host: host, port: url.port ?? 0)
    }

    // MARK: Private

    private func currentDeviceToken() async throws -> String {
        if let deviceToken { return deviceToken }
        registerForRemote()
        let timeout = tokenTimeout
        return try await withCheckedThrowingContinuation { continuation in
            tokenWaiters.append(continuation)
            if tokenTimeoutTask == nil {
                tokenTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishTokenWait(.failure(PushError.registrationTimedOut))
                }
            }
        }
    }

    private func finishTokenWait(_ result: Result<String, Error>) {
        tokenTimeoutTask?.cancel()
        tokenTimeoutTask = nil
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        waiters.forEach { $0.resume(with: result) }
    }

    func notificationIdentity() -> PushIdentity? { try? identities.load() }

    func scopeIsOptedOut(origin: String, scope: String) -> Bool {
        optOuts.contains(Self.scopeKey(origin: origin, scope: scope))
    }

    func locallyOptedOut(_ message: PushMessage) -> Bool {
        if !enabled, defaults.object(forKey: Self.enabledKey) != nil { return true }
        if let origin = message.origin, let scope = message.scope {
            return scopeIsOptedOut(origin: origin, scope: scope)
        }
        return !optOuts.isEmpty
    }

    private func notifyChange() { changeCount += 1 }

    private func persistOptOuts() { defaults.set(optOuts.sorted(), forKey: Self.optOutsKey) }

    func persistRecords() { defaults.set(try? JSONEncoder().encode(records), forKey: Self.recordsKey) }
}

extension PushCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // userInfo is an immutable property-list snapshot; hop it to the main actor.
        let info = UncheckedUserInfo(value: notification.request.content.userInfo)
        return await MainActor.run { presentationOptions(userInfo: info.value) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let url = info[PushMessage.urlKey] as? String
        let delivered = PushMessage.delivered(userInfo: info)
        let metadata = delivered?.metadata
        handleNotificationTap(urlString: url, scope: delivered?.scope, windowID: metadata?.windowID,
                              isCompletion: metadata?.kind == "completion", completionHandler: completionHandler)
    }

    /// Use the completion-handler delegate API so UIKit's completion runs on the
    /// main thread too. The async delegate's generated thunk can resume on a
    /// worker thread after our actor hop and crash UIKit's state restoration.
    nonisolated func handleNotificationTap(urlString: String?, scope: String? = nil, windowID: String? = nil,
                                           isCompletion: Bool = false, completionHandler: @escaping () -> Void) {
        // UIKit's completion handler is safe to call on the main thread.
        nonisolated(unsafe) let completionHandler = completionHandler
        Task { @MainActor in
            let saved = try? HubConnectionStore.validatedDocument(defaults.object(forKey: HubConnectionStore.storageKey))
            open(urlString: urlString, scope: scope, configuredServer: ServerAddress.parse(defaults.string(forKey: "serverURL") ?? ""),
                 connections: saved?.connections ?? [], selectedConnectionID: saved?.selectedID,
                 windowID: windowID, isCompletion: isCompletion)
            completionHandler()
        }
    }
}

/// Notification userInfo is an immutable property-list snapshot.
private struct UncheckedUserInfo: @unchecked Sendable { let value: [AnyHashable: Any] }
