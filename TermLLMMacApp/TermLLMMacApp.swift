import AppKit
import SwiftUI

@main
struct TermLLMMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = CompanionModel()

    var body: some Scene {
        Window("term-llm", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    model.refreshLoginItemPathIfNeeded()
                    model.startPolling()
                }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Chat") { model.openChat() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Refresh Service Status") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window leaves the menu-bar item (and the service) running.
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
