import Darwin
import Foundation

/// Device and app-process readings, taken by the monitor every few seconds.
/// CPU figures are in cores: 1.0 means one core fully busy for the interval.
struct NativeHealthSample: Equatable, Sendable {
    let uptime: TimeInterval
    let date: Date
    /// This app's process only. WebKit's page, GPU and network processes are
    /// separate processes and are not included.
    let appCPU: Double?
    /// Every process on the device, including WebKit's (nil if unavailable).
    let deviceCPU: Double?
    let cpuCount: Int
    let wakeupsPerSecond: Double?
    let footprintMB: Double?
    let thermal: ProcessInfo.ThermalState
    let lowPower: Bool
    let batteryLevel: Float?
    let charging: Bool?
    let appActive: Bool
    let appBackground: Bool
    /// Elapsed uptime used by the app CPU counter delta, including suspension.
    var cpuInterval: TimeInterval? = nil

    /// CPU used by other processes: WebKit's processes, the render server and iOS daemons.
    var otherCPU: Double? {
        guard let deviceCPU, let appCPU else { return nil }
        return max(0, deviceCPU - appCPU)
    }
}

struct ThreadUsage: Equatable, Sendable, Codable {
    let name: String
    /// Fraction of one core (recent, decaying), 1.0 = 100%.
    let cpu: Double
    /// Stable within this process lifetime, unlike a Mach port name.
    var threadID: UInt64? = nil
    var label: String { threadID.map { "\(name)#\($0)" } ?? name }
}

/// Reads public Mach/BSD counters. Each call costs a few system calls.
/// Rates need at least half a second between readings; a sooner reading
/// keeps the previous baseline rather than replacing it.
final class ProcessUsageSampler {
    private static let minimumInterval: TimeInterval = 0.5
    private var previousCPU: (uptime: TimeInterval, seconds: TimeInterval)?
    private var previousTicks: (uptime: TimeInterval, busy: UInt64, total: UInt64)?
    private var previousWakeups: (uptime: TimeInterval, count: UInt64)?
    private let host = mach_host_self()
    let cpuCount = ProcessInfo.processInfo.activeProcessorCount

    deinit { mach_port_deallocate(mach_task_self_, host) }

    @MainActor
    func sample(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, date: Date = Date(),
                appActive: Bool, appBackground: Bool) -> NativeHealthSample {
        var appCPU: Double?
        var cpuInterval: TimeInterval?
        if let seconds = Self.processCPUSeconds() {
            if let previous = previousCPU {
                if uptime - previous.uptime >= Self.minimumInterval {
                    cpuInterval = uptime - previous.uptime
                    appCPU = max(0, seconds - previous.seconds) / (uptime - previous.uptime)
                    previousCPU = (uptime, seconds)
                }
            } else {
                previousCPU = (uptime, seconds)
            }
        }
        var deviceCPU: Double?
        if let ticks = Self.deviceTicks(host: host) {
            if let previous = previousTicks {
                if uptime - previous.uptime >= Self.minimumInterval {
                    if ticks.total > previous.total, ticks.busy >= previous.busy {
                        let fraction = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
                        deviceCPU = min(1, max(0, fraction)) * Double(cpuCount)
                    }
                    previousTicks = (uptime, ticks.busy, ticks.total)
                }
            } else {
                previousTicks = (uptime, ticks.busy, ticks.total)
            }
        }
        var wakeups: Double?
        if let count = Self.wakeups() {
            if let previous = previousWakeups {
                if uptime - previous.uptime >= Self.minimumInterval {
                    if count >= previous.count { wakeups = Double(count - previous.count) / (uptime - previous.uptime) }
                    previousWakeups = (uptime, count)
                }
            } else {
                previousWakeups = (uptime, count)
            }
        }
        let battery = NativeDevice.battery()
        let charging: Bool? = switch battery.state {
        case "charging", "full": true
        case "unplugged": false
        default: nil
        }
        return NativeHealthSample(
            uptime: uptime, date: date, appCPU: appCPU, deviceCPU: deviceCPU, cpuCount: cpuCount,
            wakeupsPerSecond: wakeups, footprintMB: Self.footprintBytes().map { Double($0) / 1_048_576 },
            thermal: ProcessInfo.processInfo.thermalState, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: battery.level, charging: charging,
            appActive: appActive, appBackground: appBackground, cpuInterval: cpuInterval)
    }

    /// User + system CPU of every thread this process has run, including exited ones.
    static func processCPUSeconds() -> TimeInterval? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ value: timeval) -> TimeInterval { TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Aggregate scheduler ticks for all CPUs (busy = user + system + nice).
    static func deviceTicks(host: host_t) -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = withUnsafeBytes(of: info.cpu_ticks) { Array($0.bindMemory(to: natural_t.self)) }
        guard ticks.count >= Int(CPU_STATE_MAX) else { return nil }
        let user = UInt64(ticks[Int(CPU_STATE_USER)]), system = UInt64(ticks[Int(CPU_STATE_SYSTEM)])
        let idle = UInt64(ticks[Int(CPU_STATE_IDLE)]), nice = UInt64(ticks[Int(CPU_STATE_NICE)])
        return (user + system + nice, user + system + idle + nice)
    }

    /// Interrupt and package-idle wakeups of this process: timer storms show up here.
    static func wakeups() -> UInt64? {
        var info = task_power_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return info.task_interrupt_wakeups &+ info.task_platform_idle_wakeups
    }

    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// This process's busiest threads right now (WebKit's processes are not visible here).
    /// Main actor only, so `pthread_self()` identifies the main thread.
    @MainActor
    static func busiestThreads(limit: Int = 4, minimum: Double = 0.03) -> [ThreadUsage] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        let main = pthread_mach_thread_np(pthread_self())
        var result: [ThreadUsage] = []
        for index in 0..<Int(count) {
            var info = thread_extended_info_data_t()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[index], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &infoCount)
                }
            }
            guard status == KERN_SUCCESS else { continue }
            let usage = Double(info.pth_cpu_usage) / Double(TH_USAGE_SCALE)
            guard usage >= minimum else { continue }
            var name = withUnsafeBytes(of: info.pth_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            name = WebKitHealthProbe.token(name, limit: 48, allowingSpaces: true) ?? ""
            if list[index] == main { name = name.isEmpty ? "main" : "main:" + name }
            var identity = thread_identifier_info_data_t()
            var identityCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            let identityStatus = withUnsafeMutablePointer(to: &identity) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(identityCount)) {
                    thread_info(list[index], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identityCount)
                }
            }
            result.append(ThreadUsage(name: name.isEmpty ? "unnamed" : name, cpu: usage,
                                      threadID: identityStatus == KERN_SUCCESS ? identity.thread_id : nil))
        }
        return Array(result.sorted { $0.cpu > $1.cpu }.prefix(limit))
    }
}
