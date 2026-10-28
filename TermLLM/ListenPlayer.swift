import Foundation
import Observation

/// Plays the Listen library: one item at a time, resuming where each was left,
/// continuing through Up Next, and keeping the lock screen in step. Shared by
/// the mini player, the Listen screens, and the agent's media tools.
@MainActor
@Observable
final class ListenPlayer {
    enum Status: Equatable {
        case idle, loading, playing, paused
        case failed(String)
    }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let rateKey = "listen.rate"
    static let currentKey = "listen.current"

    private(set) var status: Status = .idle
    /// The item shown in the mini player; it survives app restarts (paused).
    private(set) var currentID: UUID?
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var rate: Float
    /// Pause at this time, or at the end of the current item.
    private(set) var sleepAt: Date?
    private(set) var sleepAtEnd = false
    /// The user swiped the mini player away; playback carries on.
    private(set) var barHidden = false
    private(set) var notice: String?
    /// The loaded item comes over the network rather than from a file.
    private(set) var streaming = false
    /// Playing, but waiting for the network.
    private(set) var buffering = false
    /// For a stream: loaded up to here (media time) from the playhead.
    private(set) var bufferedUntil: TimeInterval?

    /// Runs before this player starts audio (e.g. to pause Apple Music).
    @ObservationIgnored var willStartPlayback: (() -> Void)?
    /// Items played to the end here.
    @ObservationIgnored var didFinish: (([UUID]) -> Void)?

    @ObservationIgnored private let store: ListenStore
    @ObservationIgnored private let engine: ListenEngine
    @ObservationIgnored private let sources: (ListenItem) async -> ListenSource
    @ObservationIgnored private let nowPlaying: ListenNowPlaying?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    /// The item the engine has loaded (nil after a restart until played).
    @ObservationIgnored private var loadedID: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticksSinceSave = 0
    @ObservationIgnored private var pausedByInterruption = false

    /// Positions are saved every this many seconds while playing.
    static let saveInterval = 5

