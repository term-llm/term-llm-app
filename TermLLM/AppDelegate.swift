import UIKit
import UserNotifications

/// Receives the APNs device token and routes notification presentation/taps
/// to `PushCenter`.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // UIKit menus/key commands bridge to Designed for iPad on Mac (WWDC21 10056).
    // SwiftUI CommandMenu on iOS only promises key commands, not menu-bar placement.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard ProcessInfo.processInfo.isiOSAppOnMac, builder.system == .main else { return }
        builder.insertSibling(UIMenu(title: "Navigate", identifier: .init("com.termllm.navigate"), children:
            DesktopCommand.tabs.map { $0.keyCommand() } + [DesktopCommand.back.keyCommand()]), afterMenu: .view)
        builder.insertChild(UIMenu(title: "", options: .displayInline,
                                   children: [DesktopCommand.refresh.keyCommand()] + DesktopCommand.zoom.map { $0.keyCommand() }),
                            atEndOfMenu: .view)
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [DesktopCommand.settings.keyCommand()]),
                            atEndOfMenu: .application)
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // UI tests wait for transitions to settle after every tap.
        if PhoneHubFixture.isEnabled { UIView.setAnimationsEnabled(false) }
        guard !HubFixture.isEnabled else { return true }
        // Device/app CPU and thermal history, plus the chat page's own reports.
        WebKitHealthMonitor.shared.start()
        // Must be set before launch finishes to receive the tap that launched the app.
        UNUserNotificationCenter.current().delegate = PushCenter.shared
        PushCenter.shared.applicationDidLaunch()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushCenter.shared.didFailToRegister(error)
    }
}
