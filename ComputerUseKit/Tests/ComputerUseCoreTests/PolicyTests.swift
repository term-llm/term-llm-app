import XCTest

@testable import ComputerUseCore

final class PolicyTests: XCTestCase {
    var folder: URL!, managed: URL!, user: URL!, policy: Policy!
    let agent = AgentSession(key: "test", hosts: ["/Applications/Host.app"])
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        managed = folder.appendingPathComponent("managed.toml")
        user = folder.appendingPathComponent("user.toml")
        policy = Policy(
            managedFile: managed, userFile: user,
            appKind: { AppKind(http: $0.bundleID == "browser") })
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func target(_ bundle: String, path: String = "/Applications/Test.app", pid: Int32? = nil)
        -> AppTarget
    { AppTarget(path: path, bundleID: bundle, name: "Test", pid: pid) }
    func write(_ text: String, _ file: URL? = nil) throws {
        try text.write(to: file ?? user, atomically: true, encoding: .utf8)
    }
    func error(
        _ key: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(
                ($0 as? HarnessError)?.name, Errors.make(key).name, file: file, line: line)
        }
    }
    func testNewDefaultsAndLists() throws {
        let config = try policy.load()
        XCTAssertTrue(config.enabled)
        XCTAssertTrue(config.askBeforeFirstUse)
        XCTAssertTrue(config.strict)
        XCTAssertTrue(config.allowPersistentApproval)
        for bundle in Policy.terminals.union(Policy.passwordManagers).union(Policy.security).union(
            Policy.ownBundles)
        {
            XCTAssertEqual(
                try policy.evaluate(agent: agent, target: target(bundle)).decision, .forbidden,
                bundle)
        }
        XCTAssertEqual(Policy.terminals.count, 11)
        XCTAssertEqual(Policy.passwordManagers.count, 10)
        let ordinary = try policy.decide(agent: agent, target: target("com.apple.TextEdit"))
        XCTAssertEqual(ordinary.risk, .low)
        XCTAssertTrue(ordinary.ask)
        XCTAssertEqual(
            Policy.managedFile.path,
            "/Library/Application Support/term-llm/computer-use/policy.toml")
    }
    func testHighRiskMirroredPhoneAndBrowsers() throws {
        for bundle in ["com.apple.ScreenContinuity", "browser"] {
            let p = try policy.decide(agent: agent, target: target(bundle))
            XCTAssertEqual(p.decision, .allowed)
            XCTAssertEqual(p.risk, .high)
            XCTAssertEqual(p.warning, Policy.warning)
        }
        for bundle in Policy.terminals {
            XCTAssertEqual(try policy.evaluate(agent: agent, target: target(bundle)).risk, .high)
        }
    }
    func testHostAndHelperForbidden() throws {
        XCTAssertEqual(
            try policy.evaluate(
                agent: agent, target: target("host", path: "/Applications/Host.app")
            )
            .decision, .forbidden)
        XCTAssertEqual(
            try policy.evaluate(
                agent: agent,
                target: target("unknown", pid: ProcessInfo.processInfo.processIdentifier)
            ).decision, .forbidden)
    }
    func testDeniesWinAndFilesCombine() throws {
        try write("[bundle_ids]\n\"com.apple.Terminal\" = \"deny\"", managed)
        try write("[bundle_ids]\n\"com.apple.Terminal\" = \"allow\"")
        XCTAssertEqual(
            try policy.evaluate(agent: agent, target: target("com.apple.Terminal")).decision,
            .denied)
        error("denied_by_policy") {
            _ = try policy.decide(agent: agent, target: target("com.apple.Terminal"))
        }
        try write("default_app_access = \"deny\"\n[bundle_ids]\n\"exception\" = \"allow\"", managed)
        try write("")
        XCTAssertEqual(try policy.evaluate(agent: agent, target: target("other")).decision, .denied)
        XCTAssertEqual(
            try policy.evaluate(agent: agent, target: target("exception")).decision, .allowed)
    }
    func testUnknownAccessWordDeniesRatherThanAllows() throws {
        try write("default_app_access = 'unexpected'")
        XCTAssertEqual(try policy.evaluate(agent: agent, target: target("other")).decision, .denied)
        try write("[bundle_ids]\n'app' = 'unexpected'")
        XCTAssertEqual(try policy.evaluate(agent: agent, target: target("app")).decision, .denied)
    }
    func testSwitchMerging() throws {
        for file in [managed!, user!] {
            try write("enabled = false\nallow_persistent_approval = false", file)
            XCTAssertFalse(try policy.load().enabled)
            XCTAssertFalse(try policy.load().allowPersistentApproval)
            error("disabled") { _ = try policy.evaluate(agent: agent, target: target("other")) }
            try write("", file)
        }
        // True in either file wins. New true defaults also apply to missing files.
        try write("strict = false\nask_before_first_use = false", managed)
        try write("strict = false\nask_before_first_use = false")
        XCTAssertFalse(try policy.load().strict)
        XCTAssertFalse(try policy.load().askBeforeFirstUse)
        XCTAssertEqual(
            try policy.evaluate(agent: agent, target: target("com.apple.Terminal")).decision,
            .allowed)
        try write("strict = true\nask_before_first_use = true", managed)
        XCTAssertTrue(try policy.load().strict)
        XCTAssertTrue(try policy.load().askBeforeFirstUse)
    }
    func testForbiddenOverrideNeverAllowsSecurityRecipients() throws {
        try write("allow_forbidden_targets = true")
        XCTAssertEqual(
            try policy.evaluate(agent: agent, target: target("com.apple.Terminal")).decision,
            .allowed)
        for bundle in Policy.security {
            error("security_process") {
                _ = try policy.decide(agent: agent, target: target(bundle))
            }
            error("security_process") { try policy.checkRecipient(bundle) }
        }
    }
    func testRecipientRules() throws {
        error("security_process") { try policy.checkRecipient("") }
        for bundle in Policy.terminals.union(Policy.passwordManagers).union(Policy.ownBundles) {
            error("forbidden") { try policy.checkRecipient(bundle) }
        }
        try write("default_app_access = \"deny\"\n[bundle_ids]\n\"denied\" = \"deny\"")
        try policy.checkRecipient("unlisted.filepanel")  // default deny is app-level, not recipient-level
        error("denied_by_policy") { try policy.checkRecipient("denied") }
    }
    func testURLShellPatternsAndReload() throws {
        XCTAssertFalse(try policy.watchesURLs())
        try policy.checkURL(nil)
        try write("blocked_urls = [\"*.example.com\", 'https://bank.test/private/*']")
        try write("blocked_urls = ['exact.test']", managed)
        XCTAssertTrue(try policy.watchesURLs())
        for url in [
            "https://UPPER.EXAMPLE.COM/path", "https://bank.test/private/thing",
            "http://exact.test/a",
        ] { error("blocked_url") { try policy.checkURL(url) } }
        for url in ["https://example.com/", "https://bank.test/public/", "https://safe.test/a"] {
            try policy.checkURL(url)
        }
        try write("blocked_urls = []")
        try write("", managed)
        XCTAssertFalse(try policy.watchesURLs())
    }
    func testShellMatchIsAnchoredAndSupportsClasses() {
        XCTAssertTrue(Policy.shellMatch("a/b", pattern: "a*"))
        XCTAssertTrue(Policy.shellMatch("a1", pattern: "a[0-9]"))
        XCTAssertTrue(Policy.shellMatch("ab", pattern: "a[!0-9]"))
        XCTAssertFalse(Policy.shellMatch("zabc", pattern: "abc"))
        XCTAssertTrue(Policy.shellMatch(".dot", pattern: "*"))
        XCTAssertTrue(Policy.shellMatch(#"a\b"#, pattern: #"a\?"#))
    }
    func testUnreadablePolicyFailsClosed() throws {
        for text in [
            "strict = 1", "strict = 'yes'", "[other]\na = true", "blocked_urls = [true]",
            "enabled = true trailing", "[bundle_ids]\n\"test\" = false",
        ] {
            try write(text)
            error("policy_unreadable") {
                _ = try policy.evaluate(agent: agent, target: target("other"))
            }
        }
        try FileManager.default.removeItem(at: user)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        error("policy_unreadable") { _ = try policy.load() }
    }
    func testTOMLSubset() throws {
        let text = """
            # comment
            enabled = false # trailing comment
            blocked_urls = [
              'literal#host', "escaped\\nline", # array comment
              "unicode\\u0061",
            ]
            default_app_access = 'deny'
            [bundle_ids]
            "com.example.App" = "allow"
            'com.other.App' = 'deny'
            """
        let doc = try PolicyTOML.parse(text)
        XCTAssertEqual(doc.values["enabled"], .bool(false))
        XCTAssertEqual(
            doc.values["blocked_urls"], .strings(["literal#host", "escaped\nline", "unicodea"]))
        XCTAssertEqual(doc.bundleIDs, ["com.example.App": "allow", "com.other.App": "deny"])
        XCTAssertEqual(try PolicyTOML.parse(""), PolicyTOML.Document())
    }
    func testTOMLRejectsDuplicatesAndUnsupportedShapes() {
        for text in [
            "enabled=true\nenabled=false", "a=1", "strict=tru", "blocked_urls=['a' 'b']",
            "blocked_urls=['unterminated]", "strict=\"\\q\"", "[bundle_ids]\n[ bundle_ids ]",
            "[bundle_ids]\ncom.example='allow'", "[bundle_ids]\n'a'='allow'\n'a'='deny'",
            "default_app_access = {}", "strict = \"\\uD800\"", "enabled = true\n[other]",
        ] { XCTAssertThrowsError(try PolicyTOML.parse(text), text) }
    }
    func testDisplayNameFallbacks() throws {
        let app = folder.appendingPathComponent("Fallback.app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        let t = target("app", path: app.path)
        XCTAssertEqual(Policy.displayName(t), "Fallback")
        for (dict, want) in [
            (["CFBundleName": "Name"], "Name"),
            (["CFBundleDisplayName": "Display", "CFBundleName": "Name"], "Display"),
            (["CFBundleDisplayName": "", "CFBundleName": "Name"], "Name"),
        ] {
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
                .write(
                    to: info)
            XCTAssertEqual(Policy.displayName(t), want)
        }
    }
}