    init(store: ListenStore, engine: ListenEngine, sources: @escaping (ListenItem) async -> ListenSource,
         nowPlaying: ListenNowPlaying? = nil, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.engine = engine
        self.sources = sources
        self.nowPlaying = nowPlaying
        self.defaults = defaults
        self.now = now
        let saved = defaults.float(forKey: Self.rateKey)
        rate = saved > 0 ? saved : 1
        if let raw = defaults.string(forKey: Self.currentKey), let id = UUID(uuidString: raw),
           let item = store.item(id), item.isQueued {
            currentID = id
            position = item.position
            duration = item.duration
            status = .paused
        }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        nowPlaying?.connect(ListenRemoteCommands(
            play: { [weak self] in Task { try? await self?.resume() } },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in Task { await self?.togglePlayPause() } },
            skip: { [weak self] seconds in Task { await self?.skip(by: seconds) } },
            seek: { [weak self] position in Task { await self?.seek(to: position) } },
            next: { [weak self] in Task { try? await self?.next() } },
            previous: { [weak self] in Task { try? await self?.previous() } },
            rate: { [weak self] rate in self?.setRate(rate) }
        ))
    }

    var current: ListenItem? { currentID.flatMap(store.item) }
    var isPlaying: Bool { status == .playing || status == .loading }
    /// Player state only, never the library: the root view reads this, and the
    /// library changes every few seconds while playing (the position is saved).
    /// The iOS 26 tab accessory rebuilds the whole shelf on each root update.
    var showsBar: Bool { currentID != nil && !barHidden }

    // MARK: - Starting

    /// Plays `id` from `start` (default: where it was left).
    func play(_ id: UUID, from start: TimeInterval? = nil) async throws {
        guard store.item(id) != nil else { throw ListenError.notFound(id.uuidString) }
        if loadedID == id, currentID == id, status == .playing || status == .paused {
            // Already loaded: keep the buffer instead of fetching it again.
            barHidden = false
            notice = nil
            if let start { await seek(to: start) }
            if status == .paused { try await resume() }
            return
        }
        try await load(id, from: start)
    }

    /// Loads `id` (from `source`, or wherever it's best played from) and
    /// starts it unless `autoplay` is false.
    private func load(_ id: UUID, from start: TimeInterval?, source given: ListenSource? = nil,
                      autoplay: Bool = true) async throws {
        guard let item = store.item(id) else { throw ListenError.notFound(id.uuidString) }
        if autoplay { willStartPlayback?() }
        if let currentID, currentID != id, loadedID == currentID { savePosition() }
        generation += 1
        let attempt = generation
        setCurrent(id)
        barHidden = false
        notice = nil
        status = .loading
        resetNetworkState()
        let startAt = start ?? item.resumePosition()
        position = startAt
        duration = item.duration
        store.update(id) {
            if !$0.isQueued { $0.status = .unplayed }
            $0.lastPlayedAt = self.now()
        }
        do {
            var source = given
            if source == nil { source = await sources(item) }
            guard let source, attempt == generation else { return }
            streaming = !source.isLocal
            try await engine.load(source, startAt: startAt)
            guard attempt == generation else { return }
            loadedID = id
            if autoplay {
                try await engine.play(rate: rate)
                guard attempt == generation else { return }
                status = .playing
            } else {
                status = .paused
            }
            duration = engine.duration ?? item.duration
            updateNetworkState()
            store.update(id) {
                $0.status = .inProgress
                if let duration = self.duration { $0.duration = duration }
            }
            showNowPlaying()
        } catch {
            guard attempt == generation else { return }
            generation += 1
            engine.stop()
            nowPlaying?.clear()
            loadedID = nil
            resetNetworkState()
            let message = error.localizedDescription
            status = .failed(message)
            notice = message
            throw error
        }
    }

    /// Resumes the current item, or starts Up Next.
    func resume() async throws {
        if let current, loadedID == current.id, status == .paused {
            if await switchToDownload(at: engine.currentTime, autoplay: true) { return }
            willStartPlayback?()
            // Playing as soon as asked, so a pause while the audio session
            // activates reaches the engine and wins.
            let attempt = generation
            status = .playing
            do {
                try await engine.play(rate: rate)
            } catch {
                if attempt == generation, status == .playing { status = .paused }
                throw error
            }
            guard attempt == generation, status == .playing else { return }
            showNowPlaying()
            return
        }
        if let current, current.isQueued {
            try await play(current.id)
            return
        }
        guard let first = store.upNext.first else { throw ListenError.nothingToPlay }
        try await play(first.id)
    }

    func togglePlayPause() async {
        if isPlaying { pause() } else { try? await resume() }
    }

    // MARK: - Transport

    func pause() {
        pausedByInterruption = false
        generation += 1
        guard status == .playing || status == .loading else { return }
        if status == .loading { loadedID = nil }
        engine.pause()
        status = .paused
        savePosition()
        showNowPlaying()
    }

    /// Unloads everything; the mini player goes away.
    func stop() {
        pausedByInterruption = false
        if loadedID != nil { savePosition() }
        generation += 1
        engine.stop()
        loadedID = nil
        resetNetworkState()
        status = .idle
        setCurrent(nil)
        cancelSleepTimer()
        nowPlaying?.clear()
    }

    func seek(to seconds: TimeInterval) async {
        let target = max(0, duration.map { min(seconds, $0) } ?? seconds)
        position = target
        if loadedID != nil && loadedID == currentID {
            // Once the stream is saved, jumps are instant from the file.
            if await !switchToDownload(at: target, autoplay: status == .playing) {
                await engine.seek(to: target)
            }
            updateNetworkState()
        }
        if let currentID { store.update(currentID) { $0.position = target } }
        showNowPlaying()
    }

    func skip(by seconds: TimeInterval) async {
        let base = loadedID != nil ? engine.currentTime : position
        await seek(to: base + seconds)
    }

    /// Next in Up Next. The skipped item keeps its place and position.
    func next() async throws {
        guard let following = store.upNext(after: currentID) else {
            throw ListenError.nothingToPlay
        }
        try await play(following.id)
    }

    /// Back to the start, or (near the start) the previous Up Next item.
    func previous() async throws {
        let elapsed = loadedID != nil ? engine.currentTime : position
        if elapsed > 5 || currentID == nil {
            await seek(to: 0)
            return
        }
        if let currentID, let earlier = store.upNext(before: currentID) {
            try await play(earlier.id, from: 0)
        } else {
            await seek(to: 0)
        }
    }

    func setRate(_ value: Float) {
        rate = min(3, max(0.5, value))
        defaults.set(rate, forKey: Self.rateKey)
        engine.setRate(rate)
        showNowPlaying()
    }

    /// Pauses after `minutes`; nil or 0 cancels.
    func sleep(minutes: Int?) {
        sleepAtEnd = false
        if let minutes, minutes > 0 {
            sleepAt = now().addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            sleepAt = nil
        }
    }

    func sleepAtEndOfItem() {
        sleepAt = nil
        sleepAtEnd = true
    }

    func cancelSleepTimer() {
        sleepAt = nil
        sleepAtEnd = false
    }

    func hideBar() { barHidden = true }
    func showBar() { barHidden = false }

    func dismissNotice() { notice = nil }

    /// The library is about to lose these items; stop if one is playing.
    func willRemove(_ ids: Set<UUID>) {
        guard let currentID, ids.contains(currentID) else { return }
        stop()
    }

    /// `id` was marked played or archived elsewhere.
    func didFinishElsewhere(_ id: UUID) async {
        guard currentID == id else { return }
        if isPlaying, let following = store.upNext(after: nil) {
            try? await play(following.id)
        } else {
            stop()
        }
    }

    // MARK: - Engine events

    private func handle(_ event: ListenEngineEvent) {
        switch event {
        case .tick:
            guard loadedID != nil, loadedID == currentID else { return }
            position = engine.currentTime
            if let known = engine.duration { duration = known }
            updateNetworkState()
            ticksSinceSave += 1
            if status == .playing, ticksSinceSave >= Self.saveInterval { savePosition() }
            if let sleepAt, now() >= sleepAt {
                cancelSleepTimer()
                pause()
            }
        case .ended:
            let attempt = generation
            Task {
                guard attempt == generation else { return }
                await finishCurrent()
            }
        case .failed(let message):
            savePosition()
            if streaming, let id = currentID, store.item(id)?.download == .downloaded {
                // The stream dropped, but the file is here: carry on from it.
                let resumeAt = position
                let attempt = generation
                Task {
                    guard attempt == generation else { return }
                    do { try await load(id, from: resumeAt) } catch {}
                }
                return
            }
            generation += 1
            engine.stop()
            nowPlaying?.clear()
            loadedID = nil
            resetNetworkState()
            status = .failed(message)
            notice = "Playback stopped: \(message)"
        case .interrupted:
            guard status == .playing else { return }
            status = .paused
            pausedByInterruption = true
            savePosition()
            showNowPlaying()
        case .interruptionEnded(let shouldResume):
            guard pausedByInterruption else { return }
            pausedByInterruption = false
            if shouldResume {
                let attempt = generation
                Task {
                    guard attempt == generation, status == .paused else { return }
                    try? await resume()
                }
            }
        case .outputLost:
            pause()
        case .buffer:
            guard loadedID != nil, loadedID == currentID else { return }
            updateNetworkState()
        }
    }

    private func finishCurrent() async {
        guard let id = currentID else { return }
        let following = store.upNext(after: id)
        try? store.setStatus([id], .played)
        store.update(id) { $0.lastPlayedAt = self.now() }
        didFinish?([id])
        if sleepAtEnd {
            cancelSleepTimer()
            stop()
            return
        }
        if let following {
            try? await play(following.id, from: nil)
        } else {
            stop()
        }
    }

    // MARK: - Private

    private func setCurrent(_ id: UUID?) {
        currentID = id
        defaults.set(id?.uuidString, forKey: Self.currentKey)
    }

    /// When a stream has finished downloading, reloads from the file at
    /// `time`. Done at seeks and resumes, where a reload isn't noticed.
    private func switchToDownload(at time: TimeInterval, autoplay: Bool) async -> Bool {
        guard streaming, let id = loadedID, id == currentID, let item = store.item(id),
              item.download == .downloaded else { return false }
        let source = await sources(item)
        guard source.isLocal, loadedID == id, streaming else { return false }
        listenLog.info("Listen switching \(id.uuidString, privacy: .public) from stream to its download")
        do {
            try await load(id, from: time, source: source, autoplay: autoplay)
            return true
        } catch {
            return false
        }
    }

    private func updateNetworkState() {
        guard streaming else { return resetNetworkState() }
        let stalled = status == .playing && engine.isStalled
        if buffering != stalled { buffering = stalled }
        let until = engine.bufferedUntil
        // Whole seconds are plenty for the UI and spare redraws.
        let rounded = until.map { $0.rounded(.down) }
        if bufferedUntil != rounded { bufferedUntil = rounded }
    }

    private func resetNetworkState() {
        if streaming { streaming = false }
        if buffering { buffering = false }
        if bufferedUntil != nil { bufferedUntil = nil }
    }

    private func savePosition() {
        ticksSinceSave = 0
        guard let currentID, loadedID == currentID else { return }
        let elapsed = engine.currentTime
        position = elapsed
        store.update(currentID) { $0.position = elapsed }
    }

    private func showNowPlaying() {
        guard let current else { return }
        nowPlaying?.show(current, position: position, duration: duration, rate: rate, playing: status == .playing)
    }
}
