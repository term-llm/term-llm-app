import SwiftUI

/// Passing the player rather than position values keeps the full sheet's
/// artwork and menus outside the high-frequency observation boundary.
struct ListenPlaybackScrubber: View {
    let player: ListenPlayer

    var body: some View {
        ListenScrubber(position: player.position, duration: player.duration,
                       buffered: player.bufferedUntil) { await player.seek(to: $0) }
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
                        ListenPlaybackScrubber(player: player)
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
                ToolbarItem(placement: .platformLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .platformTrailing) {
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
            let caching = downloader.isCachingForPlayback(item.id)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if caching {
                        Image(systemName: "internaldrive")
                        Text(downloader.progress[item.id].map { "Playback cache · " + ListenFormat.bytes($0.received) }
                             ?? "Playback cache")
                    } else {
                        ListenDownloadRing(fraction: downloader.progress[item.id]?.fraction, size: 12)
                        Text(downloader.progress[item.id].map { ListenFormat.progress($0, verb: "Saving on iPhone") }
                             ?? "Saving on iPhone…")
                    }
                    Button("Stop") { downloader.cancel(item.id) }
                        .font(.caption.weight(.semibold))
                }
                if caching {
                    Button("Download for offline") { downloader.download(item.id) }
                        .font(.caption.weight(.semibold))
                }
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
