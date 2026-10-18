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

    /// Runs before this player starts audio (e.g. to pause Apple Music).
    @ObservationIgnored var willStartPlayback: (() -> Void)?

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
    var showsBar: Bool { current != nil && !barHidden }

    // MARK: - Starting

    /// Plays `id` from `start` (default: where it was left).
    func play(_ id: UUID, from start: TimeInterval? = nil) async throws {
        guard let item = store.item(id) else { throw ListenError.notFound(id.uuidString) }
        willStartPlayback?()
        if let currentID, currentID != id, loadedID == currentID { savePosition() }
        generation += 1
        let attempt = generation
        setCurrent(id)
        barHidden = false
        notice = nil
        status = .loading
        let startAt = start ?? item.resumePosition()
        position = startAt
        duration = item.duration
        store.update(id) {
            if !$0.isQueued { $0.status = .unplayed }
            $0.lastPlayedAt = self.now()
        }
        do {
            let source = await sources(item)
            guard attempt == generation else { return }
            try await engine.load(source, startAt: startAt)
            guard attempt == generation else { return }
            loadedID = id
            try engine.play(rate: rate)
            status = .playing
            duration = engine.duration ?? item.duration
            store.update(id) {
                $0.status = .inProgress
                if let duration = self.duration { $0.duration = duration }
            }
            showNowPlaying()
        } catch {
            guard attempt == generation else { return }
            loadedID = nil
            let message = error.localizedDescription
            status = .failed(message)
            notice = message
            throw error
        }
    }

    /// Resumes the current item, or starts Up Next.
    func resume() async throws {
        if let current, loadedID == current.id, status == .paused {
            willStartPlayback?()
            try engine.play(rate: rate)
            status = .playing
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
        guard status == .playing || status == .loading else { return }
        if status == .loading { generation += 1; loadedID = nil }
        engine.pause()
        status = .paused
        savePosition()
        showNowPlaying()
    }

    /// Unloads everything; the mini player goes away.
    func stop() {
        if loadedID != nil { savePosition() }
        generation += 1
        engine.stop()
        loadedID = nil
        status = .idle
        setCurrent(nil)
        cancelSleepTimer()
        nowPlaying?.clear()
    }

    func seek(to seconds: TimeInterval) async {
        let target = max(0, duration.map { min(seconds, $0) } ?? seconds)
        position = target
        if loadedID != nil && loadedID == currentID {
            await engine.seek(to: target)
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
            ticksSinceSave += 1
            if status == .playing, ticksSinceSave >= Self.saveInterval { savePosition() }
            if let sleepAt, now() >= sleepAt {
                cancelSleepTimer()
                pause()
            }
        case .ended:
            Task { await finishCurrent() }
        case .failed(let message):
            loadedID = nil
            status = .failed(message)
            notice = "Playback stopped: \(message)"
            savePosition()
        case .interrupted:
            guard status == .playing else { return }
            status = .paused
            pausedByInterruption = true
            savePosition()
            showNowPlaying()
        case .interruptionEnded(let shouldResume):
            guard pausedByInterruption else { return }
            pausedByInterruption = false
            if shouldResume { Task { try? await resume() } }
        case .outputLost:
            pause()
        }
    }

    private func finishCurrent() async {
        guard let id = currentID else { return }
        let following = store.upNext(after: id)
        try? store.setStatus([id], .played)
        store.update(id) { $0.lastPlayedAt = self.now() }
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
