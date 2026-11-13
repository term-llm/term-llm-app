import ComputerUseCore
import ComputerUseSystem
import Darwin
import Foundation

/// The LSUIElement app's startup owns all grant-bearing and AppKit primitives.
/// Kept out of the main app and client, which must never become TCC principals.
public enum ComputerUseRuntime {
    public static let grantNames: [Permissions.Kind: String] = [
        .accessibility: "Accessibility", .screenRecording: "Screen Recording",
        .inputMonitoring: "Input Monitoring", .postEvents: "Event Posting",
    ]
    /// Call on the main thread: it becomes the helper's AppKit loop.
    @MainActor
    public static func run() -> Never {
        AX.backend = SystemAX()
        var dependencies = HarnessExecutor.Dependencies()
        let permissions = dependencies.permissions
        let screenshot = dependencies.screenshot
        let pasteboard = dependencies.actions.system.pasteboard
        pasteboard.restoreSaved()  // crash recovery must precede serving requests
        let policy = dependencies.policy
        var actionsSystem = dependencies.actions.system
        actionsSystem.checkRecipient = { try policy.checkRecipient($0) }
        dependencies.actions = Actions(system: actionsSystem)
        // Person.shared composes its immutable Presence hook at construction;
        // Focus and the executor must continue to observe the same Person.
        let executor = HarnessExecutor(dependencies: dependencies)
        var configuration = HelperConfiguration(
            grants: {
                let status = permissions.status()
                return Dictionary(
                    uniqueKeysWithValues: grantNames.map {
                        ($0.value, status[$0.key.rawValue] == true)
                    })
            },
            allow: { name in
                guard let kind = grantNames.first(where: { $0.value == name })?.key else {
                    throw Errors.serverError("Unknown permission name.")
                }
                permissions.openSettings(kind)  // marshals request + pane to helper main
            })
        configuration.onStarted = {
            Person.shared.startWatch(ownPID: getpid())
            Apps.shared.prewarm()
        }
        // HelperMain's two-second maintenance timer owns cleanup; Screenshot
        // applies its own one-hour expiry (kept proof is outside this cache).
        configuration.onMaintenance = { screenshot.cleanup() }
        configuration.wantsRelaunch = { permissions.wantsRelaunch() }
        configuration.onWorking = { ActivityBanner.shared.update(working: $0) }
        configuration.installStop = { ActivityBanner.shared.onStop = $0 }
        HelperMain.run(executor: executor, configuration: configuration)
    }
}
