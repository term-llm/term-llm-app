import SwiftUI
import UIKit

/// The Music screen: what's playing and the playlists saved on this device.
struct MusicView: View {
    let library: MusicLibrary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var path: [UUID] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var failure: String?

    private var player: MusicPlayer { library.player }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                storageSection
                if library.access != .authorized { accessSection }
                if let track = player.nowPlaying { nowPlayingSection(track) }
                playlistsSection
            }
            .navigationTitle("Music")
            .navigationDestination(for: UUID.self) { PlaylistDetailView(library: library, playlistID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New Playlist")
                }
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
                library.refreshAccess()
                library.store.reloadIfReadOnly()
            }
        }
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

    @ViewBuilder private var accessSection: some View {
        Section {
            if library.access == .notDetermined {
                Button {
                    Task { await library.requestAccess() }
                } label: {
                    Label("Connect Apple Music", systemImage: "music.note")
                }
            } else {
                Label("Apple Music access is off", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } footer: {
            Text("Playlists are saved on this iPhone. Searching and playing songs uses Apple Music.")
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
                ContentUnavailableView("No Playlists", systemImage: "music.note.list",
                                       description: Text("Tap + to make one, or ask the agent to."))
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
