import OSLog
import UserNotifications

private let log = Logger(subsystem: "com.termllm.app", category: "push")

/// Decrypts relayed Web Push messages on the device. The relay only ever sees
/// ciphertext; if decryption fails the relay's placeholder alert is shown.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        fallback = request.content
        do {
            deliver(try PushMessage.content(for: request))
        } catch {
            // Never log content; the failure kind is enough to diagnose.
            log.error("Showing placeholder: \(String(describing: error), privacy: .public)")
            deliver(request.content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback { deliver(fallback) }
    }

    private func deliver(_ content: UNNotificationContent) {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }
}
