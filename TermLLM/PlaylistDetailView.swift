import SwiftUI

/// One playlist: play or shuffle it, play from any song, and edit it.
struct PlaylistDetailView: View {
    let library: MusicLibrary
    let playlistID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var addingSongs = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var failure: String?
    @State private var taps = 0

    private var player: MusicPlayer { library.player }
    private var store: PlaylistStore { library.store }

    var body: some View {
        if let playlist = store.playlist(id: playlistID) {
            content(playlist)
        } else {
            ContentUnavailableView("Playlist Deleted", systemImage: "trash")
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        List {
            if !playlist.entries.isEmpty {
                Section {
                    actions(playlist)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                if playlist.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Songs", systemImage: "music.note")
                    } description: {
                        Text("Add songs from Apple Music, or ask the agent to.")
                    } actions: {
                        Button("Add Songs") { addingSongs = true }
                    }
                }
                ForEach(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                    Button { play(playlist, from: entry) } label: {
                        TrackRow(position: index + 1, track: entry.track,
                                 isCurrent: isCurrent(entry, in: playlist),
                                 isStarting: player.startingEntryID == entry.id,
                                 isPlaying: player.isPlaying)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    attempt { try store.remove(entries: Set(offsets.map { playlist.entries[$0].id }), from: playlist.id) }
                }
                .onMove { source, destination in
                    attempt { try store.move(in: playlist.id, from: source, to: destination) }
                }
            } header: {
                if !playlist.entries.isEmpty { Text(playlist.songCountText) }
            } footer: {
                if !playlist.entries.isEmpty { Text("Tap a song to play from there.") }
            }
        }
        .navigationTitle(playlist.name)
        .animation(.snappy(duration: 0.25), value: player.nowPlaying)
        .animation(.snappy(duration: 0.25), value: player.startingEntryID)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !playlist.entries.isEmpty { EditButton() }
                Menu {
                    Button { addingSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                    Button { newName = playlist.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Playlist Actions")
            }
        }
        .sheet(isPresented: $addingSongs) {
            MusicSearchView(library: library, playlistID: playlist.id)
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { attempt { try store.rename(playlist.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(playlist.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                attempt { try store.delete(playlist.id) }
                dismiss()
            }
        }
        .alert("Couldn't Update Playlist", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .musicNotices(player)
    }

    // MARK: Header

    private func actions(_ playlist: Playlist) -> some View {
        let active = player.isActive(playlist)
        let title = active ? (player.isPlaying ? "Pause" : "Resume") : "Play"
        return HStack(spacing: 12) {
            Button {
                taps += 1
                if active {
                    Task { await player.togglePlayPause() }
                } else {
                    play(playlist, from: nil)
                }
            } label: {
                Label(title, systemImage: active && player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PillButtonStyle(prominent: true))

            Button {
                taps += 1
                player.setShuffle(!player.shuffle)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(PillButtonStyle(prominent: player.shuffle))
            .accessibilityValue(player.shuffle ? "On" : "Off")
        }
        .animation(.snappy(duration: 0.2), value: player.shuffle)
    }

    // MARK: Helpers

    private func isCurrent(_ entry: PlaylistEntry, in playlist: Playlist) -> Bool {
        player.isActive(playlist) && player.nowPlaying?.id == entry.track.id
    }

    private func play(_ playlist: Playlist, from entry: PlaylistEntry?) {
        guard player.startingEntryID == nil else { return }
        taps += 1
        Task { try? await player.play(playlist, startingAt: entry?.id) }
    }

    private func attempt(_ change: () throws -> Void) {
        do { try change() } catch { failure = error.localizedDescription }
    }
}
