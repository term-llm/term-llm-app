import Foundation
import CoreFoundation

/// The authenticated producer's routing/read identity, carried intact into
/// delivered notification userInfo. Enrollment source is NOT taken from JSON.
struct PushMetadata: Codable, Equatable {
    static let key = "termllm_metadata"
    var version: Int
    var kind: String
    var eventID: String?
    var turnID: String?
    var responseID: String?
    var windowID: String?
    var storeInstanceID: String?
    var sessionID: String?
    var attentionSequence: Int64?
    var runEpoch: Int64?
    var source: String?
    var outcome: String?
    var createdAt: Date?
    var expiresAt: Date?

    static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return text
    }

    static func sequence(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.int64Value
    }

    static func parse(_ object: [String: Any]) throws -> PushMetadata? {
        let completionKeys = ["event_id", "turn_id", "response_id", "window_id", "store_instance_id", "session_id", "attention_seq", "outcome", "run_epoch"]
        if object["version"] == nil, object["kind"] == nil,
           !completionKeys.contains(where: { object[$0] != nil }) { return nil } // legacy manual ONLY
        guard let version = sequence(object["version"]) else { throw PushMessage.Failure.invalidMessage }
        if version == 1, object["kind"] == nil || object["kind"] as? String == "completion" {
            // Previously accepted pushes only. Never advertise old eligibility.
            guard let event = identifier(object["event_id"]), let session = identifier(object["session_id"]),
                  ["completed", "failed"].contains(object["outcome"] as? String ?? "") else { throw PushMessage.Failure.invalidMessage }
            return PushMetadata(version: 1, kind: "completion", eventID: event,
                                responseID: identifier(object["response_id"]), sessionID: session,
                                outcome: object["outcome"] as? String)
        }
        guard version == 2, let kind = object["kind"] as? String, ["completion", "manual"].contains(kind),
              let event = identifier(object["event_id"]),
              let created = (object["created_at"] as? String).flatMap(date),
              let expires = (object["expires_at"] as? String).flatMap(date),
              expires > created, expires.timeIntervalSince(created) <= PushDeliveryStore.horizon else {
            throw PushMessage.Failure.invalidMessage
        }
        var metadata = PushMetadata(version: 2, kind: kind, eventID: event,
            turnID: identifier(object["turn_id"]), responseID: identifier(object["response_id"]),
            windowID: identifier(object["window_id"]), storeInstanceID: identifier(object["store_instance_id"]),
            sessionID: identifier(object["session_id"]), attentionSequence: sequence(object["attention_seq"]),
            runEpoch: sequence(object["run_epoch"]), source: object["source"] as? String,
            outcome: object["outcome"] as? String, createdAt: created, expiresAt: expires)
        if kind == "completion" {
            guard metadata.turnID != nil, metadata.responseID != nil, metadata.windowID != nil,
                  metadata.storeInstanceID != nil, metadata.sessionID != nil,
                  (metadata.attentionSequence ?? 0) > 0, (metadata.runEpoch ?? 0) > 0,
                  let source = metadata.source, validScope(source),
                  ["completed", "failed"].contains(object["outcome"] as? String ?? "") else {
                throw PushMessage.Failure.invalidMessage
            }
        } else {
            // Manual content cannot acquire read/window authority via extra fields.
            metadata.turnID = nil; metadata.responseID = nil; metadata.windowID = nil
            metadata.storeInstanceID = nil; metadata.sessionID = nil
            metadata.attentionSequence = nil; metadata.runEpoch = nil; metadata.outcome = nil
        }
        return metadata
    }

    static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 64 else { return nil }
        // Core emits RFC3339Nano. Normalize fractional widths defensively to
        // explicit milliseconds; this adds no tolerance to the 24h horizon.
        var input = text
        if let dot = text.firstIndex(of: ".") {
            let fraction = text[text.index(after: dot)...].prefix(while: { $0 >= "0" && $0 <= "9" })
            if !fraction.isEmpty {
                let milliseconds = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
                input = String(text[...dot]) + milliseconds + String(text[fraction.endIndex...])
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: input) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: input)
    }

    static func validScope(_ scope: String) -> Bool {
        guard scope.utf8.count <= 512, scope.isEmpty || scope.hasPrefix("/"),
              let decoded = scope.removingPercentEncoding, !decoded.contains("//"),
              !decoded.contains(where: { "?#\\%".contains($0) }),
              decoded.filter({ $0 == "/" }).count == scope.filter({ $0 == "/" }).count,
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." })
    }
}
