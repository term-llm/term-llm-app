import Combine
import CryptoKit
import Foundation
import UIKit
import UserNotifications

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
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

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

protocol PushAuthorizer {
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
    static let deviceTokenKey = "push.deviceToken"
    static let relayOverrideKey = "push.relayURL"

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var enabled: Bool
    /// Bumped when app-level state changes; the browser tells the page to reconcile.
    @Published private(set) var changeCount = 0
    @Published private(set) var pendingNavigation: PushNavigation?
    @Published var storageIssue: String?
    @Published var pendingCleanupCount = 0
    let deliveries: PushDeliveryStore
    let windows = PushWindowRegistry()
    let inbox: PushNotificationInbox
    /// Injected by tests; production requests the exact scene or a fresh scene.
    var activateScene: (UISceneSession?, NSUserActivity) -> Void = { session, activity in
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: activity, options: nil)
    }
    static let navigationActivity = "com.termllm.app.notification"
    static let windowSessionsKey = "push.windowSessions"
    /// Legacy diagnostic only. A URL is never attendance or read authority.
    var visibleURL: URL?
    var isActive: () -> Bool = { UIApplication.shared.applicationState == .active }

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

    init(defaults: UserDefaults = .standard,
         identities: PushIdentityStore = PushIdentityStore(),
         authorizer: PushAuthorizer = SystemPushAuthorizer(),
         relayTransport: @escaping PushRelayClient.Transport = PushRelayClient.defaultTransport,
         registerForRemote: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
         environment: PushEnvironment = .current,
         tokenTimeout: Duration = .seconds(20),
         deliveries: PushDeliveryStore = PushDeliveryStore(),
         inbox: PushNotificationInbox = SystemPushNotificationInbox()) {
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
            try deliveries.migrate(enabled: enabled, optOuts: optOuts)
            let shared = try deliveries.transaction { $0 }
            enabled = shared.enabled == true
            optOuts = shared.optOuts
            for (key, record) in records {
                guard let separator = key.firstIndex(of: "|") else { continue }
                let origin = String(key[..<separator])
                let scope = String(key[key.index(after: separator)...])
                try deliveries.remember(origin: origin, scope: scope, endpoint: record.endpoint, subscriptionID: record.subscriptionID)
                if record.retired == true { try deliveries.retire(origin: origin, scope: scope) }
            }
            refreshPendingCleanup()
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
        guard status != authorization else { return }
        authorization = status
        notifyChange()
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
    func setEnabled(_ on: Bool) async {
        if on {
            await turnOn()
        } else {
            enrollmentGeneration &+= 1
            do { try deliveries.setEnabled(false) } catch { reportStorageFailure() }
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            for key in records.keys { records[key]?.retired = true }
            persistRecords()
            refreshPendingCleanup()
            await clearNotifications()
            notifyChange()
        }
    }

    private func turnOn() async {
        let wasEnabled = enabled
        enrollmentGeneration &+= 1
        do { try deliveries.setEnabled(true) } catch { reportStorageFailure() }
        enabled = true
        defaults.set(true, forKey: Self.enabledKey)
        var status = await authorizer.status()
        if status == .notDetermined {
            _ = try? await authorizer.request()
            status = await authorizer.status()
        }
        let changed = status != authorization || !wasEnabled
        authorization = status
        if isAuthorized { registerForRemote() }
        if changed { notifyChange() }
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
        do { try deliveries.setEnabled(true, origin: origin, scope: scope) } catch { reportStorageFailure() }
        if optOuts.remove(Self.scopeKey(origin: origin, scope: scope)) != nil { persistOptOuts() }
        await turnOn()
        return permission(origin: origin, scope: scope)
    }

    func subscription(origin: String, scope: String, label: String? = nil, nodeBasePath: String? = nil) -> NativePushSubscription? {
        guard permission(origin: origin, scope: scope) == .granted,
              let record = records[Self.scopeKey(origin: origin, scope: scope)], record.retired != true,
              record.environment == environment, record.relay == relayURL?.absoluteString,
              deviceToken == nil || record.deviceToken == deviceToken,
              let identity = try? identities.load(), let p256dh = try? identity.publicKeyBase64URL() else { return nil }
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
    func unsubscribe(origin: String, scope: String) {
        enrollmentGeneration &+= 1
        // A transport forget is not proof of a successful authenticated DELETE.
        do { try deliveries.retire(origin: origin, scope: scope) } catch { reportStorageFailure() }
        refreshPendingCleanup()
        let key = Self.scopeKey(origin: origin, scope: scope)
        if records[key] != nil { records[key]?.retired = true; persistRecords() }
    }

    /// The user turned notifications off for this node in its web UI.
    func disable(origin: String, scope: String) {
        let key = Self.scopeKey(origin: origin, scope: scope)
        do { try deliveries.setEnabled(false, origin: origin, scope: scope) } catch { reportStorageFailure() }
        if optOuts.insert(key).inserted { persistOptOuts() }
        unsubscribe(origin: origin, scope: scope)
        Task { await clearNotifications(origin: origin, scope: scope) }
        notifyChange()
    }

    // MARK: Notifications shown and tapped

    func open(urlString raw: String?, configuredServer: URL?, windowID: String? = nil) {
        guard let raw, let url = URL(string: raw), let server = configuredServer,
              let origin = Self.origin(url), origin == Self.origin(server) else { return }
        let sessions = defaults.dictionary(forKey: Self.windowSessionsKey) as? [String: String] ?? [:]
        let session = windowID.flatMap { id in
            windows.scene(windowID: id)?.session ?? UIApplication.shared.openSessions.first { $0.persistentIdentifier == sessions[id] }
        }
        // If the exact scene is gone, only the scene activity may claim a fresh
        // destination. Existing sibling BrowserViews cannot consume nil owner.
        let navigation = PushNavigation(id: UUID(), url: url, windowID: session == nil ? nil : windowID)
        pendingNavigation = navigation
        let activity = NSUserActivity(activityType: Self.navigationActivity)
        activity.userInfo = ["navigation_id": navigation.id.uuidString]
        activateScene(session, activity)
    }

    static func windowID(for scene: UIWindowScene) -> String { "scene:" + scene.session.persistentIdentifier }

    func registerWindow(_ windowID: String, scene: UIWindowScene) {
        windows.register(windowID: windowID, scene: scene)
        var sessions = defaults.dictionary(forKey: Self.windowSessionsKey) as? [String: String] ?? [:]
        // Retain only live/restorable scene sessions; no unbounded scene history.
        let live = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        sessions = sessions.filter { live.contains($0.value) }
        sessions[windowID] = scene.session.persistentIdentifier
        defaults.set(sessions, forKey: Self.windowSessionsKey)
    }

    func claimNavigation(_ activity: NSUserActivity, windowID: String) {
        guard activity.activityType == Self.navigationActivity,
              let id = activity.userInfo?["navigation_id"] as? String,
              var navigation = pendingNavigation, navigation.id.uuidString == id,
              navigation.windowID == nil || navigation.windowID == windowID else { return }
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

    private func notifyChange() { changeCount += 1 }

    private func persistOptOuts() { defaults.set(optOuts.sorted(), forKey: Self.optOutsKey) }

    func persistRecords() { defaults.set(try? JSONEncoder().encode(records), forKey: Self.recordsKey) }
}

extension PushCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return await presentationOptions(userInfo: notification.request.content.userInfo)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let url = info[PushMessage.urlKey] as? String
        let windowID = PushMessage.delivered(userInfo: info)?.metadata?.windowID
        handleNotificationTap(urlString: url, windowID: windowID, completionHandler: completionHandler)
    }

    /// Use the completion-handler delegate API so UIKit's completion runs on the
    /// main thread too. The async delegate's generated thunk can resume on a
    /// worker thread after our actor hop and crash UIKit's state restoration.
    nonisolated func handleNotificationTap(urlString: String?, windowID: String? = nil, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            open(urlString: urlString, configuredServer: ServerAddress.parse(defaults.string(forKey: "serverURL") ?? ""), windowID: windowID)
            completionHandler()
        }
    }
}
