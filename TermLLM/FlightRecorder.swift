import Foundation

enum FlightEvent: String, Codable {
    case launch, active, inactive, background
    case nativeStall, nativeRecovered, pageStall, pageRecovered
    case browserCreated, browserRemoved, navigationStarted, documentCommitted
    case navigationFinished, navigationFailed, processTerminated, recoveryRequested
    case bridgeStarted, bridgeSucceeded, bridgeFailed
}

enum FlightBridge: String, Codable { case deviceTools, notifications }

/// Deliberately no string payload, URL, tool/method name, error or page-supplied
/// identity. Correlation IDs are generated locally by the recorder/monitors.
struct FlightRecord: Codable {
    let event: FlightEvent
    let timestamp: Date
    let runID: UUID
    let browserID: UUID?
    let documentID: UUID?
    let operationID: UUID?
    var duration: TimeInterval?
    let bridge: FlightBridge?
}

final class FlightRecorder {
    static let shared = FlightRecorder()

    struct Limits {
        var maximumEvents = 512
        var maximumBytes = 256 * 1024
        var maximumAge: TimeInterval = 7 * 24 * 60 * 60
        var maximumPending = 128
    }

    private struct Snapshot: Codable {
        let version: Int
        let events: [FlightRecord]
    }

    private enum Notice: String {
        case none = "No history reset."
        case corrupt = "Unreadable history was discarded."
        case oversized = "Oversized history was discarded."
    }

    private let runID = UUID()
    private let queue: DispatchQueue
    private let admission = NSLock()
    private var pending: [FlightRecord] = [] // admission lock only; never held during IO
    private var scheduled = false
    private var dropped: UInt64 = 0
    private let limits: Limits
    private let clock: () -> Date
    private let requestedDirectory: URL?
    // Everything below is confined to queue.
    private var directory: URL?
    private var events: [FlightRecord] = []
    private var persistenceAvailable = false
    private var notice = Notice.none
    private var lastExportedAt: Date?

    /// Directory/clock injection is ordinary storage dependency injection, not a
    /// release stall hook. No file IO (including initial loading) occurs here.
    init(directory: URL? = nil, limits: Limits = Limits(), clock: @escaping () -> Date = Date.init,
         storageQueue: DispatchQueue? = nil) {
        queue = storageQueue ?? DispatchQueue(label: "app.diagnostics.storage", qos: .utility)
        var bounds = limits
        bounds.maximumEvents = min(2048, max(1, bounds.maximumEvents))
        bounds.maximumBytes = min(1024 * 1024, max(256, bounds.maximumBytes))
        bounds.maximumPending = min(512, max(1, bounds.maximumPending))
        bounds.maximumAge = bounds.maximumAge.isFinite ? min(30 * 86400, max(0, bounds.maximumAge)) : 7 * 86400
        self.limits = bounds
        self.clock = clock
        requestedDirectory = directory
        queue.async { self.load() }
    }

