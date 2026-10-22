import Foundation

/// A term-llm notification decrypted from a relayed APNs payload:
///
///     { "aps": {...}, "webpush": { "v": 1, "ce": "aes128gcm", "k": "<source tag>", "body": "<base64>" } }
///
/// The decrypted body is term-llm's Web Push JSON: completion pushes carry
/// title, body, url, session_id and event_id; `term-llm notify` sends title
/// and body.
struct PushMessage: Equatable {
    static let urlKey = "termllm_url"
    static let originKey = "termllm_origin"

    var title: String
    var body: String
    /// Groups notifications per chat (or per server when there is no chat).
    var threadIdentifier: String
    /// Absolute page to open on tap; always on `origin`.
    var url: URL?
    /// Server the push came from, when this device registered its source tag.
    var origin: String?

    enum Failure: Error, Equatable {
        case notWebPush
        case noIdentity
        case invalidMessage
    }

    static func decode(userInfo: [AnyHashable: Any], identity: PushIdentity?) throws -> PushMessage {
        guard let envelope = userInfo["webpush"] as? [String: Any],
              (envelope["v"] as? NSNumber)?.intValue == 1,
              (envelope["ce"] as? String) == "aes128gcm",
              let encoded = envelope["body"] as? String,
              let body = Data(base64Encoded: encoded) else { throw Failure.notWebPush }
        guard let identity else { throw Failure.noIdentity }
        let tag = envelope["k"] as? String
        let candidates = (identity.scopedRoutes ?? [:]).filter { $0.value.tag == tag }
        let privateKey = try identity.agreementKey()
        // The successful authentication secret identifies the enrollment even
        // when Dev and Hub share both an origin and a VAPID source tag.
        for (id, candidate) in candidates {
            guard let plaintext = try? WebPushCrypto.decrypt(body, privateKey: privateKey,
                                                            authSecret: identity.authenticationSecret(routeID: id)) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
                throw Failure.invalidMessage
            }
            let route = candidate.route
            return message(from: object, origin: candidate.origin, scope: route.scope,
                           label: route.label, nodeBasePath: route.nodeBasePath)
        }
        // Keep already-sent and pre-upgrade subscriptions readable. A legacy
        // ciphertext cannot distinguish multiple scopes sharing its key; do not
        // mislabel it or guess the last page visited in that case.
        let plaintext = try WebPushCrypto.decrypt(body, privateKey: privateKey, authSecret: identity.authSecret)
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw Failure.invalidMessage
        }
        let origins = Set(candidates.values.map { $0.origin })
        let origin = origins.count > 1 ? nil : tag.flatMap { identity.routes[$0] }
        let route = candidates.count > 1 ? nil : tag.flatMap { identity.routeDetails?[$0] }
        return message(from: object, origin: origin, scope: route?.scope, label: route?.label, nodeBasePath: route?.nodeBasePath)
    }

    static func message(from object: [String: Any], origin: String?, scope: String? = nil, label: String? = nil, nodeBasePath: String? = nil) -> PushMessage {
        func text(_ key: String) -> String? {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let session = text("session_id")
        var title = text("title") ?? "term-llm"
        if origin != nil, let label, !label.isEmpty {
            if title == "term-llm" {
                title = label
            } else if title.caseInsensitiveCompare(label) != .orderedSame,
                      !title.lowercased().hasPrefix(label.lowercased() + ":") {
                title = label + ": " + title
            }
        }
        // CLI notifications omit the URL. Like a browser service worker, fall
        // back to the enrolled node's scope, not the app's configured hub URL.
        var path = text("url") ?? scope.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        if let scope, let nodeBasePath, let raw = path,
           raw.hasPrefix("/"), !raw.hasPrefix("//") {
            let mount = scope.hasSuffix("/") ? String(scope.dropLast()) : scope
            let base = nodeBasePath.hasSuffix("/") ? String(nodeBasePath.dropLast()) : nodeBasePath
            // A completion sender knows its local /ui prefix, not the hub's
            // public /node/Dev mount. Never rebase an already-public URL.
            if raw != mount && !raw.hasPrefix(mount + "/"),
               raw == base || raw.hasPrefix(base + "/") {
                path = mount + raw.dropFirst(base.count)
            }
        }
        return PushMessage(
            title: title,
            body: text("body") ?? "",
            threadIdentifier: [origin, session].compactMap { $0 }.joined(separator: "#").nilIfEmpty ?? "term-llm",
            url: path.flatMap { resolve(path: $0, origin: origin) },
            origin: origin
        )
    }

    /// Accepts only a same-origin absolute path; never a full URL from the payload.
    static func resolve(path: String, origin: String?) -> URL? {
        guard let origin, path.hasPrefix("/"), !path.hasPrefix("//"),
              let base = URL(string: origin), let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else { return nil }
        return url
    }

    var userInfo: [String: String] {
        var info: [String: String] = [:]
        if let url { info[Self.urlKey] = url.absoluteString }
        if let origin { info[Self.originKey] = origin }
        return info
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if canImport(UserNotifications)
import UserNotifications

extension PushMessage {
    /// What the Notification Service Extension delivers: the decrypted
    /// notification. Throws to keep the relay's placeholder.
    static func content(for request: UNNotificationRequest, identities: PushIdentityStore = PushIdentityStore()) throws -> UNNotificationContent {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { throw Failure.invalidMessage }
        let message = try decode(userInfo: request.content.userInfo, identity: identities.load())
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = message.threadIdentifier
        var userInfo = content.userInfo
        userInfo.removeValue(forKey: "webpush")
        for (key, value) in message.userInfo { userInfo[key] = value }
        content.userInfo = userInfo
        return content
    }
}
#endif
