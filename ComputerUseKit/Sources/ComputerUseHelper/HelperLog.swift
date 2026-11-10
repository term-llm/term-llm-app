import ComputerUseCore
import Darwin
import Foundation

/// Operational metadata only. Never pass argv, environment, app names, text,
/// screenshots, exception descriptions, or accessibility content to this logger.
final class HelperLog {
    private let lock = NSLock()
    private let path: String
    init(environment: [String: String]) { path = Paths.logPath(env: environment) }
    func write(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return }
            if info.st_size > 1024 * 1024 { _ = rename(path, path + ".1") }
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)\n"
        let data = Data(line.utf8)
        data.withUnsafeBytes { bytes in _ = Darwin.write(fd, bytes.baseAddress!, bytes.count) }
    }
}
