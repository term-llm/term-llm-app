import Foundation

/// Explicit opt-out of ownership. A malformed setting fails closed rather than
/// falling back to managing the user's installation.
public struct DeveloperModeStore {
    public let provisioner: CLIProvisioner
    public init(provisioner: CLIProvisioner) { self.provisioner = provisioner }
    public var url: URL { provisioner.supportDirectory.appendingPathComponent("developer-mode.json") }
    private struct Setting: Codable { var binaryPath: String }
    public func load() throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let setting = try JSONDecoder().decode(Setting.self, from: Data(contentsOf: url))
        try validate(setting.binaryPath)
        return URL(fileURLWithPath: setting.binaryPath)
    }
    private func validate(_ path: String) throws {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        guard path.hasPrefix("/"), attributes?[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIProvisionerError.notExecutable(path)
        }
    }
    public func enable(binary: URL) throws {
        try validate(binary.path)
        try FileManager.default.createDirectory(at: provisioner.supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Setting(binaryPath: binary.path)).write(to: url, options: .atomic)
    }
    public func disable() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
