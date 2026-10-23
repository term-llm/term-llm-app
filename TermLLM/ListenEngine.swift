import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit
import WebKit

// The boundary between Listen and AVFoundation, MediaPlayer, and WebKit.
// Everything above these protocols (store, player, tools, views) is testable
// without real audio.

/// What the engine plays: a local file or a remote URL, with the cookies the
/// request may carry (only for the connected term-llm server).
struct ListenSource: Equatable, Sendable {
    var url: URL
    var cookies: [HTTPCookie] = []
    var spoken = true

    var isLocal: Bool { url.isFileURL }
}

enum ListenEngineEvent: Equatable, Sendable {
    /// About once a second while loaded.
    case tick
    case ended
    case failed(String)
    /// Another app or a call took the audio; playback was paused by iOS.
    case interrupted
    /// The interruption ended and iOS suggests resuming.
    case interruptionEnded(shouldResume: Bool)
    /// Headphones or another route went away; playback should pause.
    case outputLost
    /// How much of a stream is loaded, or whether it's stalled, changed.
    case buffer
}

@MainActor
protocol ListenEngine: AnyObject {
    var onEvent: (@MainActor (ListenEngineEvent) -> Void)? { get set }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    /// For a stream: how far (media time) is loaded contiguously from the
    /// current position. Nil for local files or when unknown.
    var bufferedUntil: TimeInterval? { get }
    /// Playback was asked for but is waiting on the network.
    var isStalled: Bool { get }
    /// Prepares `source`, positioned at `startAt`; throws when it can't play.
    func load(_ source: ListenSource, startAt: TimeInterval) async throws
    func play(rate: Float) throws
    func pause()
    func seek(to seconds: TimeInterval) async
    func setRate(_ rate: Float)
    /// Unloads and gives up the audio session.
    func stop()
}

/// Supplies the web view's cookies for requests to the connected server.
@MainActor
protocol ListenCookieJar {
    func cookies(for url: URL) async -> [HTTPCookie]
    func cookies(for url: URL, sourceID: UUID?) async -> [HTTPCookie]
}
extension ListenCookieJar {
    func cookies(for url: URL, sourceID: UUID?) async -> [HTTPCookie] { await cookies(for: url) }
}

@MainActor
struct WebKitCookieJar: ListenCookieJar {
    private let registry: HubCookieScopeRegistry
    init(registry: HubCookieScopeRegistry? = nil) { self.registry = registry ?? .shared }
    func cookies(for url: URL) async -> [HTTPCookie] {
        return await registry.cookies(for: url, sourceID: nil)
    }
    func cookies(for url: URL, sourceID: UUID?) async -> [HTTPCookie] {
        await registry.cookies(for: url, sourceID: sourceID)
    }

    /// RFC 6265 domain/path/secure matching, enough to pick the session cookie.
    nonisolated static func matching(_ cookies: [HTTPCookie], url: URL) -> [HTTPCookie] {
        guard let host = url.host()?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        return cookies.filter { cookie in
            var domain = cookie.domain.lowercased()
            let domainMatches: Bool
            if domain.hasPrefix(".") {
                domain.removeFirst()
                domainMatches = host == domain || host.hasSuffix("." + domain)
            } else {
                domainMatches = host == domain
            }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
            let notExpired = cookie.expiresDate.map { $0 > Date() } ?? true
            return domainMatches && pathMatches && (secure || !cookie.isSecure) && notExpired
        }
    }
}

// MARK: - AVFoundation

/// Injectable so session activation failures can be tested without real audio.
@MainActor
protocol ListenAudioSession: AnyObject {
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     policy: AVAudioSession.RouteSharingPolicy, options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: ListenAudioSession {}

@MainActor
final class AVListenEngine: ListenEngine {
    var onEvent: (@MainActor (ListenEngineEvent) -> Void)?

