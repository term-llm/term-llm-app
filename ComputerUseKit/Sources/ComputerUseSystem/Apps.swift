import AppKit
import ComputerUseCore
import Darwin

/// Resolve, launch in the background, and list apps. Every system look goes
/// through System, including paths and the clock, so tests can replace the Mac.
public final class Apps {
    public static let launchLimit = 5.0, launchPoll = 0.05, recentDays = 14, recentSeconds = 1_209_600.0
    public static let catalogLimit = 2.0, queryLimit = 10.0
    public static let openOptions = ["activates": false, "allowsRunningApplicationSubstitution": true]
    public static let bundles = [".app", ".xpc", ".appex", ".bundle"]
    public static let dataVolume = "/System/Volumes/Data", pidPrefix = "#pid:"
    public static let electronClass = "AtomApplication", chromiumClass = "BrowserCrApplication", webScheme = "http"
    public static let catalyst = "_AXExhibitsMacCatalystBehavior"
    public static let appFolders = ["/Applications", "/Applications/Utilities", "~/Applications", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices", "/System/Library/CoreServices/Applications", "/System/Volumes/Preboot/Cryptexes/App/System/Applications"]
    public static let filePanels: Set<String> = ["save-panel", "open-panel", "GoToWindow"]
    public static let usageQuery = "kMDItemContentType == \"com.apple.application-bundle\" && kMDItemFSName == \"*.app\" && kMDItemLastUsedDate_Ranking >= $time.today(-14)"
    public static let usageAttributes = ["kMDItemPath", "kMDItemLastUsedDate", "kMDItemLastUsedDate_Ranking", "kMDItemUseCount", "kMDItemDisplayName", "kMDItemCFBundleIdentifier"]
    public struct Proc {
        public var pid: pid_t; public var path: String?; public var bundleID: String; public var name: String; public var executable: String
        public init(pid: pid_t, path: String?, bundleID: String = "", name: String = "", executable: String = "") {
            self.pid = pid; self.path = path; self.bundleID = bundleID; self.name = name; self.executable = executable
        }
    }
    public struct Used {
        public var path: String; public var lastUsed: TimeInterval?; public var useCount: Int?; public var name: String?; public var bundleID: String?
        public init(path: String, lastUsed: TimeInterval? = nil, useCount: Int? = nil, name: String? = nil, bundleID: String? = nil) {
            self.path = path; self.lastUsed = lastUsed; self.useCount = useCount; self.name = name; self.bundleID = bundleID
        }
    }
    public struct System {
        public var running: () -> [Proc] = { RealApps.shared.running() }
        public var executable: (pid_t) -> String = Apps.executable
        public var regular: (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
        public var bundlePaths: (String) -> [String] = { id in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path) }
        public var named: (String) -> String? = { NSWorkspace.shared.fullPath(forApplication: $0) }
        public var open: (String) -> pid_t? = Apps.openBackground
        public var frontPIDs: () -> [pid_t] = { Windows.shared.serverWindows().filter { $0.layer == 0 }.map(\.pid) }
        public var used: () -> [Used] = Apps.queryUsed
        public var info: (String) -> [String: Any]? = Apps.readInfo
        public var entries: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        public var realPath: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        public var expandUser: (String) -> String = { ($0 as NSString).expandingTildeInPath }
        public var ownPID: () -> pid_t = { getpid() }
        public var panelServices: () -> [pid_t: pid_t] = Apps.systemPanelServices
        public var processBundleID: (pid_t) -> String = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier ?? "" }
        public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        public var wallTime: () -> TimeInterval = { Date().timeIntervalSince1970 }
        public var sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
        public var keyWindow: (AppTarget) throws -> ComputerUseCore.WindowRef = Windows.keyWindow
        public init() {}
    }
    public static let shared = Apps()
    public var system: System
    private let lock = NSLock()
    private var kinds: [String: AppKind] = [:], catalystPIDs: [pid_t: Bool] = [:]
    private var kindOrder: [String] = [], catalystOrder: [pid_t] = []
    private var catalogRows: [Used]?, catalogGroup: DispatchGroup?
    public init(system: System = .init()) { self.system = system }
    public static func clean(_ path: String) -> String {
        // Lexical POSIX normpath, not NSString.standardizingPath: that also expands
        // tildes and can consult the filesystem. Symlinks belong to System.realPath.
        let absolute = path.hasPrefix("/")
        let prefix = path.hasPrefix("//") && !path.hasPrefix("///") ? "//" : (absolute ? "/" : "")
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                if let last = parts.last, last != ".." { parts.removeLast() }
                else if !absolute { parts.append(part) }
            } else { parts.append(part) }
        }
        var clean = prefix + parts.joined(separator: "/")
        if clean.isEmpty { clean = "." }
        return clean.hasPrefix(dataVolume + "/") ? String(clean.dropFirst(dataVolume.count)) : clean
    }
    public static func readInfo(_ path: String) -> [String: Any]? {
        for inner in ["Contents/Info.plist", "WrappedBundle/Info.plist", "Info.plist"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(inner)),
                  let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
            return value as? [String: Any]
        }
        return nil
    }
    public static func pids() -> [pid_t] {
        let room = Int(proc_listallpids(nil, 0)) + 64
        var values = [pid_t](repeating: 0, count: max(64, room))
        let count = values.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(values.prefix(max(0, min(Int(count), values.count))))
    }
    public static func executable(_ pid: pid_t) -> String {
        var bytes = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        return length > 0 ? clean(String(cString: bytes)) : ""
    }
    public static func systemPanelServices() -> [pid_t: pid_t] {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let handle = dlopen(nil, RTLD_LAZY) else { return [:] }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return [:] }
        let responsible = unsafeBitCast(symbol, to: Responsible.self)
        return Dictionary(uniqueKeysWithValues: pids().filter { executable($0).hasSuffix("/" + Limits.panelService) }.map { ($0, responsible($0)) })
    }
    public static func openBackground(_ path: String) -> pid_t? {
        let done = DispatchSemaphore(value: 0), result = OpenResult()
        MainThread.onMain {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = openOptions["activates"]!
            config.allowsRunningApplicationSubstitution = openOptions["allowsRunningApplicationSubstitution"]!
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { app, _ in
                result.lock.lock(); result.pid = app?.processIdentifier; result.lock.unlock(); done.signal()
            }
        }
        _ = done.wait(timeout: .now() + launchLimit)
        result.lock.lock(); defer { result.lock.unlock() }; return result.pid
    }
    public static func queryUsed() -> [Used] {
        autoreleasepool {
            let query = NSMetadataQuery()
            query.predicate = NSPredicate(fromMetadataQueryString: usageQuery)
            query.start()
            defer { query.stop() }
            let end = ProcessInfo.processInfo.systemUptime + queryLimit
            while query.isGathering && ProcessInfo.processInfo.systemUptime < end {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            query.disableUpdates()
            return (query.results as? [NSMetadataItem] ?? []).compactMap { item in
                guard let path = item.value(forAttribute: usageAttributes[0]) as? String else { return nil }
                let used = (item.value(forAttribute: usageAttributes[1]) as? Date) ?? (item.value(forAttribute: usageAttributes[2]) as? Date)
                return Used(path: clean(path), lastUsed: used?.timeIntervalSince1970,
                            useCount: (item.value(forAttribute: usageAttributes[3]) as? NSNumber)?.intValue,
                            name: item.value(forAttribute: usageAttributes[4]) as? String,
                            bundleID: item.value(forAttribute: usageAttributes[5]) as? String)
            }
        }
    }
    func spellings(_ path: String) -> Set<String> { [path, system.realPath(path)] }
    func stem(_ path: String) -> String { let name = (path as NSString).lastPathComponent; return name.hasSuffix(".app") ? String(name.dropLast(4)) : name }
    public func procTarget(_ proc: Proc) -> AppTarget {
        let path = proc.path ?? "\(Self.pidPrefix)\(proc.pid)"
        // With no bundle id, the path stands in: approval never covers two programs.
        return AppTarget(path: path, bundleID: proc.bundleID.isEmpty ? path : proc.bundleID, name: proc.name.isEmpty ? proc.executable : proc.name, pid: proc.pid)
    }
    func target(_ path: String, procs: [Proc]) -> AppTarget {
        let paths = spellings(path)
        if let live = procs.first(where: { $0.path.map(paths.contains) ?? false }) { return procTarget(live) }
        let info = system.info(path) ?? [:]
        return AppTarget(path: path, bundleID: info["CFBundleIdentifier"] as? String ?? "", name: (info["CFBundleDisplayName"] as? String).nonempty ?? (info["CFBundleName"] as? String).nonempty ?? stem(path))
    }
    func dockedFirst(_ procs: [Proc]) -> Proc { procs.first { system.regular($0.pid) } ?? procs[0] }
    func byName(_ name: String, procs: [Proc], same: (String, String) -> Bool) -> AppTarget? {
        let named = procs.filter { same($0.name, name) }
        if !named.isEmpty { return procTarget(dockedFirst(named)) }
        for folder in Self.appFolders.map(system.expandUser) {
            for entry in system.entries(folder).sorted() where entry.hasSuffix(".app") && same(stem(entry), name) { return target(folder + "/" + entry, procs: procs) }
        }
        if let path = system.named(name) { return target(Self.clean(path), procs: procs) }
        let programs = procs.filter { same($0.executable, name) }
        return programs.isEmpty ? nil : procTarget(dockedFirst(programs))
    }
    public func resolve(_ identifier: String) throws -> AppTarget {
        if identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Errors.make("invalid_app", ["identifier": identifier]) }
        let procs = system.running()
        if identifier.hasPrefix(Self.pidPrefix), identifier.dropFirst(Self.pidPrefix.count).allSatisfy({ $0.isNumber }), let pid = pid_t(identifier.dropFirst(Self.pidPrefix.count)), let live = procs.first(where: { $0.pid == pid }) { return procTarget(live) }
        if identifier.hasPrefix("/") || identifier.hasPrefix("~") {
            let path = Self.clean(system.expandUser(identifier))
            guard path.hasSuffix(".app"), system.info(path) != nil else { throw Errors.make("invalid_app", ["identifier": identifier]) }
            return target(path, procs: procs)
        }
        let livePaths = procs.filter { $0.bundleID == identifier }.compactMap(\.path)
        let paths = (livePaths.isEmpty ? system.bundlePaths(identifier).map(Self.clean) : livePaths).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if paths.count > 1 { throw Errors.ambiguousApp(bundleID: identifier, paths: paths) }
        if let path = paths.first { return target(path, procs: procs) }
        let names = [identifier] + (identifier.lowercased().hasSuffix(".app") && !identifier.contains("/") ? [String(identifier.dropLast(4))] : [])
        for name in names {
            if let found = byName(name, procs: procs, same: { $0 == $1 }) { return found }
            if let found = byName(name, procs: procs, same: { $0.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == $1.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }) { return found }
        }
        throw Errors.make("invalid_app", ["identifier": identifier])
    }
    public func running(_ target: AppTarget) throws -> AppTarget {
        if let pid = target.pid {
            let program = system.executable(pid)
            if target.path == "\(Self.pidPrefix)\(pid)" ? !program.isEmpty : spellings(target.path).contains(where: { program.hasPrefix($0 + "/") }) { return target }
        }
        let paths = spellings(target.path)
        guard let proc = system.running().first(where: { $0.path.map(paths.contains) ?? false || target.path == "\(Self.pidPrefix)\($0.pid)" }) else { throw Errors.make("app_not_running", ["identifier": target.path]) }
        var found = target; found.pid = proc.pid; return found
    }
    public func launch(_ target: AppTarget, abandoned: () -> Bool = { false }) throws -> AppTarget {
        guard let pid = system.open(target.path), pid != 0 else { throw Errors.make("failed_to_launch") }
        var target = target; target.pid = pid
        let end = system.now() + Self.launchLimit
        while true {
            do { _ = try system.keyWindow(target); return target }
            catch is HarnessError { if system.now() >= end { throw Errors.make("timeout_reached") } }
            if abandoned() { throw Errors.make("request_timed_out") }; system.sleep(Self.launchPoll)
        }
    }
    public func kind(_ target: AppTarget) -> AppKind {
        lock.lock()
        var found = kinds[target.path]
        if found != nil { kindOrder.removeAll { $0 == target.path }; kindOrder.append(target.path) }
        lock.unlock()
        if found == nil {
            let info = system.info(target.path) ?? [:]
            let types = info["CFBundleURLTypes"] as? [Any] ?? []
            let schemes = types.compactMap { $0 as? [String: Any] }.flatMap { $0["CFBundleURLSchemes"] as? [Any] ?? [] }
            found = AppKind(electron: info["NSPrincipalClass"] as? String == Self.electronClass, chromium: info["NSPrincipalClass"] as? String == Self.chromiumClass, http: schemes.contains { $0 as? String == Self.webScheme })
            lock.lock()
            kindOrder.removeAll { $0 == target.path }; kindOrder.append(target.path); kinds[target.path] = found
            if kindOrder.count > 256 { kinds.removeValue(forKey: kindOrder.removeFirst()) }
            lock.unlock()
        }
        if let pid = target.pid {
            lock.lock()
            var isCatalyst = catalystPIDs[pid]
            if isCatalyst != nil { catalystOrder.removeAll { $0 == pid }; catalystOrder.append(pid) }
            lock.unlock()
            if isCatalyst == nil {
                isCatalyst = (try? AX.backend.get(AX.backend.app(pid: pid), Self.catalyst)) as? Bool == true
                lock.lock()
                catalystOrder.removeAll { $0 == pid }; catalystOrder.append(pid); catalystPIDs[pid] = isCatalyst
                if catalystOrder.count > 256 { catalystPIDs.removeValue(forKey: catalystOrder.removeFirst()) }
                lock.unlock()
            }
            found!.catalyst = isCatalyst!
        }
        return found!
    }
    public func bundleID(_ pid: pid_t) -> String {
        let known = system.processBundleID(pid)
        if !known.isEmpty { return known }
        var folder = (system.executable(pid) as NSString).deletingLastPathComponent
        while !folder.isEmpty && folder != "/" {
            if Self.bundles.contains("." + (folder as NSString).pathExtension), let id = system.info(folder)?["CFBundleIdentifier"] as? String, !id.isEmpty { return id }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return ""
    }
    public func panelService(_ pid: pid_t) -> pid_t? { system.panelServices().first { $0.value == pid }?.key }
    public func panelOwner(_ candidates: [AppTarget]) throws -> AppTarget {
        // Only apps already read, newest first. Asking for the service itself once
        // needed its own approval: the person was asked, the agent waited 110 s.
        for target in candidates.reversed() {
            guard let pid = target.pid, let window = (try? AX.backend.get(AX.backend.app(pid: pid), "AXFocusedWindow")) as? UIElementRef,
                  let id = (try? AX.backend.get(window, "AXIdentifier")) as? String else { continue }
            if Self.filePanels.contains(id) { return target }
        }
        throw Errors.make("no_file_panel")
    }
    public func frontmost(hosts: Set<String> = [], procs: [Proc]? = nil) -> AppTarget? {
        let procs = procs ?? system.running()
        for pid in system.frontPIDs() {
            if let proc = procs.first(where: { $0.pid == pid }), pid != system.ownPID(), !(proc.path.map(hosts.contains) ?? false), system.regular(pid) { return procTarget(proc) }
        }
        return nil
    }
    public func prewarm() {
        lock.lock(); defer { lock.unlock() }
        if let group = catalogGroup, group.wait(timeout: .now()) == .timedOut { return }
        let group = DispatchGroup(); group.enter(); catalogGroup = group
        let system = self.system
        DispatchQueue.global().async { [self] in
            _ = system.running() // First process listing is the slow one (~60 vs 4 ms).
            let rows = system.used(); lock.lock(); catalogRows = rows; lock.unlock(); group.leave()
        }
    }
    public func catalog() -> [Used] {
        prewarm(); lock.lock(); let group = catalogRows == nil ? catalogGroup : nil; lock.unlock()
        _ = group?.wait(timeout: .now() + Self.catalogLimit)
        lock.lock(); defer { lock.unlock() }; return catalogRows ?? []
    }
    public func listApps(hosts: Set<String> = []) -> [[String: Any]] {
        let cut = system.wallTime() - Self.recentSeconds
        let recent = catalog().filter { ($0.lastUsed ?? -.infinity) >= cut }
        let procs = system.running(), front = frontmost(hosts: hosts, procs: procs)
        var ranked: [([Double], [String: Any])] = []
        var remaining = Set(recent.indices)
        func append(_ name: String, _ id: String, _ running: Bool, _ inFront: Bool, _ usage: Used?) {
            var row: [String: Any] = ["displayName": name, "id": id, "isRunning": running]
            if let usage, let epoch = usage.lastUsed {
                let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime]; row["lastUsedDate"] = format.string(from: Date(timeIntervalSince1970: epoch))
                if let count = usage.useCount { row["useCount"] = count }
            }
            ranked.append(([inFront ? 0 : 1, running ? 0 : 1, usage == nil ? 1 : 0, -floor((usage?.lastUsed ?? 0) / 86400), -Double(usage?.useCount ?? 0)], row))
        }
        for proc in procs where proc.pid != system.ownPID() && system.regular(proc.pid) {
            let index = proc.path.flatMap { path in recent.lastIndex { spellings($0.path).contains(path) } }
            let usage = index.map { recent[$0] }
            if let index { remaining.remove(index) }
            append(proc.name.isEmpty ? proc.bundleID : proc.name, proc.bundleID.isEmpty ? "\(Self.pidPrefix)\(proc.pid)" : proc.bundleID, true, front?.pid == proc.pid, usage)
        }
        for (index, usage) in recent.enumerated() where remaining.contains(index) {
            let name = usage.name.nonempty ?? stem(usage.path)
            append(name, usage.bundleID.nonempty ?? name.nonempty ?? "unknown", false, false, usage)
        }
        return ranked.enumerated().sorted { a, b in a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0.lexicographicallyPrecedes(b.element.0) }.map { $0.element.1 }
    }
}
private extension Optional where Wrapped == String { var nonempty: String? { flatMap { $0.isEmpty ? nil : $0 } } }
private extension String { var nonempty: String? { isEmpty ? nil : self } }
private final class OpenResult { let lock = NSLock(); var pid: pid_t? }
private final class RealApps {
    static let shared = RealApps()
    let lock = NSLock(); var known: [pid_t: Apps.Proc] = [:]
    func running() -> [Apps.Proc] {
        autoreleasepool {
            let pids = Apps.pids(); lock.lock(); defer { lock.unlock() }
            known = known.filter { pids.contains($0.key) }
            for pid in pids where known[pid] == nil {
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                // For a bare program the system calls the program file its "bundle".
                let bundle = app.bundleURL?.path
                var directory: ObjCBool = false
                let bundled = bundle.map { FileManager.default.fileExists(atPath: $0, isDirectory: &directory) && directory.boolValue } ?? false
                known[pid] = Apps.Proc(pid: pid, path: bundled ? bundle.map(Apps.clean) : nil, bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "", executable: app.executableURL?.lastPathComponent ?? "")
            }
            return pids.compactMap { known[$0] }
        }
    }
}
