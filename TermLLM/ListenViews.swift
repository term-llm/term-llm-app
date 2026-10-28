import SwiftUI
import UIKit

// MARK: - Playback shelf

/// A shared shelf for persistent tabs. The players remain independent: this
/// only chooses which controls to show and never starts or stops audio itself.
struct MediaPlaybackShelf: View {
    let listen: Listen
    let music: MusicPlayer
    @Binding var state: State
    var usesSystemBackground = false
    var onOpenPodcastPlayer: () -> Void
    var onOpenMusic: () -> Void

    enum Source: Equatable {
        case podcasts, music
    }

    /// Value-only inputs keep shelf decisions testable without media permissions.
    struct Playback: Equatable {
        var podcastID: UUID?
        var podcastVisible: Bool
        var podcastPlaying: Bool
        var musicID: String?
        var musicPlaying: Bool
    }

    /// Owned by the persistent tab container, including on systems where each
    /// tab hosts its own shelf. Re-mounting a host is not a new playback event.
    struct State {
        private(set) var preferredSource: Source?
        private(set) var dismissedMusicID: String?
        private var lastPlayback: Playback?

        init() {}

        mutating func update(_ playback: Playback) {
            guard lastPlayback != playback else { return }
            let previous = lastPlayback
            if playback.musicID != nil && previous?.musicID != playback.musicID {
                dismissedMusicID = nil
                preferredSource = .music
            }
            if playback.podcastID != nil && previous?.podcastID != playback.podcastID {
                preferredSource = .podcasts
            }
            if playback.musicPlaying && previous?.musicPlaying != true {
                dismissedMusicID = nil
                preferredSource = .music
            }
            if playback.podcastVisible && previous?.podcastVisible == false {
                preferredSource = .podcasts
            }
            if playback.podcastPlaying && previous?.podcastPlaying != true {
                preferredSource = .podcasts
            }
            lastPlayback = playback
        }

        mutating func dismiss(_ source: Source, playback: Playback) {
            // Pin the dismissed source: never replace it with an older paused
            // item from the other player. Only a new selection/start unpins it.
            preferredSource = source
            if source == .music { dismissedMusicID = playback.musicID }
            lastPlayback = playback
        }

        func visibleSource(for playback: Playback) -> Source? {
            MediaPlaybackShelf.visibleSource(
                podcastVisible: playback.podcastID != nil && playback.podcastVisible,
                podcastPlaying: playback.podcastPlaying,
                musicAvailable: playback.musicID != nil && playback.musicID != dismissedMusicID,
                musicPlaying: playback.musicPlaying, preferred: preferredSource)
        }
    }

    /// Playing beats paused. A preferred but hidden source must not fall back
    /// to an older paused source when its controls are dismissed.
    nonisolated static func visibleSource(podcastVisible: Bool, podcastPlaying: Bool,
                              musicAvailable: Bool, musicPlaying: Bool,
                              preferred: Source? = nil) -> Source? {
        if podcastVisible && podcastPlaying { return .podcasts }
        if musicAvailable && musicPlaying { return .music }
        if preferred == .music { return musicAvailable ? .music : nil }
        if preferred == .podcasts { return podcastVisible ? .podcasts : nil }
        if podcastVisible { return .podcasts }
        return musicAvailable ? .music : nil
    }

    private var playback: Playback {
        Playback(podcastID: listen.player.currentID,
                 podcastVisible: listen.player.showsBar,
                 podcastPlaying: listen.player.isPlaying,
                 musicID: music.nowPlaying?.id, musicPlaying: music.isPlaying)
    }

    var body: some View {
        Group {
            if let source = state.visibleSource(for: playback) {
                switch source {
                case .podcasts:
                    MiniPlayerBar(listen: listen, usesSystemBackground: usesSystemBackground,
                                  onDismiss: { dismiss(.podcasts) }, onOpen: onOpenPodcastPlayer)
                case .music:
                    MusicMiniPlayerBar(player: music, usesSystemBackground: usesSystemBackground,
                                       onDismiss: { dismiss(.music) }, onOpen: onOpenMusic)
                }
            }
        }
        .onChange(of: playback, initial: true) { _, playback in
            state.update(playback)
        }
    }

