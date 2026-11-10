import AppKit
import UserNotifications

/// Receives the APNs device token, routes notification presentation and taps
/// to `PushCenter`, and keeps the app (with its retained, hidden window) alive
/// after the window closes. Quit is the only way to end it.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Debug fixtures and the unit-test host never touch production push,
    /// health history or the local service.
    private var isFixture: Bool {
        HubFixture.isEnabled || PhoneHubFixture.isEnabled || MacLocalServiceBridge.isHostedTestRun
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isFixture else { return }
        // Set before launch finishes to receive the tap that launched the app.
        UNUserNotificationCenter.current().delegate = PushCenter.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isFixture else { return }
        AppUpdateController.shared.start()
        // Device/app CPU and thermal history, plus the chat page's own reports.
        WebKitHealthMonitor.shared.start()
        PushCenter.shared.applicationDidLaunch()
        MacLocalServiceBridge.shared.start()
    }

    private var terminationTask: Task<Void, Never>?

    /// Also covers Sparkle's install-on-quit path, for which its optional
    /// postpone-relaunch callback is not guaranteed to run. Sparkle replaces
    /// the app only after this process exits; never acknowledge until safe.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFixture else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor in
            do {
                try await MacLocalServiceController.active?.prepareForTermination()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                MacLocalServiceController.active?.cancelTerminationPreparation()
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = "Could not safely quit for the app update"
                alert.informativeText = error.localizedDescription + "\nNo app replacement was allowed. Let local CLI and Computer Use work finish, then try quitting again."
                alert.runModal()
            }
        }
        return .terminateLater
    }

    /// The menu-bar item and the retained client keep running without a window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon restores the same hidden window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MacClientWindow.shared.show()
        return false
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushCenter.shared.didFailToRegister(error)
    }
}
