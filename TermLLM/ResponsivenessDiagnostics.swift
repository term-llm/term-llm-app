import Foundation
import UIKit
import WebKit

/// Clock-injected state shared by the native and page monitors. A timed-out probe
/// keeps its transport slot: a timeout must never enqueue another WebKit call.
struct ResponsivenessState {
    struct Probe: Equatable {
        let id: UUID
        let document: UUID
    }
    enum Signal: Equatable { case stalled, recovered(TimeInterval) }
    private(set) var document = UUID()
    private(set) var pending: Probe?
    private var started: TimeInterval = 0
    private var active = false
    private var graceUntil: TimeInterval = 0
    private var reported = false
    let threshold: TimeInterval
    let grace: TimeInterval

    init(threshold: TimeInterval = 5, grace: TimeInterval = 3) {
        self.threshold = threshold
        self.grace = grace
    }

    mutating func setActive(_ value: Bool, now: TimeInterval) {
        guard active != value else { return }
        active = value
        // Inactive intervals are not evidence of a hang. Start a fresh budget.
        graceUntil = now + grace
        started = graceUntil
        reported = false
    }

    mutating func resetGrace(now: TimeInterval) {
        graceUntil = now + grace
        started = graceUntil
        reported = false
    }

    mutating func navigate(now: TimeInterval) {
        document = UUID()
        graceUntil = now + grace
        reported = false
        // Keep the outstanding transport slot until its actual callback.
    }

    mutating func begin(now: TimeInterval) -> Probe? {
        guard active, now >= graceUntil, pending == nil else { return nil }
        let probe = Probe(id: UUID(), document: document)
        pending = probe
        started = now
        return probe
    }

    mutating func tick(now: TimeInterval) -> Signal? {
        guard active, let pending, pending.document == document,
              now >= graceUntil, now - started >= threshold, !reported else { return nil }
        reported = true
        return .stalled
    }

    mutating func complete(_ probe: Probe, now: TimeInterval) -> Signal? {
        guard pending == probe else { return nil }
        pending = nil
        guard active, probe.document == document, reported else { return nil }
        reported = false
        return .recovered(max(0, now - started))
    }
}

/// All state and timing work runs off-main. At most one main-queue ping is
/// outstanding. Public UIKit lifecycle notifications are installed at launch.
final class NativeResponsivenessWatchdog {
    static let shared = NativeResponsivenessWatchdog()
    private let queue = DispatchQueue(label: "app.diagnostics.watchdog", qos: .utility)
    private var state = ResponsivenessState()
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var lastTick: TimeInterval?

    @MainActor
    func start() {
        guard timer == nil else { return } // called once, on the main thread
        FlightRecorder.shared.record(event: .launch)
        let center = NotificationCenter.default
        for (name, event) in [(UIApplication.didBecomeActiveNotification, FlightEvent.active),
                              (UIApplication.willResignActiveNotification, .inactive),
                              (UIApplication.didEnterBackgroundNotification, .background)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                FlightRecorder.shared.record(event: event)
                self?.setActive(event == .active)
            })
        }
        setActive(UIApplication.shared.applicationState == .active)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func setActive(_ active: Bool) {
        queue.async { self.state.setActive(active, now: ProcessInfo.processInfo.systemUptime) }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // A suspended watchdog cannot diagnose main-thread responsiveness. Give
        // discontinuities a new grace period rather than claiming a sleep stall.
        if let lastTick, now - lastTick > 3 {
            state.resetGrace(now: now)
        }
        lastTick = now
        if let signal = state.tick(now: now) { record(signal) }
        guard let probe = state.begin(now: now) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let acknowledged = ProcessInfo.processInfo.systemUptime
            self.queue.async {
                if let signal = self.state.complete(probe, now: acknowledged) { self.record(signal) }
            }
        }
    }

    private func record(_ signal: ResponsivenessState.Signal) {
        switch signal {
        case .stalled: FlightRecorder.shared.record(event: .nativeStall)
        case .recovered(let duration): FlightRecorder.shared.record(event: .nativeRecovered, duration: duration)
        }
    }
}

/// One monitor per WKWebView, independent of the app-wide native ping. The
/// constant expression inspects no DOM, URL, frontend state or user content.
final class PageResponsivenessMonitor {
    let browserID = UUID()
    private(set) var state = ResponsivenessState()
    private weak var view: WKWebView?
    private var timer: Timer?
    private var active = false
    private var navigating = true
    private var lastTick: TimeInterval?

    func attach(_ view: WKWebView) {
        self.view = view
        FlightRecorder.shared.record(event: .browserCreated, browserID: browserID)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setActive(_ value: Bool) {
        active = value
        state.setActive(value && !navigating, now: ProcessInfo.processInfo.systemUptime)
    }

    func navigationStarted() {
        navigating = true
        state.setActive(false, now: ProcessInfo.processInfo.systemUptime)
        record(.navigationStarted)
    }

    func committed() {
        state.navigate(now: ProcessInfo.processInfo.systemUptime)
        record(.documentCommitted)
    }

    func navigationEnded(failed: Bool) {
        navigating = false
        state.setActive(active, now: ProcessInfo.processInfo.systemUptime)
        record(failed ? .navigationFailed : .navigationFinished)
    }

    func terminated() {
        record(.processTerminated)
        navigating = true
        state.setActive(false, now: ProcessInfo.processInfo.systemUptime)
        state.navigate(now: ProcessInfo.processInfo.systemUptime)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        state.setActive(false, now: ProcessInfo.processInfo.systemUptime)
        view = nil
        record(.browserRemoved)
    }

    deinit { timer?.invalidate() }

    func record(_ event: FlightEvent) {
        FlightRecorder.shared.record(event: event, browserID: browserID, documentID: state.document)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastTick, now - lastTick > 3 {
            state.setActive(false, now: now)
            state.setActive(active && !navigating, now: now)
        }
        lastTick = now
        if let signal = state.tick(now: now) { record(signal) }
        guard let view, let probe = state.begin(now: now) else { return }
        view.evaluateJavaScript("1", in: nil, in: .page) { [weak self] _ in
            guard let self else { return }
            // Success or error means WebKit answered; never log its value/error.
            if let signal = self.state.complete(probe, now: ProcessInfo.processInfo.systemUptime) {
                self.record(signal)
            }
        }
    }

    private func record(_ signal: ResponsivenessState.Signal) {
        switch signal {
        case .stalled: record(.pageStall)
        case .recovered(let duration):
            FlightRecorder.shared.record(event: .pageRecovered, browserID: browserID,
                                         documentID: state.document, duration: duration)
        }
    }
}

/// One generated operation ID pairs start/end without ever accepting a bridge
/// method name, tool name, argument, result, document-provided ID or error text.
struct BridgeFlightCall {
    let bridge: FlightBridge
    let context: (UUID, UUID)?
    let operation = UUID()
    let started = ProcessInfo.processInfo.systemUptime
    let recorder: FlightRecorder

    init(bridge: FlightBridge, context: (UUID, UUID)?, recorder: FlightRecorder = .shared) {
        self.bridge = bridge
        self.context = context
        self.recorder = recorder
        recorder.record(event: .bridgeStarted, browserID: context?.0, documentID: context?.1,
                        operationID: operation, bridge: bridge)
    }

    func finish(succeeded: Bool) {
        recorder.record(event: succeeded ? .bridgeSucceeded : .bridgeFailed,
                        browserID: context?.0, documentID: context?.1, operationID: operation,
                        duration: ProcessInfo.processInfo.systemUptime - started, bridge: bridge)
    }
}
