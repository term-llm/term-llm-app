import SwiftUI

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

/// One floating control surface, not glass on every child or on media content.
/// The system handles contrast, Reduce Transparency and Reduce Motion.
private struct PlaybackControlSurface: ViewModifier {
    let usesSystemBackground: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if usesSystemBackground {
            content
        } else {
            #if os(macOS)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: 18))
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
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
            .modifier(PlaybackControlSurface(usesSystemBackground: usesSystemBackground))
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

    private var isPhone: Bool { WorkspacePlatform.current == .phone }
    private var showsInlineSkips: Bool { !isPhone && !dynamicTypeSize.isAccessibilitySize && !compactLayout }
    /// The phone tab accessory has a fixed height; inset its contents so the
    /// title never runs edge to edge against the cover and controls.
    private var isTabAccessory: Bool { isPhone && usesSystemBackground }

    private func episodeTitle(_ item: ListenItem) -> some View {
        Text(item.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func openLabel(_ item: ListenItem) -> some View {
        HStack(spacing: 12) {
            // Keep a stable cover (or the standard placeholder) when text wraps.
            ListenArtwork(item: item, size: isPhone ? 32 : 42, store: listen.artwork)
            Group {
                if isTabAccessory {
                    // The tab accessory has a fixed height. One standard-style
                    // line each keeps air above and below; the full title is in
                    // the player sheet and the accessibility label. Large text
                    // drops the subtitle rather than crowding the edges.
                    VStack(alignment: .leading, spacing: 1) {
                        episodeTitle(item).lineLimit(1)
                        if !dynamicTypeSize.isAccessibilitySize {
                            ListenMiniPlayerSubtitle(player: player, item: item)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        episodeTitle(item).lineLimit(isPhone ? 2 : 1)
                        ListenMiniPlayerSubtitle(player: player, item: item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        if let item = player.current {
            HStack(spacing: 0) {
                Button(action: onOpen) {
                    openLabel(item)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Now playing: \(item.title)")
                .accessibilityHint("Opens the player")
                .accessibilityIdentifier("miniPlayerOpen")
                if showsInlineSkips {
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
                .accessibilityIdentifier("miniPlayerPlayPause")
                if showsInlineSkips {
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
            .padding(.leading, isTabAccessory ? 20 : usesSystemBackground ? 12 : 14)
            .padding(.trailing, isTabAccessory ? 12 : 4)
            .padding(.vertical, usesSystemBackground ? 0 : 4)
            .background(alignment: .bottom) {
                ListenMiniPlayerProgress(player: player)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .modifier(PlaybackControlSurface(usesSystemBackground: usesSystemBackground))
            .padding(.horizontal, usesSystemBackground ? 0 : 10)
            .padding(.bottom, usesSystemBackground ? 0 : 4)
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
}

/// Only this small label observes the once-per-second playhead, not the
/// artwork, transport controls, shelf selection or retained tab container.
struct ListenMiniPlayerSubtitle: View {
    let player: ListenPlayer
    let item: ListenItem

    var body: some View {
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

/// Keep playhead/buffer changes inside the two-pixel progress track.
struct ListenMiniPlayerProgress: View {
    let player: ListenPlayer

    var body: some View {
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

    private func fraction(_ time: TimeInterval?) -> CGFloat? {
        guard let time, let duration = player.duration, duration > 0 else { return nil }
        return CGFloat(min(1, max(0, time / duration)))
    }
}
