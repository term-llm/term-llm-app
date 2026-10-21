import SwiftUI

@main
struct TermLLMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Listen.connectToMusic(MusicLibrary.shared.player, listen: .shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
