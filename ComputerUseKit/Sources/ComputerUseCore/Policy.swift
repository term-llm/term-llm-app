import Foundation

/// Minimal, deliberately closed TOML subset for policy files: booleans, quoted
/// strings, string arrays, and [bundle_ids] containing strings. Unknown keys and
/// shapes are errors: a file we cannot read may hold a deny. Refuse until fixed.
public enum PolicyTOML {
    public enum Value: Equatable { case bool(Bool), string(String), strings([String]) }
    public struct Document: Equatable {
        public var values: [String: Value] = [:]
        public var bundleIDs: [String: String] = [:]
        public init() {}
    }
    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }
    public static func parse(_ text: String) throws -> Document {
        var scanner = Scanner(text)
        return try scanner.document()
    }
    private struct Scanner {
        let chars: [Character]
        var i = 0
        init(_ text: String) { chars = Array(text) }
        var end: Bool { i >= chars.count }
        var current: Character { end ? "\0" : chars[i] }
        mutating func whitespace(lines: Bool = false) {
            while !end {
                if current == " " || current == "\t"
                    || (lines && (current == "\n" || current == "\r"))
                {
                    i += 1
                } else if current == "#" {
                    while !end && current != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }
        func failure(_ message: String) -> ParseError {
            ParseError(description: "\(message) at character \(i + 1)")
        }
        mutating func string() throws -> String {
            let quote = current
            guard quote == "\"" || quote == "'" else { throw failure("expected quoted string") }
            i += 1
            var result = ""
            while !end && current != quote {
                let c = current
                i += 1
                guard
                    c != "\n" && c != "\r"
                        && !c.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" })
                else { throw failure("control character in string") }
                if c == "\\" && quote == "\"" {
                    guard !end else { throw failure("unfinished escape") }
                    let escaped = current
                    i += 1
                    let escapes: [Character: String] = [
                        "\"": "\"", "\\": "\\", "n": "\n", "r": "\r", "t": "\t", "b": "\u{8}",
                        "f": "\u{c}",
                    ]
                    if let value = escapes[escaped] {
                        result += value
                    } else if escaped == "u" || escaped == "U" {
                        let count = escaped == "u" ? 4 : 8
                        guard i + count <= chars.count,
                            let n = UInt32(String(chars[i..<i + count]), radix: 16),
                            let scalar = UnicodeScalar(n)
                        else { throw failure("invalid unicode escape") }
                        i += count
                        result.unicodeScalars.append(scalar)
                    } else {
                        throw failure("unsupported string escape")
                    }
                } else {
                    result.append(c)
                }
            }
            guard !end else { throw failure("unterminated string") }
            i += 1
            return result
        }
        mutating func key() throws -> String {
            if current == "\"" || current == "'" { return try string() }
            let start = i
            while !end
                && (current.isASCII
                    && (current.isLetter || current.isNumber || current == "_" || current == "-"))
            { i += 1 }
            guard i > start else { throw failure("expected key (quote bundle IDs)") }
            return String(chars[start..<i])
        }
        mutating func value() throws -> Value {
            if current == "\"" || current == "'" { return .string(try string()) }
            if current == "[" {
                i += 1
                whitespace(lines: true)
                var strings: [String] = []
                while current != "]" {
                    strings.append(try string())
                    whitespace(lines: true)
                    if current == "," {
                        i += 1
                        whitespace(lines: true)
                    } else if current != "]" {
                        throw failure("expected comma or ]")
                    }
                }
                i += 1
                return .strings(strings)
            }
            let start = i
            while !end && current.isLetter { i += 1 }
            switch String(chars[start..<i]) {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw failure("expected string, bool or string array")
            }
        }
        mutating func document() throws -> Document {
            var result = Document()
            var table = false
            let switches: Set<String> = [
                "enabled", "ask_before_first_use", "strict", "allow_persistent_approval",
                "allow_forbidden_targets",
            ]
            while true {
                whitespace(lines: true)
                if end { return result }
                if current == "[" {
                    guard !table else { throw failure("duplicate table") }
                    i += 1
                    whitespace()
                    let tableName = try key()
                    whitespace()
                    guard tableName == "bundle_ids", current == "]" else {
                        throw failure("only [bundle_ids] is supported")
                    }
                    i += 1
                    table = true
                } else {
                    let name = try key()
                    whitespace()
                    guard current == "=" else { throw failure("expected =") }
                    i += 1
                    whitespace()
                    let v = try value()
                    if table {
                        guard result.bundleIDs[name] == nil, case .string(let s) = v else {
                            throw failure("bundle rule must be a unique string")
                        }
                        result.bundleIDs[name] = s
                    } else {
                        guard result.values[name] == nil else { throw failure("duplicate key") }
                        switch (name, v) {
                        case (_, .bool) where switches.contains(name): break
                        case ("blocked_urls", .strings): break
                        case ("default_app_access", .string): break
                        default: throw failure("unknown key or invalid value for \(name)")
                        }
                        result.values[name] = v
                    }
                }
                whitespace()
                guard end || current == "\n" || current == "\r" else {
                    throw failure("unexpected trailing text")
                }
            }
        }
    }
}

public final class Policy {
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "co.zeit.hyper", "com.github.wez.wezterm", "org.tabby",
        "com.mitchellh.ghostty", "com.raphaelamorim.rio", "dev.commandline.waveterm",
    ]
    public static let passwordManagers: Set<String> = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
        "com.1password.safari", "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass", "com.nordsec.nordpass", "me.proton.pass.electron",
        "me.proton.pass.catalyst",
    ]
    public static let elevated: Set<String> = ["com.apple.ScreenContinuity"]
    public static let security: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.LocalAuthenticationRemoteService",
        "com.apple.SecurityAgent",
    ]
    public static let ownBundles: Set<String> = [
        "com.termllm.app", "com.termllm.app.computeruse",
        "com.apple.settings.PrivacySecurity.extension",
    ]
    public static let warning =
        "An app that \(product) drives can show it text written by someone else, and that text may try to steer it: data could be stolen or lost. Watch \(product) while it works in this app."
    public static let managedFile = URL(
        fileURLWithPath: "/Library/Application Support/term-llm/computer-use/policy.toml")
    public struct Layer {
        public var enabled = true, askBeforeFirstUse = true, strict = true
        public var allowPersistentApproval = true, allowForbiddenTargets = false
        public var defaultAppAccess = "allow", bundleIDs: [String: String] = [:],
            blockedURLs: [String] = []
        public init() {}
        public init(document: PolicyTOML.Document) {
            self.init()
            for (key, value) in document.values {
                switch (key, value) {
                case ("enabled", .bool(let b)): enabled = b
                case ("ask_before_first_use", .bool(let b)): askBeforeFirstUse = b
                case ("strict", .bool(let b)): strict = b
                case ("allow_persistent_approval", .bool(let b)): allowPersistentApproval = b
                case ("allow_forbidden_targets", .bool(let b)): allowForbiddenTargets = b
                case ("default_app_access", .string(let s)): defaultAppAccess = s
                case ("blocked_urls", .strings(let s)): blockedURLs = s
                default: break
                }
            }
            bundleIDs = document.bundleIDs
        }
    }
    public struct Configuration {
        public var layers: [Layer]
        public var enabled: Bool { layers.allSatisfy(\.enabled) }
        public var askBeforeFirstUse: Bool { layers.contains(where: \.askBeforeFirstUse) }
        public var strict: Bool { layers.contains(where: \.strict) }
        public var allowPersistentApproval: Bool { layers.allSatisfy(\.allowPersistentApproval) }
        public var allowForbiddenTargets: Bool { layers.contains(where: \.allowForbiddenTargets) }
        public var blockedURLs: [String] { layers.flatMap(\.blockedURLs) }
        public init(layers: [Layer]) { self.layers = layers }
    }
    private let files: [URL]
    private let appKind: (AppTarget) -> AppKind
    public init(
        managedFile: URL = Policy.managedFile,
        userFile: URL = Paths.stateDirectory().appendingPathComponent("policy.toml"),
        appKind: @escaping (AppTarget) -> AppKind = { _ in AppKind() }
    ) {
        files = [managedFile, userFile]
        self.appKind = appKind
        // HarnessExecutor supplies Apps.kind so browsers receive the high-risk warning.
    }
    public func load() throws -> Configuration {
        try Configuration(
            layers: files.map { file in
                do {
                    return Layer(
                        document: try PolicyTOML.parse(String(contentsOf: file, encoding: .utf8)))
                } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoSuchFileError
                { return Layer() } catch {
                    throw Errors.make(
                        "policy_unreadable",
                        ["path": file.path, "reason": String(describing: error)])
                }
            })
    }
    public func evaluate(agent: AgentSession, target: AppTarget) throws -> PolicyDecision {
        try evaluate(agent: agent, target: target, config: load())
    }
    public func evaluate(agent: AgentSession, target: AppTarget, config: Configuration) throws
        -> PolicyDecision
    {
        guard config.enabled else { throw Errors.make("disabled") }
        let bundle = target.bundleID
        let denied = config.layers.contains {
            ($0.bundleIDs[bundle] ?? $0.defaultAppAccess) != "allow"
        }
        let path = URL(fileURLWithPath: target.path).resolvingSymlinksInPath().path
        let host =
            agent.hosts.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == path }
            || target.pid == ProcessInfo.processInfo.processIdentifier
        let guarded = Self.security.union(Self.passwordManagers).union(Self.ownBundles).union(
            config.strict ? Self.terminals : [])
        let forbidden = !config.allowForbiddenTargets && (guarded.contains(bundle) || host)
        // Every app that opens http links is a browser, and a page can carry instructions.
        let high =
            Self.terminals.union(Self.elevated).union(Self.passwordManagers).contains(bundle)
            || appKind(target).http
        return PolicyDecision(
            decision: denied ? .denied : forbidden ? .forbidden : .allowed,
            risk: high ? .high : .low,
            allowPersistent: config.allowPersistentApproval, warning: high ? Self.warning : nil,
            ask: config.askBeforeFirstUse)
    }
    public func decide(agent: AgentSession, target: AppTarget) throws -> PolicyDecision {
        let p = try evaluate(agent: agent, target: target)
        if p.decision != .allowed {
            throw Errors.make(
                p.decision == .denied ? "denied_by_policy" : "forbidden",
                ["bundle_id": target.bundleID])
        }
        if Self.security.contains(target.bundleID) {
            throw Errors.make("security_process", ["bundle_id": target.bundleID])
        }
        return p
    }
    public func checkRecipient(_ bundleID: String) throws {
        if bundleID.isEmpty || Self.security.contains(bundleID) {
            throw Errors.make(
                "security_process", ["bundle_id": bundleID.isEmpty ? "unknown process" : bundleID])
        }
        let config = try load()
        let guarded = Self.passwordManagers.union(Self.ownBundles).union(
            config.strict ? Self.terminals : [])
        if !config.allowForbiddenTargets && guarded.contains(bundleID) {
            throw Errors.make("forbidden", ["bundle_id": bundleID])
        }
        if config.layers.contains(where: { ($0.bundleIDs[bundleID] ?? "allow") != "allow" }) {
            throw Errors.make("denied_by_policy", ["bundle_id": bundleID])
        }
    }
    public func watchesURLs() throws -> Bool { try !load().blockedURLs.isEmpty }
    public func checkURL(_ url: String?) throws {
        guard let url, !url.isEmpty else { return }
        let candidates = [url.lowercased(), URLComponents(string: url)?.host?.lowercased() ?? ""]
        for pattern in try load().blockedURLs
        where candidates.contains(where: { Self.shellMatch($0, pattern: pattern.lowercased()) }) {
            throw Errors.make("blocked_url")
        }
    }
    /// fnmatch-style shell patterns, not regular expressions; matches the entire string.
    public static func shellMatch(_ text: String, pattern: String) -> Bool {
        // Python fnmatchcase treats backslashes literally; slash and leading dot
        // are ordinary characters too. Do not apply filesystem pathname rules.
        pattern.withCString { p in text.withCString { t in fnmatch(p, t, FNM_NOESCAPE) == 0 } }
    }
    public static func displayName(_ target: AppTarget) -> String {
        let url = URL(fileURLWithPath: target.path).appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: url)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return (info?["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: target.path).deletingPathExtension().lastPathComponent
    }
}
