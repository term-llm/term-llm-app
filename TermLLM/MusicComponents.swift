import SwiftUI

// Shared building blocks for the Music screens.

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    var highlighted = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size / 5, style: .continuous)
                .stroke(.tint, lineWidth: highlighted ? 2 : 0)
        }
        .animation(.snappy(duration: 0.25), value: highlighted)
        .accessibilityHidden(true)
    }
}

/// A song in a list: position, spinner while starting, or playing bars.
struct TrackRow: View {
    let position: Int?
    let track: MusicTrack
    var isCurrent = false
    var isStarting = false
    var isPlaying = false

    var body: some View {
        HStack(spacing: 12) {
            if let position {
                leading(position).frame(width: 24)
            }
            ArtworkView(url: track.artworkURL, size: 44, highlighted: isCurrent && isPlaying)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(isStarting ? "Starting…" : track.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrent ? (isPlaying ? "Playing" : "Paused") : "")
    }

    @ViewBuilder private func leading(_ position: Int) -> some View {
        if isStarting {
            ProgressView().controlSize(.small)
        } else if isCurrent {
            PlayingBars(animating: isPlaying)
        } else {
            Text("\(position)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// The small animated equalizer beside the current song.
struct PlayingBars: View {
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !animating)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { bar in
                    Capsule().fill(.tint).frame(width: 3, height: height(bar, time))
                }
            }
            .frame(height: 16)
        }
        .accessibilityHidden(true)
    }

    private func height(_ bar: Int, _ time: Double) -> CGFloat {
        guard animating else { return bar == 1 ? 12 : 6 }
        let phase = Double(bar) * 0.8
        let wave = sin(time * 5.2 + phase) * 0.6 + sin(time * 3.1 + phase * 1.7) * 0.4
        return 5 + CGFloat((wave + 1) / 2) * 11
    }
}

/// Play / Shuffle buttons at the top of a playlist.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().fill(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08))))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Transport controls: previous, play/pause, next.
struct TransportControls: View {
    let player: MusicPlayer

    var body: some View {
        HStack(spacing: 18) {
            Button { Task { try? await player.previous() } } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button { Task { await player.togglePlayPause() } } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { Task { try? await player.next() } } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .disabled(player.nowPlaying == nil && player.queue.isEmpty)
    }
}

private struct MusicNoticeModifier: ViewModifier {
    let player: MusicPlayer

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice = player.notice {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "music.note")
                        .font(.subheadline)
                        .lineLimit(3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onTapGesture { player.dismissNotice() }
                        .task(id: notice.id) {
                            try? await Task.sleep(for: .seconds(notice.isError ? 5 : 2.5))
                            player.dismissNotice(notice.id)
                        }
                }
            }
            .animation(.snappy(duration: 0.3), value: player.notice)
            .sensoryFeedback(.error, trigger: player.notice) { _, new in new?.isError == true }
    }
}

extension View {
    /// Shows the player's transient notices (e.g. "3 songs aren't available").
    func musicNotices(_ player: MusicPlayer) -> some View {
        modifier(MusicNoticeModifier(player: player))
    }
}
