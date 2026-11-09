import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Shared building blocks for the Music screens.

/// Apple Music artwork from the copy saved on the phone, so a rebuilt row or
/// player bar shows it at once instead of loading and decoding it again.
struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    var highlighted = false
    /// Default: `ListenArtworkStore.music`.
    var store: ListenArtworkStore?

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: String, image: PlatformImage)?

    var body: some View {
        let store = store ?? .music
        let pixels = ListenArtworkStore.pixels(for: size, scale: displayScale)
        let key = url.map { "\(pixels) \($0.absoluteString)" }
        let image = url.flatMap { store.cachedImage(url: $0, pixels: pixels) }
            ?? (key != nil && loaded?.key == key ? loaded?.image : nil)
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
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
        .task(id: key) {
            guard let url, let key else { return }
            loaded = await store.image(url: url, pixels: pixels).map { (key: key, image: $0) }
        }
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

/// The small animated equalizer beside the current song or episode. Core
/// Animation moves the bars in the render server at a capped frame rate, so
/// the app isn't woken to redraw them every frame. They hold still with
/// Reduce Motion.
struct PlayingBars: View {
    let animating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PlayingBarsLayers(animating: animating && !reduceMotion)
            .frame(width: PlayingBarsView.width, height: PlayingBarsView.height)
            .accessibilityHidden(true)
    }
}

#if os(iOS)
private struct PlayingBarsLayers: UIViewRepresentable {
    let animating: Bool

    func makeUIView(context: Context) -> PlayingBarsView { PlayingBarsView() }
    func updateUIView(_ view: PlayingBarsView, context: Context) { view.animating = animating }
}

typealias PlayingBarsBaseView = UIView
#elseif os(macOS)
private struct PlayingBarsLayers: NSViewRepresentable {
    let animating: Bool

    func makeNSView(context: Context) -> PlayingBarsView { PlayingBarsView() }
    func updateNSView(_ view: PlayingBarsView, context: Context) { view.animating = animating }
}

typealias PlayingBarsBaseView = NSView
#endif

/// Three tinted capsules whose heights Core Animation varies.
final class PlayingBarsView: PlayingBarsBaseView {
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2
    static let width = barWidth * 3 + spacing * 2
    static let height: CGFloat = 16
    static let stillHeights: [CGFloat] = [6, 12, 6]
    static let lowest: CGFloat = 5
    /// Seconds for each bar to rise (and again to fall); unequal, so the bars
    /// drift in and out of step.
    static let periods: [CFTimeInterval] = [0.43, 0.31, 0.37]
    static let frameRate = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
    static let animationKey = "playing"

    let bars: [CALayer] = (0..<3).map { _ in CALayer() }

    var animating = false {
        didSet { if animating != oldValue { updateAnimations() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        isUserInteractionEnabled = false
        bars.forEach { layer.addSublayer($0) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PlayingBarsView, _: UITraitCollection) in
            view.updateColor()
        }
        #else
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
        #endif
        updateColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.width, height: Self.height) }

    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColor()
    }
    #else
    override func layout() {
        super.layout()
        layoutBars()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let left = bounds.midX - Self.width / 2
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.stillHeights[index])
            bar.position = CGPoint(x: left + CGFloat(index) * (Self.barWidth + Self.spacing) + Self.barWidth / 2,
                                   y: bounds.midY)
            bar.cornerRadius = Self.barWidth / 2
        }
        CATransaction.commit()
    }

    private func updateColor() {
        #if os(iOS)
        let color = tintColor.resolvedColor(with: traitCollection).cgColor
        #else
        var color = NSColor.controlAccentColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.controlAccentColor.cgColor }
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color }
        CATransaction.commit()
    }

    private func updateAnimations() {
        for (index, bar) in bars.enumerated() {
            guard animating else {
                bar.removeAnimation(forKey: Self.animationKey)
                continue
            }
            let bounce = CABasicAnimation(keyPath: "bounds.size.height")
            bounce.fromValue = Self.lowest
            bounce.toValue = Self.height
            bounce.duration = Self.periods[index]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.timeOffset = Self.periods[index] * Double(index) * 0.7
            bounce.preferredFrameRateRange = Self.frameRate
            // Otherwise the bars stop once the app has been in the background.
            bounce.isRemovedOnCompletion = false
            bar.add(bounce, forKey: Self.animationKey)
        }
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
