import Foundation

// MARK: - Minute history

struct MinuteAccumulator {
    private var start: Date?
    private var app: [Double] = []
    private var device: [Double] = []
    private var thermal = 0
    private var battery: Int?
    private var charging: Bool?
    private var samples = 0
    private var foreground = 0
    private var chat = 0
    private var webViews = 0
    private var memory: Int?
    private var pages: [WebPageHealthSample] = []
    /// (uptime, cumulative monitor nanoseconds) at the minute's first and last sample.
    private var costFirst: (uptime: TimeInterval, nanoseconds: UInt64)?
    private var costLast: (uptime: TimeInterval, nanoseconds: UInt64)?

    mutating func add(_ sample: WebPageHealthSample) { pages.append(sample) }

    /// Returns the previous minute when `sample` starts a new one.
    mutating func add(_ sample: NativeHealthSample, chatOnScreen: Bool, webViews alive: Int,
                      monitorNanoseconds: UInt64 = 0, calendar: Calendar = .current) -> WebKitHealthMinute? {
        let minute = calendar.dateInterval(of: .minute, for: sample.date)?.start ?? sample.date
        var finished: WebKitHealthMinute?
        if let start, start != minute { finished = summary(start: start) }
        if start != minute { self = MinuteAccumulator(); start = minute }
        if costFirst == nil { costFirst = (sample.uptime, monitorNanoseconds) }
        costLast = (sample.uptime, monitorNanoseconds)
        if let value = sample.appCPU { app.append(value) }
        if let value = sample.deviceCPU { device.append(value) }
        thermal = max(thermal, sample.thermal.rawValue)
        battery = sample.batteryLevel.map { Int(($0 * 100).rounded()) }
        charging = sample.charging
        samples += 1
        if sample.appActive { foreground += 1 }
        if chatOnScreen { chat += 1 }
        webViews = max(webViews, alive)
        memory = sample.footprintMB.map { Int($0.rounded()) }
        return finished
    }

    private func summary(start: Date) -> WebKitHealthMinute {
        let count = Double(max(samples, 1))
        let span = pages.reduce(0) { $0 + $1.spanSeconds }
        let counted = pages.reduce(0) { $0 + $1.mutationSeconds }
        var monitor: Double?
        if let first = costFirst, let last = costLast, last.uptime - first.uptime >= 10, last.nanoseconds >= first.nanoseconds {
            monitor = Double(last.nanoseconds - first.nanoseconds) / 1_000_000_000 / (last.uptime - first.uptime)
        }
        return WebKitHealthMinute(
            start: start, app: optionalAverage(app), appPeak: app.max(), device: optionalAverage(device), devicePeak: device.max(),
            thermal: thermal, battery: battery, charging: charging,
            foreground: Double(foreground) / count, chatOnScreen: Double(chat) / count,
            pageReports: pages.count,
            pageVisible: pages.isEmpty ? nil : Double(pages.filter(\.isVisible).count) / Double(pages.count),
            busy: pages.isEmpty ? nil : WebKitHealthFindings.average(pages.map(\.busyFraction)),
            fps: span > 0 ? Double(pages.reduce(0) { $0 + $1.frames }) / span : nil,
            animations: pages.map(\.runningAnimations).max(),
            repainting: pages.map(\.repaintingAnimations.count).max(),
            mutations: counted >= 0.2 ? Double(pages.reduce(0) { $0 + $1.mutations }) / counted : nil,
            requests: span > 0 ? Double(pages.reduce(0) { $0 + $1.resources }) * 60 / span : nil,
            audio: pages.map(\.audioContextsRunning).max(),
            webViews: webViews, memoryMB: memory,
            probe: span > 0 ? pages.reduce(0) { $0 + $1.probeMilliseconds } / 1000 / span : nil,
            monitor: monitor)
    }
}

// MARK: - Persistence

/// JSON lines in Application Support, excluded from backups. Two small
/// rotating files per kind; writes happen off the main thread.
final class WebKitHealthJournal: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.termllm.webkit-health.journal", qos: .utility)
    let directory: URL
    static let maximumBytes = 256 * 1024

    init(directory: URL) { self.directory = directory }

    static func standard() -> WebKitHealthJournal? {
        guard !HubFixture.isEnabled, !PhoneHubFixture.isEnabled,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return WebKitHealthJournal(directory: base.appendingPathComponent("Diagnostics/WebKitHealth", isDirectory: true))
    }

    func append(event: WebKitHealthEvent) { append(event, to: "events") }
    func append(minute: WebKitHealthMinute) { append(minute, to: "minutes") }

    func load(_ completion: @escaping @Sendable ([WebKitHealthEvent], [WebKitHealthMinute]) -> Void) {
        queue.async { [self] in
            completion(Array(read("events", as: WebKitHealthEvent.self).suffix(200)),
                       Array(read("minutes", as: WebKitHealthMinute.self).suffix(360)))
        }
    }

    func clear() {
        queue.async { [self] in
            for name in ["events", "minutes"] {
                try? FileManager.default.removeItem(at: file(name))
                try? FileManager.default.removeItem(at: file(name, old: true))
            }
        }
    }

    private func file(_ name: String, old: Bool = false) -> URL {
        directory.appendingPathComponent(name + (old ? ".old" : "") + ".jsonl")
    }

    private func append<Value: Encodable & Sendable>(_ value: Value, to name: String) {
        queue.async { [self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(value) else { return }
            line.append(0x0A)
            let manager = FileManager.default
            if !manager.fileExists(atPath: directory.path) {
                try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var url = directory
                try? url.setResourceValues(values)
            }
            let url = file(name)
            if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int, size >= Self.maximumBytes {
                try? manager.removeItem(at: file(name, old: true))
                try? manager.moveItem(at: url, to: file(name, old: true))
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }

    private func read<Value: Decodable>(_ name: String, as type: Value.Type) -> [Value] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var values: [Value] = []
        for url in [file(name, old: true), file(name)] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) {
                if let value = try? decoder.decode(Value.self, from: Data(line)) { values.append(value) }
            }
        }
        return values
    }
}
