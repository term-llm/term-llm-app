import CoreFoundation
import Foundation

extension NativePushBridge {
    @MainActor
    static func handleNotification(method: String, object: [String: Any], scope: String, origin: String,
                                   windowID: String?, documentID: String?, center: PushCenter) async -> Result<Any, BridgeError> {
        func failure(_ message: String) -> Result<Any, BridgeError> { .failure(BridgeError(message: message)) }
        guard let windowID, let documentID,
              PushMetadata.identifier(windowID) != nil, PushMetadata.identifier(documentID) != nil,
              object["document_id"] as? String == documentID else {
            return failure("Stale notification document")
        }
        if method == "notificationCapabilities" {
            guard center.storageIssue == nil, center.deliveries.available else {
                return failure("Shared notification state is unavailable")
            }
            center.windows.bind(windowID: windowID, documentID: documentID, origin: origin)
            return .success(["version": 2, "window_id": windowID, "document_id": documentID])
        }
        guard let payload = object["payload"] as? [String: Any], payload["source"] as? String == scope else {
            return failure("Malformed notification scope")
        }
        do {
            switch method {
            case "notificationPresence":
                guard PushMetadata.sequence(payload["version"]) == 2,
                      payload["window_id"] as? String == windowID, payload["document_id"] as? String == documentID,
                      let sequence = PushMetadata.sequence(payload["sequence"]),
                      let active = payload["active"] as? NSNumber, CFGetTypeID(active) == CFBooleanGetTypeID(),
                      let raw = payload["expires_at"] as? String, let expires = PushMetadata.date(raw),
                      center.windows.update(windowID: windowID, documentID: documentID, origin: origin,
                                            sequence: sequence, active: active.boolValue, expires: expires) else {
                    return failure("Invalid or stale notification presence")
                }
                return .success(true)
            case "notificationRead":
                guard PushMetadata.sequence(payload["version"]) == 2,
                      let store = PushMetadata.identifier(payload["store_instance_id"]),
                      let session = PushMetadata.identifier(payload["session_id"]),
                      let sequence = PushMetadata.sequence(payload["attention_seq"]), sequence > 0 else {
                    return failure("Malformed attention acknowledgement")
                }
                try await center.acknowledgeRead(origin: origin, scope: scope, store: store, session: session, sequence: sequence)
                return .success(true)
            case "notificationEnrollment":
                guard let id = PushMetadata.identifier(payload["subscription_id"]) else { return failure("Malformed enrollment") }
                try center.recordEnrollment(origin: origin, scope: scope, subscriptionID: id)
                return .success(true)
            case "notificationPendingCleanup":
                let pending = try center.deliveries.pending(origin: origin, scope: scope)
                return .success(pending.compactMap { record -> [String: String]? in
                    record.subscriptionID.map { ["subscription_id": $0] }
                })
            case "notificationCleanupAcknowledged":
                guard let id = PushMetadata.identifier(payload["subscription_id"]) else { return failure("Malformed cleanup acknowledgement") }
                // Called only after an authenticated server DELETE succeeded.
                try center.acknowledgeCleanup(origin: origin, scope: scope, subscriptionID: id)
                return .success(true)
            default:
                return failure("Unknown notification request")
            }
        } catch {
            center.reportStorageFailure()
            return failure("Could not persist notification state; cleanup remains pending")
        }
    }
}
