import AppKit
import Combine
import Sparkle
import SwiftUI

/// App-bundle updates only. CLI updates, launchd services and login registration
/// remain independently owned by MacLocalServiceController. Sparkle's normal
/// application termination runs its existing Computer Use shutdown observer.
@MainActor
final class AppUpdateController: NSObject, ObservableObject {
    static let shared = AppUpdateController()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    private(set) var controller: SPUStandardUpdaterController?
    let disabledReason: String?
    let isLocalTestFeed: Bool
    private var observations: [NSKeyValueObservation] = []

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:], suppressed: Bool? = nil) {
        disabledReason = AppUpdatePolicy.disabledReason(
            info: info, suppressed: suppressed ?? (HubFixture.isEnabled || PhoneHubFixture.isEnabled
                || MacLocalServiceBridge.isHostedTestRun))
        isLocalTestFeed = (info["SUFeedURL"] as? String) != AppUpdatePolicy.productionFeed
        super.init()
        #if DEBUG
        if let disabledReason { NSLog("%@", disabledReason) }
        #endif
    }

    func start() {
        guard disabledReason == nil, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // Never honor legacy/defaults feed overrides; only the validated plist
        // build setting above may select the feed, including in local demos.
        _ = controller.updater.clearFeedURLFromUserDefaults()
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
            }
        ]
        controller.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(sender)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    @objc private func toggleAutomaticChecks() {
        setAutomaticChecks(!automaticallyChecksForUpdates)
    }

    /// Separate from Local Service's CLI update controls, including for installs
    /// that never provision a CLI. Omit all controls when configuration is unsafe.
    func addMenuItems(to menu: NSMenu) {
        if let disabledReason {
            let unavailable = NSMenuItem(title: "App Updates Unavailable", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            unavailable.toolTip = disabledReason
            menu.addItem(unavailable)
            return
        }
        menu.addItem(.separator())
        let group = NSMenuItem(title: isLocalTestFeed ? "App Updates (Local Test)" : "App Updates", action: nil, keyEquivalent: "")
        let updates = NSMenu()
        updates.autoenablesItems = false
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        check.target = self
        check.isEnabled = canCheckForUpdates
        updates.addItem(check)
        let automatic = NSMenuItem(title: "Automatically Check for App Updates", action: #selector(toggleAutomaticChecks), keyEquivalent: "")
        automatic.target = self
        automatic.state = automaticallyChecksForUpdates ? .on : .off
        automatic.isEnabled = controller != nil
        updates.addItem(automatic)
        group.submenu = updates
        menu.addItem(group)
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject var updates: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updates.disabledReason == nil {
                Button(updates.isLocalTestFeed ? "Check for Updates… (Local Test)" : "Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
                Toggle("Automatically Check for App Updates", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.setAutomaticChecks($0) }))
                .disabled(updates.controller == nil)
                Divider()
            } else if let reason = updates.disabledReason {
                Button("App Updates Unavailable") {}
                    .disabled(true)
                    .help(reason)
            }
        }
    }
}
