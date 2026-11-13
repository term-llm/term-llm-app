import Foundation
import Observation

/// Wires the music feature together once: playlists, Apple Music, the player,
/// and the agent's tools all share the same state.
@MainActor
@Observable
final class MusicLibrary {
    static let shared: MusicLibrary = {
        let library = MusicLibrary(catalog: AppleMusicCatalog(), engine: AppleMusicEngine(), store: PlaylistStore())
        // Artwork saved for songs no playlist holds any more (search results,
        // songs played from elsewhere) goes; the rest stays on the phone.
        ListenArtworkStore.music.prune(keepingURLs: library.store.playlists.flatMap { $0.tracks.compactMap(\.artworkURL) })
        return library
    }()

    let store: PlaylistStore
    let player: MusicPlayer
    let catalog: MusicCatalog
    /// Whether this app may use Apple Music; playlists work either way.
    private(set) var access: MusicAccess
    private(set) var isRequestingAccess = false

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
        guard !isRequestingAccess else { return }
        refreshAccess()
        guard access == .notDetermined else { return }
        isRequestingAccess = true
        defer {
            isRequestingAccess = false
            refreshAccess()
        }
        _ = await catalog.requestAccess()
    }
}

extension ListenArtworkStore {
    /// Apple Music artwork, in a folder of its own. It's public: never
    /// fetched with cookies.
    static let music = ListenArtworkStore(
        directory: URL.applicationSupportDirectory.appending(path: "Music/Artwork", directoryHint: .isDirectory),
        cookies: nil, server: { nil })
}
