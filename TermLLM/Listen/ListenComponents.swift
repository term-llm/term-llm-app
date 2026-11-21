import SwiftUI

/// Progress updates invalidate row labels, not the entire library.
struct ListenLibraryRow: View {
    let listen: Listen
    let item: ListenItem
    var isActive = true
    private var player: ListenPlayer { listen.player }

    var body: some View {
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
                PlayingBars(animating: isActive && player.status == .playing)
            } else {
                downloadBadge(item)
            }
        }
        .contentShape(Rectangle())
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
            if listen.downloader.isCachingForPlayback(item.id) {
                parts.append(listen.downloader.progress[item.id].map { "Playback cache · " + ListenFormat.bytes($0.received) }
                             ?? "Playback cache")
            } else if let fraction = listen.downloader.progress[item.id]?.fraction {
                parts.append("Downloading \(Int(fraction * 100))%")
            } else {
                parts.append("Downloading…")
            }
        case .downloaded:
            if let bytes = item.downloadedBytes, bytes > 0 { parts.append(ListenFormat.bytes(bytes)) }
        case .failed: parts.append("Download failed")
        case .none: break
        }
        return parts.joined(separator: " · ")
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
    @State private var loaded: (key: String, image: PlatformImage)?

    var body: some View {
        let pixels = ListenArtworkStore.pixels(for: size, scale: displayScale)
        let key = store.fileName(for: item).map { "\(pixels) \($0)" }
        // A rebuilt view starts from the decoded copy instead of the placeholder.
        let image = store.cachedImage(for: item, pixels: pixels) ?? (key != nil && loaded?.key == key ? loaded?.image : nil)
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
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
        guard ListenMediaTime.validPosition(seconds) else { return "—" }
        let total = ListenMediaTime.seconds(seconds)
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
