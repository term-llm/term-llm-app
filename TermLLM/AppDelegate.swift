import UIKit
import UserNotifications

/// Receives the APNs device token and routes notification presentation/taps
/// to `PushCenter`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NativeResponsivenessWatchdog.shared.start()
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