    private func dismiss(_ source: Source) {
        withAnimation(.snappy) {
            state.dismiss(source, playback: playback)
            if source == .podcasts { listen.player.hideBar() }
        }
    }
}

private struct MusicMiniPlayerBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var compactLayout = false
    let player: MusicPlayer
    var usesSystemBackground = false
    var onDismiss: () -> Void
    var onOpen: () -> Void

    var body: some View {
        if let track = player.nowPlaying {
            HStack(spacing: 0) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        ArtworkView(url: track.artworkURL, size: 42, highlighted: player.isPlaying)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(track.subtitle.isEmpty ? "Music" : track.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Music: \(track.title)")
                .accessibilityHint("Opens Music")
                .accessibilityIdentifier("musicMiniPlayerOpen")
                Button { Task { await player.togglePlayPause() } } label: {
                    Group {
                        if player.status == .loading {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(player.isPlaying ? "Pause Music" : "Play Music")
                .accessibilityIdentifier("musicMiniPlayerPlayPause")
                if !dynamicTypeSize.isAccessibilitySize && !compactLayout {
                    Button { Task { try? await player.next() } } label: {
                        Image(systemName: "forward.end.fill")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Next Song")
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Hide Music player")
                .accessibilityHint("Hides the panel without stopping playback.")
                .accessibilityIdentifier("musicMiniPlayerClose")
            }
            .buttonStyle(.plain)
            .font(.body.weight(.medium))
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background {
                if !usesSystemBackground {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
                }
            }
            .shadow(color: usesSystemBackground ? .clear : .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open Music", onOpen)
            .accessibilityAction(named: "Next Song") { Task { try? await player.next() } }
            .accessibilityIdentifier("musicMiniPlayer")
            .onGeometryChange(for: Bool.self) { $0.size.width < 360 } action: { compactLayout = $0 }
            .musicNotices(player)
        }
    }
}

// MARK: - Mini player

/// The persistent mini player above the web page. It lives outside the web
/// view, so playback and the bar survive page loads. Standalone, ✕ stops and
/// closes it; the shared shelf supplies a hide-only dismissal instead. Swiping
/// down hides either presentation while playback carries on.
struct MiniPlayerBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var compactLayout = false
    let listen: Listen
    var usesSystemBackground = false
    var onDismiss: (() -> Void)? = nil
    var onOpen: () -> Void

    @State private var drag: CGFloat = 0
    private var player: ListenPlayer { listen.player }

    var body: some View {
        if let item = player.current {
            HStack(spacing: 0) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        ListenArtwork(item: item, size: 42, store: listen.artwork)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            subtitleView(item)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Now playing: \(item.title)")
                .accessibilityHint("Opens the player")
                if !dynamicTypeSize.isAccessibilitySize && !compactLayout {
                    Button { Task { await player.skip(by: -SystemNowPlaying.skipBack) } } label: {
                        Image(systemName: "gobackward.15").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Back 15 seconds")
                }
                Button { Task { await player.togglePlayPause() } } label: {
                    Group {
                        if player.status == .loading || player.buffering {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                if !dynamicTypeSize.isAccessibilitySize && !compactLayout {
                    Button { Task { await player.skip(by: SystemNowPlaying.skipForward) } } label: {
                        Image(systemName: "goforward.30").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Forward 30 seconds")
                }
                Button {
                    withAnimation(.snappy) {
                        if let onDismiss { onDismiss() } else { player.stop() }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.secondary.opacity(0.15), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(onDismiss == nil ? "Close player" : "Hide Podcast player")
                .accessibilityHint(onDismiss == nil
                    ? "Stops playback. The episode keeps its place in Up Next."
                    : "Hides the panel without stopping playback.")
                .accessibilityIdentifier("miniPlayerClose")
            }
            .buttonStyle(.plain)
            .font(.body.weight(.medium))
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(alignment: .bottom) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        if let buffered = fraction(player.bufferedUntil) {
                            Rectangle().fill(.tint.opacity(0.3)).frame(width: proxy.size.width * buffered)
                        }
                        Rectangle().fill(.tint).frame(width: proxy.size.width * (fraction(player.position) ?? 0))
                    }
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .background {
                if !usesSystemBackground {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: usesSystemBackground ? .clear : .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .offset(y: max(0, drag))
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 40 {
                            withAnimation(.snappy) { hide() }
                        } else if value.translation.height < -40 {
                            onOpen()
                        }
                        withAnimation(.snappy) { drag = 0 }
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open player", onOpen)
            .accessibilityAction(named: "Hide player, keep playing", hide)
            .accessibilityAction(named: "Back 15 seconds") { Task { await player.skip(by: -SystemNowPlaying.skipBack) } }
            .accessibilityAction(named: "Forward 30 seconds") { Task { await player.skip(by: SystemNowPlaying.skipForward) } }
            .accessibilityIdentifier("miniPlayer")
            .onGeometryChange(for: Bool.self) { $0.size.width < 360 } action: { compactLayout = $0 }
        }
    }

    private func hide() {
        if let onDismiss { onDismiss() } else { player.hideBar() }
    }

    private func fraction(_ time: TimeInterval?) -> CGFloat? {
        guard let time, let duration = player.duration, duration > 0 else { return nil }
        return CGFloat(min(1, max(0, time / duration)))
    }

    @ViewBuilder private func subtitleView(_ item: ListenItem) -> some View {
        let text = Text(subtitle(item)).font(.caption).lineLimit(1)
        if case .failed = player.status {
            text.foregroundStyle(.orange)
        } else {
            text.foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ item: ListenItem) -> String {
        if case .failed(let message) = player.status { return message }
        if player.status == .loading {
            return player.streaming ? "Connecting to \(item.url.host() ?? "server")…" : "Loading…"
        }
        if player.buffering { return "Buffering…" }
        let left = player.duration.map { ListenFormat.time(max(0, $0 - player.position)) + " left" }
        // Time left first: it's what changes, and long artists truncate.
        return [left, item.artist].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

// MARK: - Full player

/// The full player sheet: scrubbing, skips, speed, sleep timer, and Up Next.
struct ListenPlayerView: View {
    let listen: Listen

    @Environment(\.dismiss) private var dismiss
    private var player: ListenPlayer { listen.player }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let item = player.current {
                    ListenArtwork(item: item, size: 240, store: listen.artwork)
                        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
                        .padding(.top, 12)
                    VStack(spacing: 6) {
                        Text(item.title)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    VStack(spacing: 10) {
                        ListenScrubber(position: player.position, duration: player.duration,
                                       buffered: player.bufferedUntil) { await player.seek(to: $0) }
                        ListenConnectionStatus(listen: listen, item: item)
                    }
                    transport
                    options
                    if case .failed(let message) = player.status {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 0)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "headphones",
                                           description: Text("Pick something from Up Next."))
                }
            }
            .padding(.horizontal, 24)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ListenView(listen: listen, embedded: true) } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Up Next")
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 34) {
            Button { Task { try? await player.previous() } } label: { Image(systemName: "backward.end.fill") }
                .accessibilityLabel("Previous")
            Button { Task { await player.skip(by: -SystemNowPlaying.skipBack) } } label: { Image(systemName: "gobackward.15") }
                .accessibilityLabel("Back 15 seconds")
            Button { Task { await player.togglePlayPause() } } label: {
                if player.status == .loading || player.buffering {
                    // Still a pause button: tapping stops the wait.
                    Circle().fill(.tint)
                        .frame(width: 60, height: 60)
                        .overlay { ProgressView().tint(.white).controlSize(.large) }
                } else {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { Task { await player.skip(by: SystemNowPlaying.skipForward) } } label: { Image(systemName: "goforward.30") }
                .accessibilityLabel("Forward 30 seconds")
            Button { Task { try? await player.next() } } label: { Image(systemName: "forward.end.fill") }
                .accessibilityLabel("Next")
                .disabled(listen.store.upNext(after: player.currentID) == nil)
        }
        .font(.title2)
        .buttonStyle(.plain)
    }

    private var options: some View {
        HStack {
            Menu {
                ForEach(ListenPlayer.rates, id: \.self) { rate in
                    Button { player.setRate(rate) } label: {
                        if rate == player.rate { Label(ListenFormat.rate(rate), systemImage: "checkmark") } else { Text(ListenFormat.rate(rate)) }
                    }
                }
            } label: {
                Label(ListenFormat.rate(player.rate), systemImage: "gauge.with.dots.needle.67percent")
            }
            Spacer()
            Menu {
                Button("Off") { player.cancelSleepTimer() }
                ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") { player.sleep(minutes: minutes) }
                }
                Button("End of episode") { player.sleepAtEndOfItem() }
            } label: {
                Label(sleepLabel, systemImage: player.sleepAt != nil || player.sleepAtEnd ? "moon.zzz.fill" : "moon.zzz")
            }
        }
        .font(.subheadline)
    }

    private var sleepLabel: String {
        if player.sleepAtEnd { return "End of episode" }
        if let sleepAt = player.sleepAt {
            return sleepAt.formatted(date: .omitted, time: .shortened)
        }
        return "Sleep"
    }
}

// MARK: - Library

/// Up Next and history. Tap to play, drag to reorder, swipe for more.
struct ListenView: View {
    let listen: Listen
    /// Embedded destinations use their parent's navigation stack and omit Done.
    var embedded = false
    /// Hide native chrome while this persistent destination is inactive.
    var isActive: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    private var player: ListenPlayer { listen.player }
    private var store: ListenStore { listen.store }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content.toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                }
            }
        }
    }

    private var content: some View {
        List {
            if let notice = store.notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle.fill").font(.subheadline)
                    Button("OK") { store.dismissNotice() }
                }
            }
            Section {
                if store.upNext.isEmpty {
                    Text("Ask the agent to queue a podcast episode or generated audio.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.upNext) { item in
                    row(item)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { attempt { try listen.remove([item.id]) } } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            Button { Task { await attemptAsync { try await listen.finish([item.id], as: .played) } } } label: {
                                Label("Played", systemImage: "checkmark.circle")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .leading) { downloadAction(item) }
                }
                .onMove { store.moveUpNext(from: $0, to: $1) }
            } header: {
                Text("Up Next")
            } footer: {
                if listen.downloader.totalBytes > 0 {
                    Text("Downloads use \(ByteCountFormatter.string(fromByteCount: listen.downloader.totalBytes, countStyle: .file)).")
                }
            }
            if !store.history.isEmpty {
                Section("History") {
                    ForEach(store.history) { item in
                        row(item)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { attempt { try listen.remove([item.id]) } } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                Button { attempt { try store.setStatus([item.id], .unplayed) } } label: {
                                    Label("Up Next", systemImage: "text.badge.plus")
                                }
                                .tint(.blue)
                            }
                    }
                    Button("Clear History", role: .destructive) { listen.clearHistory() }
                }
            }
        }
        .accessibilityIdentifier(embedded ? "podcastsScreen" : "listenScreen")
        .navigationTitle(embedded ? "Podcasts" : "Listen")
        .toolbar(isActive ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .alert("Couldn't Update Listen", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func row(_ item: ListenItem) -> some View {
        Button {
            Task { await attemptAsync { try await player.play(item.id) } }
        } label: {
            HStack(spacing: 12) {
                ListenArtwork(item: item, size: 44, store: listen.artwork)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(player.currentID == item.id ? .semibold : .regular))
                        .foregroundStyle(player.currentID == item.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                    Text(detail(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.currentID == item.id {
                    PlayingBars(animating: player.status == .playing)
                } else {
                    downloadBadge(item)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func downloadBadge(_ item: ListenItem) -> some View {
        switch item.download {
        case .downloaded: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Downloaded")
        case .queued, .downloading:
            ListenDownloadRing(fraction: listen.downloader.progress[item.id]?.fraction)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityLabel("Download failed")
        case .none: EmptyView()
        }
    }

    @ViewBuilder private func downloadAction(_ item: ListenItem) -> some View {
        switch item.download {
        case .downloaded:
            Button { listen.downloader.deleteFile(item.id) } label: { Label("Delete Download", systemImage: "trash.circle") }
        case .queued, .downloading:
            Button { listen.downloader.cancel(item.id) } label: { Label("Cancel", systemImage: "xmark.circle") }
        case .none, .failed:
            Button { listen.downloader.download(item.id) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .tint(.cyan)
        }
    }

    private func detail(_ item: ListenItem) -> String {
        var parts: [String] = []
        if let artist = item.artist, !artist.isEmpty { parts.append(artist) }
        if let duration = item.duration {
            if item.status == .inProgress, item.position > 0 {
                parts.append(ListenFormat.time(max(0, duration - item.position)) + " left")
            } else {
                parts.append(ListenFormat.time(duration))
            }
        }
        if item.status == .played { parts.append("Played") }
        if item.status == .archived { parts.append("Archived") }
        switch item.download {
        case .queued: parts.append("Waiting to download")
        case .downloading:
            let saving = listen.downloader.isCachingForPlayback(item.id) ? "Saving" : "Downloading"
            if let fraction = listen.downloader.progress[item.id]?.fraction {
                parts.append("\(saving) \(Int(fraction * 100))%")
            } else {
                parts.append(saving + "…")
            }
        case .downloaded:
            if let bytes = item.downloadedBytes, bytes > 0 { parts.append(ListenFormat.bytes(bytes)) }
        case .failed: parts.append("Download failed")
        case .none: break
        }
        return parts.joined(separator: " · ")
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { failure = error.localizedDescription }
    }

    private func attemptAsync(_ action: () async throws -> Void) async {
        do { try await action() } catch { failure = error.localizedDescription }
    }
}

// MARK: - Shared

/// A scrubber that also shows how much of a stream has loaded.
struct ListenScrubber: View {
    let position: TimeInterval
    let duration: TimeInterval?
    let buffered: TimeInterval?
    var onSeek: (TimeInterval) async -> Void

    @State private var dragging: TimeInterval?

    var body: some View {
        let total = max(duration ?? 0, 1)
        let shown = dragging ?? min(position, total)
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let height: CGFloat = dragging == nil ? 6 : 10
                let x = width * fraction(shown, total)
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2))
                    if let buffered {
                        Capsule().fill(.secondary.opacity(0.35)).frame(width: max(height, width * fraction(buffered, total)))
                    }
                    Capsule().fill(.tint).frame(width: max(height, x))
                }
                .frame(height: height)
                .overlay(alignment: .leading) {
                    let knob: CGFloat = dragging == nil ? 14 : 22
                    Circle().fill(.tint)
                        .frame(width: knob, height: knob)
                        .offset(x: min(max(0, x - knob / 2), width - knob))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration != nil else { return }
                            dragging = min(total, max(0, value.location.x / max(width, 1) * total))
                        }
                        .onEnded { _ in
                            guard let target = dragging else { return }
                            Task {
                                await onSeek(target)
                                dragging = nil
                            }
                        }
                )
                .animation(.snappy(duration: 0.15), value: dragging == nil)
            }
            .frame(height: 30)
            HStack {
                Text(ListenFormat.time(shown))
                Spacer()
                Text("-" + ListenFormat.time(max(0, total - shown)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .opacity(duration == nil ? 0.5 : 1)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(duration.map { "\(ListenFormat.time(shown)) of \(ListenFormat.time($0))" } ?? ListenFormat.time(shown))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: Task { await onSeek(position + SystemNowPlaying.skipForward) }
            case .decrement: Task { await onSeek(position - SystemNowPlaying.skipBack) }
            @unknown default: break
            }
        }
    }

    private func fraction(_ time: TimeInterval, _ total: TimeInterval) -> CGFloat {
        CGFloat(min(1, max(0, time / total)))
    }
}

/// Where the current item plays from: the network (connecting, buffering,
/// how far ahead it's loaded) and whether it's being saved on the phone.
struct ListenConnectionStatus: View {
    let listen: Listen
    let item: ListenItem

    private var player: ListenPlayer { listen.player }
    private var downloader: ListenDownloader { listen.downloader }

    var body: some View {
        VStack(spacing: 4) {
            if let line = streamLine {
                HStack(spacing: 6) {
                    if player.status == .loading || player.buffering {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: line.symbol)
                    }
                    Text(line.text)
                }
            }
            fileLine
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var streamLine: (symbol: String, text: String)? {
        guard player.streaming else { return nil }
        let host = item.url.host() ?? "server"
        if player.status == .loading { return ("antenna.radiowaves.left.and.right", "Connecting to \(host)…") }
        if player.buffering { return ("antenna.radiowaves.left.and.right", "Buffering from \(host)…") }
        if let until = player.bufferedUntil {
            let ahead = max(0, until - player.position)
            if let duration = player.duration, until >= duration - 1 {
                return ("antenna.radiowaves.left.and.right", "Streaming · loaded to the end")
            }
            return ("antenna.radiowaves.left.and.right", "Streaming · \(ListenFormat.time(ahead)) loaded ahead")
        }
        return ("antenna.radiowaves.left.and.right", "Streaming from \(host)")
    }

    @ViewBuilder private var fileLine: some View {
        switch item.download {
        case .downloaded:
            if player.streaming {
                Label("Saved on iPhone · seeking uses the file now", systemImage: "checkmark.circle")
            } else if item.cachedForPlayback == true {
                Label("Playing from iPhone · removed after it's played", systemImage: "iphone")
            } else {
                Label("Downloaded · plays offline" + (item.downloadedBytes.map { " · " + ListenFormat.bytes($0) } ?? ""),
                      systemImage: "arrow.down.circle.fill")
            }
        case .queued:
            Label("Waiting to save on iPhone…", systemImage: "arrow.down.circle")
        case .downloading:
            HStack(spacing: 6) {
                ListenDownloadRing(fraction: downloader.progress[item.id]?.fraction, size: 12)
                Text(downloader.progress[item.id].map { ListenFormat.progress($0, verb: "Saving on iPhone") }
                     ?? "Saving on iPhone…")
                Button("Stop") { downloader.cancel(item.id) }
                    .font(.caption.weight(.semibold))
            }
        case .none, .failed:
            Button { downloader.download(item.id) } label: {
                Label(item.download == .failed ? "Download failed · Try again" : "Download for offline",
                      systemImage: "arrow.down.circle")
            }
            .font(.caption.weight(.semibold))
        }
    }
}

/// A small determinate ring; spins while the size is unknown.
struct ListenDownloadRing: View {
    let fraction: Double?
    var size: CGFloat = 18

    var body: some View {
        if let fraction {
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: max(0.02, fraction))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            .animation(.linear(duration: 0.4), value: fraction)
            .accessibilityLabel("Downloading \(Int(fraction * 100)) percent")
        } else {
            ProgressView().controlSize(.small).frame(width: size, height: size)
        }
    }
}

/// Artwork from the copy saved on the phone (see `ListenArtworkStore`).
struct ListenArtwork: View {
    let item: ListenItem
    let size: CGFloat
    let store: ListenArtworkStore

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: String, image: UIImage)?

    var body: some View {
        let pixels = ListenArtworkStore.pixels(for: size, scale: displayScale)
        let key = store.fileName(for: item).map { "\(pixels) \($0)" }
        // A rebuilt view starts from the decoded copy instead of the placeholder.
        let image = store.cachedImage(for: item, pixels: pixels) ?? (key != nil && loaded?.key == key ? loaded?.image : nil)
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
        .accessibilityHidden(true)
        .task(id: key) {
            guard let key else { return }
            loaded = await store.image(for: item, pixels: pixels).map { (key: key, image: $0) }
        }
    }

    private var symbol: String {
        switch item.kind {
        case .episode: return "mic.fill"
        case .generated: return "waveform"
        case .music: return "music.note"
        case .sfx: return "speaker.wave.2.fill"
        case .video: return "play.rectangle.fill"
        case .audio: return "headphones"
        }
    }
}

enum ListenFormat {
    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "Saving 34% (21 of 62 MB)", or "Saving 21 MB" when the size is unknown.
    static func progress(_ progress: ListenDownloader.Progress, verb: String) -> String {
        guard let fraction = progress.fraction, let expected = progress.expected else {
            return progress.received > 0 ? "\(verb) \(bytes(progress.received))…" : "\(verb)…"
        }
        return "\(verb) \(Int(fraction * 100))% (\(bytes(progress.received)) of \(bytes(expected)))"
    }

    static func rate(_ rate: Float) -> String {
        rate == rate.rounded() ? String(format: "%.0f×", rate) : String(format: "%g×", rate)
    }
}