    func record(event: FlightEvent, browserID: UUID? = nil, documentID: UUID? = nil,
                operationID: UUID? = nil, duration: TimeInterval? = nil, bridge: FlightBridge? = nil) {
        let entry = FlightRecord(event: event, timestamp: clock(), runID: runID,
                                 browserID: browserID, documentID: documentID, operationID: operationID,
                                 duration: Self.safeDuration(duration), bridge: bridge)
        admission.lock()
        guard pending.count < limits.maximumPending else {
            if dropped < UInt64.max { dropped += 1 }
            admission.unlock()
            return
        }
        pending.append(entry)
        let needsSchedule = !scheduled
        scheduled = true
        admission.unlock()
        if needsSchedule {
            // Coalesce bursts, and admit at most one scheduled drain. A timeout
            // or a flood cannot create one dispatch closure per bridge event.
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.flush(scheduledDrain: true) }
        }
    }

    func report() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                self.flush(scheduledDrain: false)
                continuation.resume(returning: self.makeReport())
            }
        }
    }

    /// One replaceable, bounded, user-requested snapshot; no automatic upload.
    func export() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.flush(scheduledDrain: false)
                guard let directory = self.directory else {
                    continuation.resume(returning: nil)
                    return
                }
                let url = directory.appendingPathComponent("freeze-diagnostics.txt")
                do {
                    try Data(self.makeReport().utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    self.lastExportedAt = self.clock()
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(returning: nil) // never expose raw storage errors/paths
                }
            }
        }
    }

    private static func safeDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 86400)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private func load() {
        do {
            guard var root = requestedDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("FreezeDiagnostics", isDirectory: true) else { return }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            directory = root
            // An export is a deliberate snapshot, not a second history archive.
            // Remove the previous run's snapshot; subsequent exports replace it.
            try? FileManager.default.removeItem(at: root.appendingPathComponent("freeze-diagnostics.txt"))
            let url = root.appendingPathComponent("flight-recorder.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                // Bounded read even if an old version/corrupt file exceeds cap.
                let data = try file.read(upToCount: limits.maximumBytes + 1) ?? Data()
                if data.count > limits.maximumBytes {
                    notice = .oversized
                } else {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .millisecondsSince1970
                    if let snapshot = try? decoder.decode(Snapshot.self, from: data), snapshot.version == 1 {
                        events = snapshot.events.map { entry in
                            var entry = entry
                            entry.duration = Self.safeDuration(entry.duration)
                            return entry
                        }
                    } else { notice = .corrupt }
                }
            }
            persist()
        } catch {
            persistenceAvailable = false
        }
    }

    private func flush(scheduledDrain: Bool) {
        admission.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        // A report may flush early, but must not release a still-scheduled
        // task's admission slot and allow delayed dispatch blocks to accumulate.
        if scheduledDrain { scheduled = false }
        admission.unlock()
        if scheduledDrain && batch.isEmpty { return }
        events.append(contentsOf: batch)
        persist()
    }

    private func boundedData() -> Data {
        let now = clock().timeIntervalSince1970
        events.removeAll {
            let timestamp = $0.timestamp.timeIntervalSince1970
            return !timestamp.isFinite || timestamp < now - limits.maximumAge || timestamp > now + 60
        }
        if events.count > limits.maximumEvents { events.removeFirst(events.count - limits.maximumEvents) }
        let encoder = Self.encoder()
        var data = (try? encoder.encode(Snapshot(version: 1, events: events))) ?? Data()
        while data.count > limits.maximumBytes, !events.isEmpty {
            events.removeFirst()
            data = (try? encoder.encode(Snapshot(version: 1, events: events))) ?? Data()
        }
        return data
    }

    private func persist() {
        let data = boundedData()
        guard let directory else { persistenceAvailable = false; return }
        if let lastExportedAt {
            let age = clock().timeIntervalSince(lastExportedAt)
            if age > limits.maximumAge || age < -60 {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("freeze-diagnostics.txt"))
                self.lastExportedAt = nil
            }
        }
        do {
            try data.write(to: directory.appendingPathComponent("flight-recorder.json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            persistenceAvailable = true
        } catch { persistenceAvailable = false }
    }

    private func makeReport() -> String {
        admission.lock()
        let dropped = self.dropped
        admission.unlock()
        let status = persistenceAvailable ? "Persistence available." : "Persistence unavailable; in-memory events may be lost."
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return """
        term-llm freeze diagnostics — schema 1
        Exporting app: \(version) (\(build)); OS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion).
        Environment describes this export, not necessarily earlier recorded runs.
        Timing observations only, not crash reports or stack traces.
        \(status) \(notice.rawValue)
        Dropped on admission this run: \(dropped)
        Limits: \(limits.maximumEvents) events, \(limits.maximumBytes) history bytes, \(Int(limits.maximumAge)) seconds.
        No chat, audio, credentials, URLs, arguments, results or raw error text.
        \(String(decoding: boundedData(), as: UTF8.self))
        """
    }
}
