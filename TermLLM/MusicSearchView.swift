import SwiftUI

/// Searches Apple Music and adds songs to a playlist.
struct MusicSearchView: View {
    let library: MusicLibrary
    let playlistID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MusicTrack] = []
    @State private var searching = false
    @State private var failure: String?

    private var playlist: Playlist? { library.store.playlist(id: playlistID) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { track in
                    Button { toggle(track) } label: {
                        HStack(spacing: 8) {
                            TrackRow(position: nil, track: track)
                            Image(systemName: contains(track) ? "checkmark.circle.fill" : "plus.circle")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(contains(track) ? "In the playlist. Tap to remove." : "Adds to the playlist.")
                }
            }
            .overlay { placeholder }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
            .task(id: query) { await search() }
            .navigationTitle("Add to \(playlist?.name ?? "Playlist")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sensoryFeedback(.selection, trigger: playlist?.entries.count)
        }
    }

    @ViewBuilder private var placeholder: some View {
        if let failure {
            ContentUnavailableView("Can't Search", systemImage: "exclamationmark.triangle", description: Text(failure))
        } else if searching && results.isEmpty {
            ProgressView()
        } else if results.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("Search Apple Music", systemImage: "magnifyingglass",
                                       description: Text("Find songs to add to this playlist."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func contains(_ track: MusicTrack) -> Bool {
        playlist?.entries.contains { $0.track.id == track.id } == true
    }

    /// Adds the song, or removes its most recently added copy.
    private func toggle(_ track: MusicTrack) {
        guard let playlist else { return }
        do {
            if let entry = playlist.entries.filter({ $0.track.id == track.id }).max(by: { $0.addedAt < $1.addedAt }) {
                try library.store.remove(entries: [entry.id], from: playlist.id)
            } else {
                try library.store.add([track], to: playlist.id)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            failure = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350)) // debounce typing
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await library.catalog.search(term, limit: 25)
            guard !Task.isCancelled else { return }
            results = found
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            library.refreshAccess()
            failure = error.localizedDescription
        }
    }
}