    private let player = AVPlayer()
    private let audioSession: any ListenAudioSession
    private var timeObserver: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var keyValueObservers: [NSKeyValueObservation] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private var spoken = true
    private var isRemote = false

    /// How long to wait for a stream to become playable.
    static let loadTimeout: Duration = .seconds(30)

    init(audioSession: any ListenAudioSession = AVAudioSession.sharedInstance()) {
        self.audioSession = audioSession
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2),
                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.tick) }
        }
        keyValueObservers.append(player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.onEvent?(.buffer) }
        })
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                                   queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem != nil else { return }
                switch type {
                case .began: self.onEvent?(.interrupted)
                case .ended: self.onEvent?(.interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false))
                default: break
                }
            }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                                   queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem != nil, reason == .oldDeviceUnavailable else { return }
                self.onEvent?(.outputLost)
            }
        })
    }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    var duration: TimeInterval? {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    var bufferedUntil: TimeInterval? {
        guard isRemote, let item = player.currentItem else { return nil }
        let now = player.currentTime().seconds
        guard now.isFinite else { return nil }
        // The loaded range that covers the playhead (allow a little slack
        // right after a seek, before data for the exact spot arrives).
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            if start <= now + 1, end >= now { return end }
        }
        return now
    }

    var isStalled: Bool {
        player.currentItem != nil && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    func load(_ source: ListenSource, startAt: TimeInterval) async throws {
        spoken = source.spoken
        isRemote = !source.isLocal
        var options: [String: Any] = [:]
        if !source.cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = source.cookies }
        let asset = AVURLAsset(url: source.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        observe(item)
        player.replaceCurrentItem(with: item)
        try await waitUntilReady(item)
        if startAt > 0 { await seek(to: startAt) }
    }

    func play(rate: Float) throws {
        let mode: AVAudioSession.Mode = spoken ? .spokenAudio : .default
        try audioSession.setCategory(.playback, mode: mode, policy: .longFormAudio, options: [])
        do {
            try audioSession.setActive(true, options: [])
        } catch {
            let error = error as NSError
            guard error.domain == NSOSStatusErrorDomain,
                  error.code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue else { throw error }
            // A request arriving from a locked-screen voice conversation runs
            // in the background. iOS won't let it interrupt another audio
            // session there; retry cooperatively rather than refusing to play.
            try audioSession.setCategory(.playback, mode: mode, policy: .longFormAudio, options: [.mixWithOthers])
            try audioSession.setActive(true, options: [])
        }
        player.playImmediately(atRate: rate)
    }

    func pause() {
        player.pause()
    }

    /// Exact for files. A stream may land up to a second early, which lets
    /// AVFoundation start from data it can fetch at once instead of hunting
    /// for the exact frame (much quicker for long MP3 episodes).
    func seek(to seconds: TimeInterval) async {
        let before = isRemote ? CMTime(seconds: 1, preferredTimescale: 600) : .zero
        await player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                          toleranceBefore: before, toleranceAfter: .zero)
        onEvent?(.buffer)
    }

    func setRate(_ rate: Float) {
        if player.rate > 0 { player.rate = rate }
        player.defaultRate = rate
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        isRemote = false
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func waitUntilReady(_ item: AVPlayerItem) async throws {
        let ready = item.publisher(for: \.status)
            .first { $0 != .unknown }
            .values
        let status: AVPlayerItem.Status? = try await withThrowingTaskGroup(of: AVPlayerItem.Status?.self) { group in
            group.addTask { @MainActor in
                for await status in ready { return status }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: Self.loadTimeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch status {
        case .readyToPlay?:
            return
        case .failed?:
            throw ListenError.playbackFailed(item.error?.localizedDescription ?? "the media couldn't be opened")
        default:
            player.replaceCurrentItem(with: nil)
            throw ListenError.playbackFailed("it didn't start loading within \(Int(Self.loadTimeout.components.seconds)) seconds")
        }
    }

    private func observe(_ item: AVPlayerItem) {
        removeItemObservers()
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.ended) }
        })
        itemObservers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item,
                                                queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                self?.onEvent?(.failed(error?.localizedDescription ?? "playback stopped unexpectedly"))
            }
        })
        itemObservers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item,
                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.buffer) }
        })
        itemKeyValueObservers = [item.observe(\.loadedTimeRanges) { [weak self] _, _ in
            Task { @MainActor in self?.onEvent?(.buffer) }
        }]
    }

    private var itemKeyValueObservers: [NSKeyValueObservation] = []

    private func removeItemObservers() {
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        itemKeyValueObservers = []
    }
}

