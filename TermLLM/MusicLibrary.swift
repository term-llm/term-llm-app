import Foundation
import Observation

/// Wires the music feature together once: playlists, Apple Music, the player,
/// and the agent's tools all share the same state.
@MainActor
@Observable
final class MusicLibrary {
    static let shared = MusicLibrary(catalog: AppleMusicCatalog(), engine: AppleMusicEngine(), store: PlaylistStore())

    let store: PlaylistStore
    let player: MusicPlayer
    let catalog: MusicCatalog
    /// Whether this app may use Apple Music; playlists work either way.
    private(set) var access: MusicAccess

    @ObservationIgnored private let toolbox: MusicTools

    init(catalog: MusicCatalog, engine: MusicPlaybackEngine, store: PlaylistStore,
         defaults: UserDefaults = .standard, startCheck: MusicPlayer.StartCheck = MusicPlayer.StartCheck()) {
        self.catalog = catalog
        self.store = store
        self.player = MusicPlayer(engine: engine, defaults: defaults, startCheck: startCheck)
        self.access = catalog.access()
        self.toolbox = MusicTools(store: store, catalog: catalog, player: player)
    }

    var tools: [DeviceTool] { toolbox.tools }

    func refreshAccess() {
        access = catalog.access()
    }

    func requestAccess() async {
        access = await catalog.requestAccess()
    }
}
