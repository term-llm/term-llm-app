import SwiftUI

// MARK: - Mini player

/// The persistent mini player above the web page. It lives outside the web
/// view, so playback and the bar survive page loads. Swipe down or tap ✕ to
/// hide it; playback carries on and the lock screen keeps its controls.
struct MiniPlayerBar: View {
    let listen: Listen
    var onOpen: () -> Void

    @State private var drag: CGFloat = 0
    private var player: ListenPlayer { listen.player }

    var body: some View {
        if let item = player.current {
            HStack(spacing: 12) {
                ListenArtwork(item: item, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { Task { await player.skip(by: -SystemNowPlaying.skipBack) } } label: {
                    Image(systemName: "gobackward.15")
                }
                .accessibilityLabel("Back 15 seconds")
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
                    .frame(width: 30)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { Task { await player.skip(by: SystemNowPlaying.skipForward) } } label: {
                    Image(systemName: "goforward.30")
                }
                .accessibilityLabel("Forward 30 seconds")
                Button { withAnimation(.snappy) { player.hideBar() } } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Hide player")
            }
            .buttonStyle(.plain)
            .font(.system(size: 18, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(alignment: .bottom) {
                GeometryReader { proxy in
                    Rectangle().fill(.tint)
                        .frame(width: proxy.size.width * progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .offset(y: max(0, drag))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 40 {
                            withAnimation(.snappy) { player.hideBar() }
                        } else if value.translation.height < -40 {
                            onOpen()
                        }
                        withAnimation(.snappy) { drag = 0 }
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(item.title)")
            .accessibilityAction(named: "Open player", onOpen)
            .accessibilityIdentifier("miniPlayer")
        }
    }

    private var progress: CGFloat {
        guard let duration = player.duration, duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, player.position / duration)))
    }

    private func subtitle(_ item: ListenItem) -> String {
        if case .failed(let message) = player.status { return message }
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
    @State private var scrubbing: Double?
    private var player: ListenPlayer { listen.player }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let item = player.current {
                    ListenArtwork(item: item, size: 240)
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
                    scrubber
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

    private var scrubber: some View {
        let duration = max(player.duration ?? 0, 1)
        let value = scrubbing ?? min(player.position, duration)
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { value }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                if !editing, let target = scrubbing {
                    Task {
                        await player.seek(to: target)
                        scrubbing = nil
                    }
                }
            }
            .disabled(player.duration == nil)
            HStack {
                Text(ListenFormat.time(value))
                Spacer()
                Text("-" + ListenFormat.time(max(0, duration - value)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 34) {
            Button { Task { try? await player.previous() } } label: { Image(systemName: "backward.end.fill") }
                .accessibilityLabel("Previous")
            Button { Task { await player.skip(by: -SystemNowPlaying.skipBack) } } label: { Image(systemName: "gobackward.15") }
                .accessibilityLabel("Back 15 seconds")
            Button { Task { await player.togglePlayPause() } } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 60))
                    .contentTransition(.symbolEffect(.replace))
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
    var embedded = false

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
        .navigationTitle("Listen")
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
                ListenArtwork(item: item, size: 44)
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
        case .queued, .downloading: ProgressView().controlSize(.small)
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

struct ListenArtwork: View {
    let item: ListenItem
    let size: CGFloat

    var body: some View {
        AsyncImage(url: item.artworkURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
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

    static func rate(_ rate: Float) -> String {
        rate == rate.rounded() ? String(format: "%.0f×", rate) : String(format: "%g×", rate)
    }
}
