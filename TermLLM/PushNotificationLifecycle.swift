import Foundation
import UserNotifications

/// Injectable inbox boundary; tests never touch the system notification center.
protocol PushNotificationInbox {
    func delivered() async -> [UNNotificationRequest]
    func pending() async -> [UNNotificationRequest]
    func removeDelivered(_ ids: [String])
    func removePending(_ ids: [String])
}

struct SystemPushNotificationInbox: PushNotificationInbox {
    func delivered() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request)
    }
    func pending() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
    }
    func removeDelivered(_ ids: [String]) { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
    func removePending(_ ids: [String]) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
}

extension PushCenter {
    func scopeMatchesDocument(origin: String, scope: String, url: URL) -> Bool {
        guard Self.origin(url) == origin, NativePushBridge.scope(scope, contains: url) else { return false }
        let routes = notificationIdentity()?.scopedRoutes?.values ?? Dictionary<String, PushIdentity.ScopedRoute>().values
        // A node page cannot broaden its scope to a same-origin Hub/parent that
        // contains it. Enrollment-authenticated routes survive record cleanup.
        return !routes.contains { route in
            route.origin == origin && route.route.scope.count > scope.count &&
                NativePushBridge.scope(route.route.scope, contains: url)
        }
    }

    func reportStorageFailure() {
        storageIssue = "Shared notification state is unavailable. Automatic completion capability is disabled. Background/in-flight alerts may continue; use iOS Settings to block all alerts. Server cleanup remains pending."
    }

    func refreshPendingCleanup() {
        do { pendingCleanupCount = try deliveries.pending().count }
        catch { reportStorageFailure() }
    }

    func recordEnrollment(origin: String, scope: String, subscriptionID: String) throws {
        let key = Self.scopeKey(origin: origin, scope: scope)
        let rememberedEndpoint = try deliveries.transaction { state in
            let scoped = state.enrollments.filter { $0.origin == origin && $0.scope == scope }
            return scoped.first { $0.subscriptionID == subscriptionID }?.endpoint ??
                scoped.last { $0.subscriptionID == nil }?.endpoint
        }
        let endpoint = records[key]?.endpoint ?? rememberedEndpoint ?? ""
        if records[key]?.endpoint == endpoint { records[key]?.subscriptionID = subscriptionID; persistRecords() }
        try deliveries.remember(origin: origin, scope: scope, endpoint: endpoint, subscriptionID: subscriptionID)
        refreshPendingCleanup()
    }

    func acknowledgeCleanup(origin: String, scope: String, subscriptionID: String) throws {
        let key = Self.scopeKey(origin: origin, scope: scope)
        if records[key]?.subscriptionID == subscriptionID {
            records.removeValue(forKey: key)
            persistRecords()
        }
        try deliveries.acknowledgeCleanup(origin: origin, scope: scope, subscriptionID: subscriptionID)
        refreshPendingCleanup()
    }

    /// Persist the successful server read boundary BEFORE querying the inbox.
    /// An arriving/replayed NSE event then sees the watermark even if it races
    /// these snapshots. A tap or merely opening the page never calls this.
    func acknowledgeRead(origin: String, scope: String, store: String, session: String, sequence: Int64) async throws {
        try deliveries.acknowledgeRead(origin: origin, scope: scope, store: store, session: session, sequence: sequence)
        let delivered = await inbox.delivered()
        let pending = await inbox.pending()
        func matches(_ request: UNNotificationRequest) -> Bool {
            PushMessage.delivered(userInfo: request.content.userInfo)?.isRead(origin: origin, scope: scope,
                store: store, session: session, through: sequence) == true
        }
        inbox.removeDelivered(delivered.filter(matches).map(\.identifier))
        inbox.removePending(pending.filter(matches).map(\.identifier))
    }

    func clearNotifications(origin: String? = nil, scope: String? = nil) async {
        let delivered = await inbox.delivered()
        let pending = await inbox.pending()
        func matches(_ request: UNNotificationRequest) -> Bool {
            guard let origin else { return true } // explicit app-wide off
            let info = request.content.userInfo
            return info[PushMessage.originKey] as? String == origin && info[PushMessage.scopeKey] as? String == scope
        }
        if let origin, let scope {
            guard (try? deliveries.isEnabled(origin: origin, scope: scope)) == false else { return }
        } else { guard !enabled else { return } }
        inbox.removeDelivered(delivered.filter(matches).map(\.identifier))
        inbox.removePending(pending.filter(matches).map(\.identifier))
    }

    func presentationOptions(userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
        guard enabled else { return [] }
        var message = PushMessage.delivered(userInfo: userInfo)
        if userInfo["webpush"] != nil {
            // Most foreground pushes have already passed through NSE. If not,
            // admission here uses the same cross-process ledger.
            message = try? PushMessage.decode(userInfo: userInfo, identity: notificationIdentity())
            guard let message, (try? deliveries.receive(message)) == .allowed else { return [] }
        } else if let status = userInfo[PushMessage.dispositionKey] as? String, status != PushDeliveryStore.Disposition.allowed.rawValue {
            return []
        }
        guard let message, (try? deliveries.isEnabled(origin: message.origin, scope: message.scope)) == true,
              (try? deliveries.hasRead(message)) == false else { return [] }
        if let expires = message.metadata?.expiresAt, expires <= Date() { return [] }
        if let metadata = message.metadata, metadata.kind == "completion", let window = metadata.windowID,
           let origin = message.origin, isActive(), windows.isAround(windowID: window, origin: origin) { return [] }
        return [.banner, .list, .sound]
    }
}
