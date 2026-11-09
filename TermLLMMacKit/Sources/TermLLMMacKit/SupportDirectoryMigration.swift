import Darwin
import Foundation

/// Earlier builds kept the app's files in ~/Library/Application Support/TermLLM.
/// They now live in `supportDirectory` (~/.config/term-llm/app).
extension CLIProvisioner {
    public var legacySupportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/TermLLM", isDirectory: true)
    }

    /// Moves an earlier build's files once, rewriting the absolute paths
    /// recorded inside them and a Terminal link that pointed at the old copy.
    /// A service still defined with the old binary path keeps working through
    /// a link left at the old location; that link goes away once no service
    /// definition names it. Returns true when files were moved.
    @discardableResult
    public func migrateLegacySupportDirectory() throws -> Bool {
        let old = legacySupportDirectory
        let new = supportDirectory
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: old.path) {
            let target = URL(fileURLWithPath: destination, relativeTo: old.deletingLastPathComponent())
            if target.standardizedFileURL.path == new.standardizedFileURL.path,
               !serviceDefinitionsMention(old.path) {
                try? fileManager.removeItem(at: old)
            }
            return false
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !fileManager.fileExists(atPath: new.path) else { return false }
        // Never move files out from under an install running in another copy.
        let lock = open(old.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR, 0o644)
        guard lock >= 0 else { return false }
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return false }
        // term-llm keeps its own settings private; match that if it isn't set up yet.
        try fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.moveItem(at: old, to: new)
        rewriteRecordedPaths(in: new, from: old.path, to: new.path)
        repointPATHLink(from: old.path)
        if serviceDefinitionsMention(old.path) {
            try fileManager.createSymbolicLink(at: old, withDestinationURL: new)
        }
        return true
    }

    /// Absolute paths inside the moved JSON files: the manifest's binary path,
    /// backups, the switch journal and the ownership marker's hint.
    private func rewriteRecordedPaths(in root: URL, from old: String, to new: String) {
        guard let files = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in files where url.pathExtension == "json" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            var changed = false
            let rewritten = Self.replacingPath(in: object, from: old, to: new, changed: &changed)
            guard changed, let output = try? JSONSerialization.data(withJSONObject: rewritten,
                                                                    options: [.prettyPrinted, .sortedKeys])
            else { continue }
            let permissions = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions]
            try? output.write(to: url, options: .atomic)
            if let permissions { try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        }
    }

    static func replacingPath(in value: Any, from old: String, to new: String, changed: inout Bool) -> Any {
        switch value {
        case let string as String:
            guard string == old || string.contains(old + "/") else { return string }
            changed = true
            return string == old ? new : string.replacingOccurrences(of: old + "/", with: new + "/")
        case let array as [Any]:
            return array.map { replacingPath(in: $0, from: old, to: new, changed: &changed) }
        case let object as [String: Any]:
            return object.mapValues { replacingPath(in: $0, from: old, to: new, changed: &changed) }
        default:
            return value
        }
    }

    private func repointPATHLink(from old: String) {
        let link = pathLink
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
              URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path
                == old + "/bin/" + Self.executableName else { return }
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".\(Self.executableName).link-\(UUID().uuidString)")
        do {
            try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: managedBinary.path)
            try Self.replaceAtomically(temporary, link)
        } catch {
            try? fileManager.removeItem(at: temporary)
        }
    }

    /// launchd definitions and term-llm's own service specs record the binary path.
    private func serviceDefinitionsMention(_ directory: String) -> Bool {
        var files: [URL] = []
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        for name in (try? fileManager.contentsOfDirectory(atPath: agents.path)) ?? []
        where name.hasPrefix("com.term-llm.") && name.hasSuffix(".plist") {
            files.append(agents.appendingPathComponent(name))
        }
        let services = home.appendingPathComponent(".config/term-llm/services", isDirectory: true)
        for kind in (try? fileManager.contentsOfDirectory(atPath: services.path)) ?? [] {
            files.append(services.appendingPathComponent(kind).appendingPathComponent("service.json"))
        }
        let needles = [directory + "/", directory.replacingOccurrences(of: "/", with: "\\/") + "\\/"]
        return files.contains { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            let text = String(decoding: data, as: UTF8.self)
            return needles.contains { text.contains($0) }
        }
    }
}
