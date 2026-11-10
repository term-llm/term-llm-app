import Darwin
import Foundation
import os
import Security

public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init(_ value: String) throws {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
            throw ReleaseError.invalidVersion
        }
        self.major = major; self.minor = minor; self.patch = patch
    }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (l: Self, r: Self) -> Bool { (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch) }
}

public enum ReleaseError: Error, LocalizedError {
    case invalidVersion, invalidResponse, checksum, invalidBinary, signature, smokeTest, belowMinimum
    public var errorDescription: String? {
        switch self {
        case .invalidVersion: return "The release version is not X.Y.Z."
        case .invalidResponse: return "GitHub didn't answer as expected. Try again later."
        case .checksum: return "The release archive checksum did not match checksums.txt."
        case .invalidBinary: return "The release must contain a non-empty regular term-llm executable, not a symlink."
        case .signature: return "The CLI's strict Developer ID signature verification failed."
        case .smokeTest: return "The verified CLI did not return service-status schema 1."
        case .belowMinimum: return "The app requires term-llm 0.9.94 or later."
        }
    }
}

public struct ReleaseResponse: Sendable {
    public let data: Data
    public let url: URL
    public init(data: Data, url: URL) { self.data = data; self.url = url }
}
public protocol ReleaseTransport: Sendable {
    func fetch(_ url: URL) throws -> ReleaseResponse
}