// MARK: - Lock screen

/// What the lock screen, Control Center, AirPods, and CarPlay show and send.
@MainActor
protocol ListenNowPlaying: AnyObject {
    func connect(_ commands: ListenRemoteCommands)
    func show(_ item: ListenItem, position: TimeInterval, duration: TimeInterval?, rate: Float, playing: Bool)
    func clear()
}

struct ListenRemoteCommands {
    var play: @MainActor () -> Void
    var pause: @MainActor () -> Void
    var toggle: @MainActor () -> Void
    var skip: @MainActor (_ seconds: TimeInterval) -> Void
    var seek: @MainActor (_ position: TimeInterval) -> Void
    var next: @MainActor () -> Void
    var previous: @MainActor () -> Void
    var rate: @MainActor (_ rate: Float) -> Void
}

@MainActor
final class SystemNowPlaying: ListenNowPlaying {
    static let skipBack: TimeInterval = 15
    static let skipForward: TimeInterval = 30

    private var artworkURL: URL?
    private var artworkSourceID: UUID?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private let cookies: ListenCookieJar
    private let server: () -> ListenServer?

    init(cookies: ListenCookieJar, server: @escaping () -> ListenServer?) {
        self.cookies = cookies
        self.server = server
    }

    func connect(_ commands: ListenRemoteCommands) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in MainActor.assumeIsolated { commands.play() }; return .success }
        center.pauseCommand.addTarget { _ in MainActor.assumeIsolated { commands.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { commands.toggle() }; return .success }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBack)]
        center.skipBackwardCommand.addTarget { _ in
            MainActor.assumeIsolated { commands.skip(-Self.skipBack) }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        center.skipForwardCommand.addTarget { _ in
            MainActor.assumeIsolated { commands.skip(Self.skipForward) }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { commands.seek(event.positionTime) }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in MainActor.assumeIsolated { commands.next() }; return .success }
        center.previousTrackCommand.addTarget { _ in MainActor.assumeIsolated { commands.previous() }; return .success }
        center.changePlaybackRateCommand.supportedPlaybackRates = ListenPlayer.rates.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { commands.rate(event.playbackRate) }
            return .success
        }
    }

    func show(_ item: ListenItem, position: TimeInterval, duration: TimeInterval?, rate: Float, playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = item.artist, !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = duration ?? item.duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if item.artworkURL == artworkURL, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        loadArtwork(for: item)
    }

    func clear() {
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func loadArtwork(for item: ListenItem) {
        guard item.artworkURL != artworkURL || item.sourceID != artworkSourceID else { return }
        artworkURL = item.artworkURL
        artworkSourceID = item.sourceID
        artwork = nil
        artworkTask?.cancel()
        guard let url = item.artworkURL else { return }
        let cookies = cookies
        let sameServer = item.sourceID != nil || (server()?.isSameOrigin(url) ?? false)
        artworkTask = Task { [weak self] in
            var request = URLRequest(url: url, timeoutInterval: 20)
            if sameServer {
                HTTPCookie.requestHeaderFields(with: await cookies.cookies(for: url, sourceID: item.sourceID)).forEach {
                    request.setValue($1, forHTTPHeaderField: $0)
                }
            }
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = UIImage(data: data), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.artworkURL == url else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artwork = artwork
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                guard info[MPMediaItemPropertyTitle] != nil else { return }
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
