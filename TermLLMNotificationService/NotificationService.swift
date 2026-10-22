import Foundation
import OSLog
import UserNotifications

private let log = Logger(subsystem: "com.termllm.app", category: "push")

/// Decrypts relayed Web Push messages on the device. The relay only ever sees
/// ciphertext; if decryption fails the relay's placeholder alert is shown.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?
    private let completionLock = NSLock()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Install a quiet fallback BEFORE shared-state IO: a competing process
        // may hold the file lock when iOS asks this extension to expire.
        completionLock.withLock {
            self.contentHandler = contentHandler
            fallback = Self.quiet(request.content)
        }
        let permitted = (try? PushDeliveryStore().isEnabled(origin: nil, scope: nil)) == true
        do {
            deliver(try PushMessage.content(for: request))
        } catch {
            // Never log content; the failure kind is enough to diagnose.
            log.error("Unable to decode notification: \(String(describing: error), privacy: .public)")
            let invalid = error as? PushMessage.Failure == .invalidMessage
            deliver(!permitted || invalid ? Self.quiet(request.content) : request.content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback = completionLock.withLock({ fallback }) { deliver(fallback) }
    }

    private static func quiet(_ original: UNNotificationContent) -> UNNotificationContent {
        guard let content = original.mutableCopy() as? UNMutableNotificationContent else { return original }
        content.title = ""; content.subtitle = ""; content.body = ""
        content.sound = nil; content.badge = nil; content.interruptionLevel = .passive
        return content
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler = completionLock.withLock { () -> ((UNNotificationContent) -> Void)? in
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(content)
    }
}
