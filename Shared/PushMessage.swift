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
        let plaintext = try WebPushCrypto.decrypt(body, privateKey: identity.agreementKey(), authSecret: identity.authSecret)
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw Failure.invalidMessage
        }
        let origin = (envelope["k"] as? String).flatMap { identity.routes[$0] }
        return message(from: object, origin: origin)
    }

    static func message(from object: [String: Any], origin: String?) -> PushMessage {
        func text(_ key: String) -> String? {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let session = text("session_id")
        return PushMessage(
            title: text("title") ?? "term-llm",
            body: text("body") ?? "",
            threadIdentifier: [origin, session].compactMap { $0 }.joined(separator: "#").nilIfEmpty ?? "term-llm",
            url: text("url").flatMap { resolve(path: $0, origin: origin) },
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
