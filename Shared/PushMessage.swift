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
    static let scopeKey = "termllm_scope"
    static let sourceKey = "termllm_source"
    static let dispositionKey = "termllm_disposition"
    static let decodedKey = "termllm_decoded"

    var title: String
    var body: String
    /// Groups notifications per chat (or per server when there is no chat).
    var threadIdentifier: String
    /// Absolute page to open on tap; always on `origin`.
    var url: URL?
    /// Server the push came from, when this device registered its source tag.
    var origin: String?
    /// Origin/scope/source come from successful enrollment authentication, never
    /// from a payload claiming to belong to another node.
    var scope: String?
    var sourceID: String?
    var metadata: PushMetadata?

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
            _ = try PushMetadata.parse(object)
            let route = candidate.route
            let message = message(from: object, origin: candidate.origin, scope: route.scope,
                                  label: route.label, nodeBasePath: route.nodeBasePath, sourceID: id)
            try validateCompletionRoute(message, authenticated: true)
            return message
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
        _ = try PushMetadata.parse(object)
        let message = message(from: object, origin: origin, scope: route?.scope, label: route?.label, nodeBasePath: route?.nodeBasePath, sourceID: tag)
        try validateCompletionRoute(message, authenticated: false)
        return message
    }

    private static func validateCompletionRoute(_ message: PushMessage, authenticated: Bool) throws {
        guard let metadata = message.metadata, metadata.version == 2, metadata.kind == "completion" else { return }
        guard authenticated, message.origin != nil, let scope = message.scope,
              metadata.source == scope, let url = message.url else { throw Failure.invalidMessage }
        let decoded = scope.removingPercentEncoding ?? scope
        let root = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
        guard PushMetadata.validScope(url.path),
              root.isEmpty || url.path == root || url.path.hasPrefix(root + "/") else { throw Failure.invalidMessage }
    }

    static func message(from object: [String: Any], origin: String?, scope: String? = nil, label: String? = nil, nodeBasePath: String? = nil, sourceID: String? = nil) -> PushMessage {
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
            body: object["body"] as? String ?? "",
            threadIdentifier: [origin, scope, session].compactMap { $0 }.joined(separator: "#").nilIfEmpty ?? "term-llm",
            url: path.flatMap { resolve(path: $0, origin: origin) },
            origin: origin, scope: scope, sourceID: sourceID,
            metadata: try? PushMetadata.parse(object)
        )
    }

    /// Accepts only a same-origin absolute path; never a full URL from the payload.
    static func resolve(path: String, origin: String?) -> URL? {
        guard let origin, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let base = URL(string: origin), let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else { return nil }
        return url
    }

    var userInfo: [String: String] {
        var info: [String: String] = [Self.decodedKey: "1"]
        if let url { info[Self.urlKey] = url.absoluteString }
        if let origin { info[Self.originKey] = origin }
        if let scope { info[Self.scopeKey] = scope }
        if let sourceID { info[Self.sourceKey] = sourceID }
        if let metadata, let data = try? JSONEncoder().encode(metadata) {
            info[PushMetadata.key] = String(decoding: data, as: UTF8.self)
        }
        return info
    }

    /// Delivered metadata must survive after NSE removes the encrypted body.
    static func delivered(userInfo: [AnyHashable: Any]) -> PushMessage? {
        let origin = userInfo[originKey] as? String
        guard origin != nil || userInfo[decodedKey] as? String == "1" else { return nil }
        let metadata = (userInfo[PushMetadata.key] as? String).flatMap {
            try? JSONDecoder().decode(PushMetadata.self, from: Data($0.utf8))
        }
        if userInfo[PushMetadata.key] != nil, metadata == nil { return nil }
        let url = (userInfo[urlKey] as? String).flatMap(URL.init(string:))
        return PushMessage(title: "", body: "", threadIdentifier: "", url: url, origin: origin,
                           scope: userInfo[scopeKey] as? String, sourceID: userInfo[sourceKey] as? String,
                           metadata: metadata)
    }

    func isRead(origin: String, scope: String, store: String, session: String, through sequence: Int64) -> Bool {
        self.origin == origin && self.scope == scope && metadata?.kind == "completion" &&
            metadata?.storeInstanceID == store && metadata?.sessionID == session &&
            metadata?.attentionSequence.map { $0 <= sequence } == true
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if canImport(UserNotifications)
import UserNotifications

extension PushMessage {
    /// What the Notification Service Extension delivers: the decrypted
    /// notification. Unclassified content throws; the NSE supplies quiet fallback.
    static func content(for request: UNNotificationRequest, identities: PushIdentityStore = PushIdentityStore(),
                        deliveries: PushDeliveryStore = PushDeliveryStore()) throws -> UNNotificationContent {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { throw Failure.invalidMessage }
        let message = try decode(userInfo: request.content.userInfo, identity: identities.load())
        let disposition = deliveries.admit(message)
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = message.threadIdentifier
        var userInfo = content.userInfo
        userInfo.removeValue(forKey: "webpush")
        for (key, value) in message.userInfo { userInfo[key] = value }
        userInfo[Self.dispositionKey] = disposition.rawValue
        content.userInfo = userInfo
        if disposition != .allowed {
            // NSE cannot cancel a remote alert. Quiet/redact best-effort; iOS
            // may still show an empty card or the original fallback on expiry.
            content.title = ""; content.subtitle = ""; content.body = ""
            content.sound = nil; content.badge = nil
            content.interruptionLevel = .passive
        }
        return content
    }
}
#endif
