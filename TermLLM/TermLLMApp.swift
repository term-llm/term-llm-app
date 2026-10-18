import SwiftUI

@main
struct TermLLMApp: App {
    init() {
        Listen.connectToMusic(MusicLibrary.shared.player, listen: .shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
