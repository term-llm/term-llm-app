import AppKit
import ComputerUseCore
import XCTest
@testable import ComputerUseSystem

final class AppsTests: ContextTestCase {
    var apps: Apps!; var procs: [Apps.Proc] = []; var infos: [String: [String: Any]] = [:]
    var bundles: [String: [String]] = [:], usage: [Apps.Used] = []
    var regular: Set<pid_t> = [], front: [pid_t] = [], programs: [pid_t: String] = [:]
    override func setUp() {
        super.setUp(); procs = []; infos = [:]; bundles = [:]; usage = []; regular = []; front = []; programs = [:]
        var s = Apps.System(); s.running = { self.procs }; s.info = { self.infos[$0] }; s.regular = { self.regular.contains($0) }
        s.entries = { folder in self.infos.keys.filter { ($0 as NSString).deletingLastPathComponent == folder }.map { ($0 as NSString).lastPathComponent } }
        s.bundlePaths = { self.bundles[$0] ?? [] }; s.named = { _ in nil }; s.realPath = { $0 }; s.expandUser = { $0.replacingOccurrences(of: "~/", with: "/Home/") }
        s.frontPIDs = { self.front }; s.executable = { self.programs[$0] ?? "" }; s.ownPID = { 4242 }; s.used = { self.usage }
        s.now = { self.clock.time }; s.wallTime = { 1_800_000_000 }; s.sleep = { self.clock.sleep($0) }
        s.open = { _ in XCTFail("Unexpected launch"); return nil }; s.keyWindow = { _ in XCTFail("Unexpected window read"); throw Errors.make("no_windows") }
        s.panelServices = { [:] }; s.processBundleID = { _ in "" }; apps = Apps(system: s)
    }
    @discardableResult func install(_ name: String, id: String = "dev.test", folder: String = "/Applications", info: [String: Any] = [:]) -> String {
        let path = folder + "/" + name + ".app"; var info = info; info["CFBundleIdentifier"] = id; infos[path] = info; bundles[id, default: []].append(path); return path
    }
    func testNameBundlePathAndDisplayName() throws {
        let path = install("TextEdit", info: ["CFBundleDisplayName": "Visual Editor"])
        for id in ["TextEdit", path, "dev.test", path + "/"] {
            XCTAssertEqual(try apps.resolve(id), AppTarget(path: path, bundleID: "dev.test", name: "Visual Editor"))
        }
        let short = install("Short", id: "dev.short", info: ["CFBundleName": "Shorter"])
        XCTAssertEqual(try apps.resolve(short).name, "Shorter")
    }
    func testAmbiguousInstalledAndRunningCopies() throws {
        let one = install("Browser"), two = install("Browser", folder: "/Beta")
        assertHarnessError(name: "several_apps_match") { _ = try self.apps.resolve("dev.test") }
        procs = [.init(pid: 41, path: two, bundleID: "dev.test", name: "Browser")]
        for id in ["dev.test", "Browser", two] { XCTAssertEqual(try apps.resolve(id).pid, 41) }
        procs.append(.init(pid: 42, path: one, bundleID: "dev.test")); XCTAssertThrowsError(try apps.resolve("dev.test"))
        procs[1].path = two; XCTAssertEqual(try apps.resolve("dev.test").pid, 41)
    }
    func testPathValidationAndNormalization() throws {
        let path = install("Thing")
        XCTAssertEqual(try apps.resolve("/System/Volumes/Data" + path).path, path)
        XCTAssertEqual(Apps.clean("/A/X/../Thing.app/"), "/A/Thing.app")
        for (raw, clean) in [("", "."), ("a/../../b", "../b"), ("/../../a", "/a"), ("//A//b", "//A/b"), ("~/Apps/", "~/Apps")] { XCTAssertEqual(Apps.clean(raw), clean) }
        for id in ["", " ", "absent", "/bin/ls", "/Applications", "#pid:no", "#pid:404"] { assertHarnessError(name: "no_such_app") { _ = try self.apps.resolve(id) } }
        let home = install("Home", folder: "/Home/Applications"); XCTAssertEqual(try apps.resolve("~/Applications/Home.app").path, home)
    }
    func testCaseAndAppSuffixAfterExactMatch() throws {
        install("Editor"); let literal = install("editor.app", id: "dev.literal")
        XCTAssertEqual(try apps.resolve("editor.app").path, literal)
        XCTAssertEqual(try apps.resolve("EDITOR").bundleID, "dev.test")
        for id in ["Editor.app", "EDITOR.APP"] { XCTAssertEqual(try apps.resolve(id).bundleID, "dev.literal") }
        infos.removeValue(forKey: literal)
        XCTAssertEqual(try apps.resolve("EDITOR.APP").bundleID, "dev.test")
        procs = [.init(pid: 9, path: nil, name: "Raw Tool", executable: "worker")]
        XCTAssertEqual(try apps.resolve("raw tool").pid, 9); XCTAssertEqual(try apps.resolve("WORKER").pid, 9)
    }
    func testRunningDisplayAndProcessDockedFirstAndPID() throws {
        procs = [.init(pid: 2, path: nil, name: "Test", executable: "test"), .init(pid: 3, path: "/A/Test.app", name: "Test", executable: "test")]; regular = [3]
        XCTAssertEqual(try apps.resolve("Test").pid, 3); XCTAssertEqual(try apps.resolve("test").pid, 3)
        let raw = try apps.resolve("#pid:2"); XCTAssertEqual(raw.path, "#pid:2"); XCTAssertEqual(raw.bundleID, "#pid:2")
        XCTAssertEqual(try apps.resolve("#pid:3").bundleID, "/A/Test.app")
    }
    func testSystemNamedFallbackAndSymlink() throws {
        let path = install("Odd", folder: "/Other"); apps.system.named = { $0 == "System Name" ? path : nil }
        XCTAssertEqual(try apps.resolve("System Name").path, path)
        infos["/Link.app"] = [:]; apps.system.realPath = { $0 == "/Link.app" ? path : $0 }
        procs = [.init(pid: 99, path: path, bundleID: "dev.test", name: "Odd")]
        XCTAssertEqual(try apps.resolve("/Link.app").pid, 99)
        var t = target; t.path = "/Link.app"; t.pid = nil; XCTAssertEqual(try apps.running(t).pid, 99)
    }
    func testRunningKernelFastPathRefreshAndQuit() throws {
        programs[77] = target.path + "/Contents/MacOS/Test"; XCTAssertEqual(try apps.running(target), target)
        programs = [:]; procs = [.init(pid: 88, path: target.path)]; XCTAssertEqual(try apps.running(target).pid, 88)
        procs = []; assertHarnessError(name: "app_not_running") { _ = try self.apps.running(self.target) }
        let raw = AppTarget(path: "#pid:2", bundleID: "#pid:2", name: "Raw", pid: 2)
        programs[2] = "/bin/raw"; XCTAssertEqual(try apps.running(raw).pid, 2)
    }
    func testLaunchBackgroundReadinessAndAbandonment() throws {
        var opened: [String] = [], reads = 0
        apps.system.open = { opened.append($0); return 91 }
        apps.system.keyWindow = { t in reads += 1; if reads < 4 { throw Errors.make("no_windows") }; XCTAssertEqual(t.pid, 91); return fixtureWindow() }
        XCTAssertEqual(try apps.launch(target).pid, 91); XCTAssertEqual(opened, [target.path]); XCTAssertEqual(clock.sleeps, [0.05, 0.05, 0.05])
        apps.system.keyWindow = { _ in throw Errors.make("front_not_back") }
        assertHarnessError(name: "request_timed_out") { _ = try self.apps.launch(self.target, abandoned: { true }) }
    }
    func testLaunchFailureAndFiveSecondBudget() {
        apps.system.open = { _ in nil }; assertHarnessError(Errors.make("failed_to_launch").message) { _ = try self.apps.launch(self.target) }
        apps.system.open = { _ in 91 }; apps.system.keyWindow = { _ in throw Errors.make("front_not_back") }
        assertHarnessError(Errors.make("timeout_reached").message) { _ = try self.apps.launch(self.target) }
        XCTAssertEqual(clock.time, 1005, accuracy: 0.06)
    }
    func testClassificationAndCatalystCachedPerPID() {
        let cases: [([String: Any], AppKind)] = [(["NSPrincipalClass": "AtomApplication"], AppKind(electron: true)), (["NSPrincipalClass": "BrowserCrApplication"], AppKind(chromium: true)), (["CFBundleURLTypes": [["CFBundleURLSchemes": ["http", "https"]]]], AppKind(http: true)), (["CFBundleURLTypes": "http"], AppKind())]
        for (index, row) in cases.enumerated() {
            let path = install("Kind\(index)", info: row.0)
            XCTAssertEqual(apps.kind(.init(path: path, bundleID: "dev.test", name: "Test")), row.1)
        }
        ax.el(ax.app(pid: 77)).attrs[Apps.catalyst] = true
        XCTAssertTrue(apps.kind(target).catalyst); XCTAssertTrue(apps.kind(target).catalyst)
        XCTAssertEqual(ax.gets.filter { $0.1 == Apps.catalyst }.count, 1)
        var other = target; other.pid = nil; XCTAssertFalse(apps.kind(other).catalyst)
    }
    func testPanelOwnerNewestAndOnlyKnownCandidates() throws {
        let window = ContextElement(attrs: ["AXIdentifier": "save-panel"])
        ax.el(ax.app(pid: 77)).attrs["AXFocusedWindow"] = window.ref
        var older = target; older.pid = 88
        XCTAssertEqual(try apps.panelOwner([older, target]), target); XCTAssertEqual(ax.gets.count, 2)
        window.attrs["AXIdentifier"] = "GoToWindow"; XCTAssertEqual(try apps.panelOwner([target]), target)
        window.attrs = [:]; XCTAssertThrowsError(try apps.panelOwner([target]))
        apps.system.panelServices = { [999: 77, 998: 88] }; XCTAssertEqual(apps.panelService(77), 999); XCTAssertNil(apps.panelService(55))
    }
    func testServiceBundleFromInnermostBundle() {
        apps.system.executable = { _ in "/A/Test.app/Contents/XPCServices/Agent.xpc/Contents/MacOS/Agent" }
        infos["/A/Test.app/Contents/XPCServices/Agent.xpc"] = ["CFBundleIdentifier": "dev.agent"]
        XCTAssertEqual(apps.bundleID(99), "dev.agent")
        apps.system.processBundleID = { _ in "dev.known" }; XCTAssertEqual(apps.bundleID(99), "dev.known")
        apps.system.processBundleID = { _ in "" }; apps.system.executable = { _ in "/bin/raw" }; XCTAssertEqual(apps.bundleID(99), "")
    }
    func testFrontmostExcludesSelfHostAndAccessories() {
        procs = [.init(pid: 4242, path: "/A/Helper.app"), .init(pid: 2, path: "/A/Host.app"), .init(pid: 3, path: "/A/Overlay.app"), .init(pid: 4, path: "/A/Mail.app")]
        regular = [4242, 2, 4]; front = [4242, 3, 2, 2, 4]
        XCTAssertEqual(apps.frontmost()?.pid, 2); XCTAssertEqual(apps.frontmost(hosts: ["/A/Host.app"])?.pid, 4)
        front = [3]; XCTAssertNil(apps.frontmost())
    }
    func testListShapeRecentCutoffAndMissingValues() {
        procs = [.init(pid: 11, path: "/A/Mail.app", bundleID: "dev.mail", name: "Mail"), .init(pid: 12, path: nil, name: "Raw"), .init(pid: 4242, path: "/A/Self.app")]; regular = [11, 12, 4242]; front = [11]
        usage = [.init(path: "/A/Mail.app", lastUsed: 1_800_000_000 - 43200, useCount: 4716), .init(path: "/A/Map.app", lastUsed: 1_800_000_000 - 86400), .init(path: "/A/Old.app", lastUsed: 1_800_000_000 - Apps.recentSeconds - 1), .init(path: "/A/Never.app")]
        let rows = apps.listApps(); XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["dev.mail", "#pid:12", "Map"])
        XCTAssertEqual(rows[0]["lastUsedDate"] as? String, "2027-01-14T20:00:00Z"); XCTAssertEqual(rows[0]["useCount"] as? Int, 4716)
        XCTAssertEqual(Set(rows[1].keys), ["id", "displayName", "isRunning"])
        XCTAssertFalse(rows.contains { $0["path"] != nil })
    }
    func testListRankByFrontRunningDayThenCount() {
        let names = ["Idle", "Busy", "Front", "Often", "Yesterday"]
        procs = names.enumerated().map { .init(pid: pid_t($0.offset + 1), path: "/A/\($0.element).app", bundleID: $0.element.lowercased(), name: $0.element) }; regular = [1, 2, 3, 4, 5]; front = [3]
        usage = [("Busy", 0.2, 5), ("Often", 0.3, 900), ("Yesterday", 1.2, 5000), ("Closed", 0.1, 2), ("Shut", 0.25, 70), ("Past", 3.0, 999)].map { .init(path: "/A/\($0.0).app", lastUsed: 1_800_000_000 - $0.1 * 86400, useCount: $0.2, bundleID: $0.0.lowercased()) }
        XCTAssertEqual(apps.listApps().compactMap { $0["id"] as? String }, ["front", "often", "busy", "yesterday", "idle", "shut", "closed", "past"])
    }
    func testCatalogPrewarmOneQueryAtATimeAndTimeout() {
        let release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        apps.system.used = { entered.signal(); _ = release.wait(timeout: .now() + 4); return [.init(path: "/A/Recent.app", lastUsed: 1_800_000_000)] }
        apps.prewarm(); XCTAssertEqual(entered.wait(timeout: .now() + 1), .success); apps.prewarm()
        let start = Date(); XCTAssertTrue(apps.catalog().isEmpty); XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        release.signal()
        // Wait for first query publication before asking for the next refresh.
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(apps.catalog().first?.path, "/A/Recent.app"); release.signal()
    }
    func testInfoPlistLayoutsAndInvalidFiles() throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        for inner in ["Contents/Info.plist", "WrappedBundle/Info.plist", "Info.plist"] {
            let app = folder.appendingPathComponent(UUID().uuidString + ".app"), file = app.appendingPathComponent(inner)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.test"], format: .binary, options: 0).write(to: file)
            XCTAssertEqual(Apps.readInfo(app.path)?["CFBundleIdentifier"] as? String, "dev.test")
        }
        XCTAssertNil(Apps.readInfo(folder.path))
    }
    func testKindCacheKeeps256MostRecentlyUsedPaths() {
        var infoReads = 0
        apps.system.info = { _ in infoReads += 1; return [:] }
        func target(_ index: Int) -> AppTarget { .init(path: "/A/Cache\(index).app", bundleID: "dev.cache", name: "Cache") }
        for index in 0..<256 { _ = apps.kind(target(index)) }
        _ = apps.kind(target(0)); _ = apps.kind(target(256))
        XCTAssertEqual(infoReads, 257)
        _ = apps.kind(target(0)); XCTAssertEqual(infoReads, 257)
        _ = apps.kind(target(1)); XCTAssertEqual(infoReads, 258)
    }
    func testTwoRunningInstancesShareUsageWithoutDuplicatingClosedRow() {
        procs = [.init(pid: 1, path: "/A/Mail.app", bundleID: "dev.mail"), .init(pid: 2, path: "/A/Mail.app", bundleID: "dev.mail")]
        regular = [1, 2]
        usage = [.init(path: "/A/Mail.app", lastUsed: 1_800_000_000, useCount: 5)]
        let rows = apps.listApps()
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows.allSatisfy { $0["useCount"] as? Int == 5 })
    }

}
