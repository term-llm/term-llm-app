import Foundation

/// URLSession-delivered response-body bytes for all Listen-managed transfers,
/// not unique cached bytes or exact network-interface usage: URLSession may
/// deliver a body from its in-memory HTTP cache. Retries, overlapping ranges and
/// discarded/failed bodies count again. Direct AVPlayer HTTP/video streams,
/// artwork and HTTP headers do not pass through this ledger. There are no
/// retroactive totals or URLs here.
final class ListenNetworkUsage: @unchecked Sendable {
    struct Snapshot: Sendable {
        let todayBytes: Int64
        let weekBytes: Int64
        let monthBytes: Int64
        let totalBytes: Int64
        /// Last 60 seconds, to one-second resolution; in-memory since launch.
        let recentBytes: Int64
        let startedAt: Date
    }

    static let shared = ListenNetworkUsage(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ListenNetworkUsage.json"))

    private struct Day: Codable {
        let start: Date
        var bytes: Int64
    }

    private struct Ledger: Codable {
        let startedAt: Date
        var totalBytes: Int64 = 0
        var days: [Day] = []
    }

    private let queue = DispatchQueue(label: "TermLLM.ListenNetworkUsage", qos: .utility)
    private let fileURL: URL
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private let flushInterval: TimeInterval
    // All mutable state after initialization belongs to queue.
    private var ledger: Ledger
    private var recent: [Int64: Int64] = [:]
    private var latestSecond: Int64 = .min
    private var dirty = false
    private var pendingWrite: DispatchWorkItem?

    /// `fileURL` must be owned by this instance (one writer). Daily buckets use
    /// the recording calendar/time zone; a later time-zone change cannot exactly
    /// redivide old days. Keep the injected calendar and snapshot calendar alike
    /// in deterministic tests. Lifetime totals survive daily-bucket pruning.
    init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .autoupdatingCurrent, flushInterval: TimeInterval = 5) {
        self.fileURL = fileURL
        self.clock = now
        self.calendar = calendar
        self.flushInterval = max(0, flushInterval)
        let date = now()
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Ledger.self, from: data),
           saved.totalBytes >= 0, saved.days.allSatisfy({ $0.bytes >= 0 }) {
            ledger = saved
        } else {
            ledger = Ledger(startedAt: date)
        }
        // Persist even an empty ledger's start date, and trim on relaunch.
        queue.sync {
            pruneDays(now: date)
            dirty = true
            writeIfNeeded()
        }
    }

    /// Cheap enqueue from URLSession's delegate: no disk I/O, URL or Data retained.
    /// Call for every received chunk, before any transfer validation/filtering.
    func record(bytes: Int64, at date: Date? = nil) {
        guard bytes > 0 else { return }
        let date = date ?? clock()
        queue.async { [self] in
            let start = calendar.startOfDay(for: date)
            if let index = ledger.days.firstIndex(where: { $0.start == start }) {
                ledger.days[index].bytes += bytes
            } else {
                ledger.days.append(Day(start: start, bytes: bytes))
            }
            ledger.totalBytes += bytes
            pruneDays(now: date)

            let second = Int64(floor(date.timeIntervalSince1970))
            latestSecond = max(latestSecond, second)
            recent[second, default: 0] += bytes
            recent = recent.filter { $0.key > latestSecond - 60 }
            dirty = true
            scheduleWrite()
        }
    }

    func snapshot(now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        queue.sync {
            func bytes(in component: Calendar.Component) -> Int64 {
                guard let interval = calendar.dateInterval(of: component, for: now) else { return 0 }
                return ledger.days.reduce(0) { sum, day in
                    sum + (day.start >= interval.start && day.start < interval.end ? day.bytes : 0)
                }
            }
            let second = Int64(floor(now.timeIntervalSince1970))
            return Snapshot(todayBytes: bytes(in: .day), weekBytes: bytes(in: .weekOfYear),
                            monthBytes: bytes(in: .month), totalBytes: ledger.totalBytes,
                            recentBytes: recent.reduce(0) { sum, entry in
                                sum + (entry.key > second - 60 && entry.key <= second ? entry.value : 0)
                            }, startedAt: ledger.startedAt)
        }
    }

    /// A completion (including failure/cancellation) waits for queued accounting
    /// and an atomic write. Abrupt termination can still lose the last batch.
    func flush() {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            writeIfNeeded()
        }
    }

    private func pruneDays(now: Date) {
        let today = calendar.startOfDay(for: now)
        let oldest = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        ledger.days = Array(ledger.days.filter { $0.start >= oldest }
            .sorted { $0.start < $1.start }.suffix(90))
    }

    private func scheduleWrite() {
        guard pendingWrite == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWrite = nil
            self.writeIfNeeded()
        }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + flushInterval, execute: work)
    }

    private func writeIfNeeded() {
        guard dirty else { return }
        do {
            let data = try JSONEncoder().encode(ledger)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            dirty = false
        } catch {
            // Keep dirty so the next chunk/completion retries. No paths, URLs or
            // credentials are logged. Storage failure must not break playback.
        }
    }
}