/// Synchronous seam intended for background work, never the main actor.
public struct GitHubReleaseTransport: ReleaseTransport {
    public var appVersion: String
    public init(appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") { self.appVersion = appVersion }
    public func fetch(_ url: URL) throws -> ReleaseResponse {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: ReleaseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("term-llm-mac/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let box = OSAllocatedUnfairLock<Result<ReleaseResponse, any Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result<ReleaseResponse, any Error>
            if error != nil { result = .failure(ReleaseError.invalidResponse) }
            else if let http = response as? HTTPURLResponse, http.statusCode == 200,
                    let final = http.url, final.scheme == "https", let data {
                result = .success(ReleaseResponse(data: data, url: final))
            } else { result = .failure(ReleaseError.invalidResponse) }
            box.withLock { $0 = result }
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 190) == .success else { task.cancel(); throw ReleaseError.invalidResponse }
        return try box.withLock { $0 }!.get()
    }
}
private final class ReleaseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // GitHub assets redirect to a CDN. There are no credentials on these requests.
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

public struct ReleaseInstaller {
    public static let productionRequirement = "identifier \"term-llm\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"B6BAJ46A72\""
    public static let latestURL = URL(string: "https://github.com/samsaffron/term-llm/releases/latest")!
    public let provisioner: CLIProvisioner
    public let transport: ReleaseTransport
    public let requirement: String
    public let minimumVersion: String
    public init(provisioner: CLIProvisioner, transport: ReleaseTransport = GitHubReleaseTransport(),
                requirement: String = Self.productionRequirement, minimumVersion: String = "0.9.94") {
        self.provisioner = provisioner; self.transport = transport
        self.requirement = requirement; self.minimumVersion = minimumVersion
    }
    public static var nativeArchitecture: String {
        var arm: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1 ? "arm64" : "amd64"
    }
    public func latestVersion() throws -> String {
        let response = try transport.fetch(Self.latestURL)
        let prefix = "/samsaffron/term-llm/releases/tag/"
        guard response.url.host == "github.com", response.url.path.hasPrefix(prefix) else { throw ReleaseError.invalidResponse }
        return try SemanticVersion(String(response.url.path.dropFirst(prefix.count))).description
    }
    public func verifySignature(at binary: URL) throws {
        var code: SecStaticCode?; var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
              let code, let req,
              SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), req, nil) == errSecSuccess else {
            throw ReleaseError.signature
        }
    }
    private struct VerifiedKey: Hashable, Sendable {
        let file: FileIdentity
        let sha256: String
        let requirement: String
    }
    private static let verified = FileCheckCache<VerifiedKey, Bool>()

    public func verifyManaged() throws {
        try provisioner.requireManagementEnabled()
        let binary = provisioner.managedBinary
        guard let selection = try provisioner.loadSelection().get(), selection.source == .release,
              selection.binaryPath == binary.path else { throw ReleaseError.checksum }
        guard try SemanticVersion(selection.version) >= SemanticVersion(minimumVersion) else { throw ReleaseError.belowMinimum }
        try Self.validateFile(binary)
        // Hashing and strict signature validation read the whole executable.
        // Status polling repeats them only after the file identity changes.
        let before = FileIdentity(binary)
        let key = before.map { VerifiedKey(file: $0, sha256: selection.sha256, requirement: requirement) }
        if let key, Self.verified.value(for: key) == true { return }
        guard try CLIProvisioner.sha256(of: binary) == selection.sha256 else { throw ReleaseError.checksum }
        try verifySignature(at: binary)
        if let key, FileIdentity(binary) == before { Self.verified.set(true, for: key) }
    }
    private static func validateFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw ReleaseError.invalidBinary }
    }
    /// Downloads and validates without promotion; also used by opt-in live E2E.
    /// The returned candidate lives only for the duration of `body`.
    public func withVerifiedCandidate<T>(version: String, smokeTest: Bool = true, body: (URL, String, String) throws -> T) throws -> T {
        try provisioner.requireManagementEnabled()
        let version = try SemanticVersion(version).description
        guard try SemanticVersion(version) >= SemanticVersion(minimumVersion) else { throw ReleaseError.belowMinimum }
        let fm = provisioner.fileManager
        let root = provisioner.supportDirectory.appendingPathComponent("staging")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let stage = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let name = "term-llm_\(version)_darwin_\(Self.nativeArchitecture).tar.gz"
        let base = "https://github.com/samsaffron/term-llm/releases/download/v\(version)/"
        let archive = stage.appendingPathComponent(name)
        try transport.fetch(URL(string: base + name)!).data.write(to: archive)
        let checksums = try transport.fetch(URL(string: base + "checksums.txt")!).data
        let lines = String(decoding: checksums, as: UTF8.self).split(whereSeparator: \.isNewline)
        let matches = lines.compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == name, fields[0].count == 64,
                  fields[0].allSatisfy({ $0.isHexDigit }) else { return nil }
            return fields[0].lowercased()
        }
        guard matches.count == 1, try CLIProvisioner.sha256(of: archive) == matches[0] else { throw ReleaseError.checksum }
        let extracted = try provisioner.runner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
                    arguments: ["-xzf", archive.path, "-C", stage.path, "term-llm"], environment: nil, timeout: 60)
        guard extracted.succeeded else { throw ReleaseError.invalidBinary }
        let candidate = stage.appendingPathComponent("term-llm")
        try Self.validateFile(candidate)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        try verifySignature(at: candidate) // MUST precede any candidate execution.
        let env = ["TERM_LLM_NO_PROMPT": "1", "TERM_LLM_SKIP_UPDATE_CHECK": "1"]
        let probe = try provisioner.runner.run(executable: candidate, arguments: ["--version"], environment: env, timeout: 15)
        let reported = probe.stdout.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { try? SemanticVersion(String($0)) }.first
        guard probe.succeeded, let reported, reported == (try SemanticVersion(version)) else { throw ReleaseError.invalidVersion }
        guard reported >= (try SemanticVersion(minimumVersion)) else { throw ReleaseError.belowMinimum }
        if smokeTest {
            let smoke = try provisioner.runner.run(executable: candidate, arguments: ["service", "status", "web", "--json"], environment: env, timeout: 20)
            guard smoke.succeeded, let report = try? JSONDecoder().decode(ServiceStatusReport.self, from: Data(smoke.stdout.utf8)),
                  report.schemaVersion == 1, report.service("web") != nil else { throw ReleaseError.smokeTest }
        }
        return try body(candidate, version, "https://github.com/samsaffron/term-llm/releases/tag/v\(version)")
    }
    @discardableResult
    public func install(version: String? = nil, skippedVersions: [String] = [], force: Bool = false) throws -> CLISelection? {
        try provisioner.requireManagementEnabled()
        let resolved = try version.map { try SemanticVersion($0).description } ?? latestVersion()
        if skippedVersions.contains(resolved) { return nil }
        if !force, let current = try provisioner.loadSelection().get(), current.source == .release,
           let installed = try? SemanticVersion(current.version), installed >= (try SemanticVersion(resolved)) { return nil }
        return try withVerifiedCandidate(version: resolved) { binary, version, provenance in
            try provisioner.installVerified(binary: binary, version: version,
                 sha256: CLIProvisioner.sha256(of: binary), provenance: provenance)
        }
    }
}
