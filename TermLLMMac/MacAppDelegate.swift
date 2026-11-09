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
        // Device/app CPU and thermal history, plus the chat page's own reports.
        WebKitHealthMonitor.shared.start()
        PushCenter.shared.applicationDidLaunch()
        MacLocalServiceBridge.shared.start()
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
