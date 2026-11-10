import AppKit
import SwiftUI

/// The native macOS client: the same Agents, Chat, Music and Podcasts as the
/// iPhone/iPad app, built on AppKit WebKit so Chat has microphone capture.
@main
struct TermLLMMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    init() {
        Listen.connectToMusic(MusicLibrary.shared.player, listen: .shared)
    }

    var body: some Scene {
        // One client window. Notification routing and voice/listen ownership
        // assume a single scene (NOTIFICATION-OWNERSHIP.md); unlike
        // WindowGroup, `Window` never offers New Window or window tabs.
        Window("term-llm", id: "main") {
            if MacLocalServiceBridge.isHostedTestRun {
                // The unit-test host is this app, with its defaults and
                // keychain: it must not open the developer's connections.
                Text("Running unit tests")
                    .frame(minWidth: 320, minHeight: 200)
            } else {
                ContentView()
                    .frame(minWidth: 820, minHeight: 560)
                    // Settings-style forms read like iPhone/iPad, not as two columns.
                    .formStyle(.grouped)
            }
        }
        .defaultSize(width: 1180, height: 800)
        // The selector identifies the destination. Never show a stale title
        // contributed by one of the retained, currently hidden native pages.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            MacCommands(center: DesktopCommandCenter.shared, window: MacClientWindow.shared,
                        localService: MacLocalServiceBridge.shared)
        }
    }
}
