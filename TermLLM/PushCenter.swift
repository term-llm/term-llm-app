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
    /// The page currently shown, for suppressing alerts about it.
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
    private var records: [String: Record]
    private var deviceToken: String?
    private var tokenWaiters: [CheckedContinuation<String, Error>] = []
    private var tokenTimeoutTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         identities: PushIdentityStore = PushIdentityStore(),
         authorizer: PushAuthorizer = SystemPushAuthorizer(),
         relayTransport: @escaping PushRelayClient.Transport = PushRelayClient.defaultTransport,
         registerForRemote: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
         environment: PushEnvironment = .current,
         tokenTimeout: Duration = .seconds(20)) {
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
        } else if enabled {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            notifyChange()
        }
    }

    private func turnOn() async {
        let wasEnabled = enabled
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
        if optOuts.remove(Self.scopeKey(origin: origin, scope: scope)) != nil { persistOptOuts() }
        await turnOn()
        return permission(origin: origin, scope: scope)
    }

    func subscription(origin: String, scope: String, label: String? = nil, nodeBasePath: String? = nil) -> NativePushSubscription? {
        guard permission(origin: origin, scope: scope) == .granted,
              let record = records[Self.scopeKey(origin: origin, scope: scope)],
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
        guard let rawKey = Data(base64URLEncoded: applicationServerKey), rawKey.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: rawKey)) != nil else { throw PushError.invalidServerKey }
        guard let relay = relayURL else { throw PushError.relayUnavailable }
        let identity: PushIdentity
        do { identity = try identities.loadOrCreate() } catch { throw PushError.keychain }
        let token = try await currentDeviceToken()
        let key = rawKey.base64URLEncodedString()
        let endpoint = try await PushRelayClient(baseURL: relay, transport: relayTransport)
            .register(deviceToken: token, environment: environment, applicationServerKey: key)
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
        if records.removeValue(forKey: Self.scopeKey(origin: origin, scope: scope)) != nil { persistRecords() }
    }

    /// The user turned notifications off for this node in its web UI.
    func disable(origin: String, scope: String) {
        let key = Self.scopeKey(origin: origin, scope: scope)
        if optOuts.insert(key).inserted { persistOptOuts() }
        unsubscribe(origin: origin, scope: scope)
    }

    // MARK: Notifications shown and tapped

    func presentationOptions(forURL raw: String?) -> UNNotificationPresentationOptions {
        if isActive(), let raw, let target = URL(string: raw), let visible = visibleURL,
           Self.samePage(target, visible) { return [] }
        return [.banner, .list, .sound]
    }

    func open(urlString raw: String?, configuredServer: URL?) {
        guard let raw, let url = URL(string: raw), let server = configuredServer,
              let origin = Self.origin(url), origin == Self.origin(server) else { return }
        pendingNavigation = PushNavigation(id: UUID(), url: url)
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

    private func notifyChange() { changeCount += 1 }

    private func persistOptOuts() { defaults.set(optOuts.sorted(), forKey: Self.optOutsKey) }

    private func persistRecords() { defaults.set(try? JSONEncoder().encode(records), forKey: Self.recordsKey) }
}

extension PushCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let url = notification.request.content.userInfo[PushMessage.urlKey] as? String
        return await presentationOptions(forURL: url)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let url = response.notification.request.content.userInfo[PushMessage.urlKey] as? String
        handleNotificationTap(urlString: url, completionHandler: completionHandler)
    }

    /// Use the completion-handler delegate API so UIKit's completion runs on the
    /// main thread too. The async delegate's generated thunk can resume on a
    /// worker thread after our actor hop and crash UIKit's state restoration.
    nonisolated func handleNotificationTap(urlString: String?, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            open(urlString: urlString, configuredServer: ServerAddress.parse(defaults.string(forKey: "serverURL") ?? ""))
            completionHandler()
        }
    }
}
