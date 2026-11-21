import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The Music screen: what's playing and the playlists saved on this device.
struct MusicView: View {
    let library: MusicLibrary
    /// Persistent destinations keep their navigation stack but omit sheet dismissal.
    var embedded = false
    /// Hide native chrome while this persistent destination is inactive.
    var isActive: Bool = true
    /// Quiet root chrome for the large-screen workspace; phones keep system chrome.
    var usesWorkspaceChrome: Bool = false
    var onToggleSidebar: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var failure: String?

    private var player: MusicPlayer { library.player }

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
            .navigationDestination(for: UUID.self) {
                PlaylistDetailView(library: library, playlistID: $0)
                    .navigationBarVisibility(isActive ? .visible : .hidden)
            }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create", action: create)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't Update Playlists", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .animation(.snappy(duration: 0.25), value: player.nowPlaying)
            .musicNotices(player)
            .onAppear {
                if isActive {
                    library.refreshAccess()
                    player.connect()
                }
                library.store.reloadIfReadOnly()
            }
            .onChange(of: isActive) { _, active in
                if active {
                    library.refreshAccess()
                    player.connect()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if isActive && phase == .active { library.refreshAccess() }
            }
        }
    }

    @ViewBuilder private var rootContent: some View {
        if usesWorkspaceChrome {
            libraryList
                .navigationBarVisibility(.hidden)
                .workspaceTopBar {
                    WorkspaceHeader(title: "Music", onToggleSidebar: onToggleSidebar) {
                        if !embedded {
                            Button("Done") { dismiss() }
                        }
                        newPlaylistButton
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("musicWorkspaceHeader")
                }
        } else {
            libraryList
                .navigationBarVisibility(isActive ? .visible : .hidden)
                .toolbar {
                    if !embedded {
                        ToolbarItem(placement: .platformLeading) {
                            Button("Done") { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .platformTrailing) {
                        newPlaylistButton
                    }
                }
        }
    }

    private var libraryList: some View {
        List {
            storageSection
            if library.access != .authorized { accessSection }
            if let track = player.nowPlaying { nowPlayingSection(track) }
            playlistsSection
        }
        .modifier(WorkspaceListWidth(enabled: AppPlatform.isMac))
        .accessibilityIdentifier("musicScreen")
        .navigationTitle("Music")
    }

    private var newPlaylistButton: some View {
        Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
            .accessibilityLabel("New Playlist")
    }

    // MARK: Sections

    /// Explains playlists that couldn't be fully loaded or saved.
    @ViewBuilder private var storageSection: some View {
        if let reason = library.store.readOnlyReason {
            Section {
                Label(reason, systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        if let notice = library.store.notice {
            Section {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                Button("OK") { library.store.dismissNotice() }
            }
        }
    }

    private var accessSection: some View {
        Section {
            MusicAccessHint(library: library)
        }
    }

    private func nowPlayingSection(_ track: MusicTrack) -> some View {
        Section("Now Playing") {
            HStack(spacing: 12) {
                ArtworkView(url: track.artworkURL, size: 56, highlighted: player.isPlaying)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(1)
                    if let artist = track.artist {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let playlist = activePlaylist {
                        HStack(spacing: 4) {
                            Image(systemName: "music.note.list")
                            Text(playlist.name).lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("From \(playlist.name)")
                    }
                }
                Spacer(minLength: 8)
                TransportControls(player: player)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if let active = activePlaylist { path = [active.id] }
            }
        }
    }

    private var playlistsSection: some View {
        Section("Playlists") {
            if library.store.playlists.isEmpty {
                if AppPlatform.isMac {
                    ContentUnavailableView {
                        Label("No Playlists", systemImage: "music.note.list")
                    } description: {
                        Text("Create a playlist, or ask the agent to make one.")
                    } actions: {
                        Button("New Playlist") { newName = ""; creating = true }
                            .accessibilityIdentifier("music.empty.newPlaylist")
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView("No Playlists", systemImage: "music.note.list",
                                           description: Text("Tap + to make one, or ask the agent to."))
                }
            }
            ForEach(library.store.playlists) { playlist in
                NavigationLink(value: playlist.id) { PlaylistRow(playlist: playlist, player: player) }
                    .contextMenu {
                        Button { play(playlist, shuffle: false) } label: { Label("Play", systemImage: "play.fill") }
                        Button { play(playlist, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                        Button(role: .destructive) { delete(playlist) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            .onDelete { offsets in
                offsets.map { library.store.playlists[$0] }.forEach(delete)
            }
        }
    }

    // MARK: Actions

    private var activePlaylist: Playlist? {
        library.store.playlists.first { player.isActive($0) }
    }

    private func create() {
        do {
            let playlist = try library.store.create(name: newName)
            path = [playlist.id]
        } catch {
            failure = error.localizedDescription
        }
    }

    private func delete(_ playlist: Playlist) {
        do { try library.store.delete(playlist.id) } catch { failure = error.localizedDescription }
    }

    private func play(_ playlist: Playlist, shuffle: Bool) {
        Task { try? await player.play(playlist, shuffle: shuffle) }
    }
}

/// Appearing or refreshing this hint never prompts. Its explicit Connect action
/// requests access; catalog operations can also request it when undetermined.
/// Restricted devices have no misleading retry button.
struct MusicAccessHint: View {
    let library: MusicLibrary
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let guidance = library.access.guidance {
            VStack(alignment: .leading, spacing: 8) {
                Text(guidance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let title = library.access.actionTitle {
                    Button(title) {
                        if library.access == .notDetermined {
                            Task { await library.requestAccess() }
                        } else if library.access == .denied, let url = NativeApp.appSettingsURL {
                            openURL(url)
                        }
                    }
                    .disabled(library.isRequestingAccess)
                }
            }
            .accessibilityIdentifier("musicAccessHint")
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let player: MusicPlayer

    var body: some View {
        let active = player.isActive(playlist)
        HStack(spacing: 12) {
            ArtworkView(url: playlist.artworkURL, size: 48, highlighted: active && player.isPlaying)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).lineLimit(1)
                Text(playlist.songCountText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if active { PlayingBars(animating: player.isPlaying) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(active ? (player.isPlaying ? "Playing" : "Paused") : "")
    }
}
