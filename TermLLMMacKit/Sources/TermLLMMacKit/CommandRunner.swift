import Foundation
import Darwin

/// Result of one non-interactive child process. Each output stream retains at
/// most its first 2 MiB plus a truncation notice; diagnostics must never print credentials.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
}

public enum CommandError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)
    case failed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Could not launch the command: \(message)"
        case .timedOut(let seconds):
            return "The command did not finish within \(Int(seconds)) seconds."
        case .failed(_, let message):
            return message
        }
    }
}

/// Injectable command execution seam. Production uses `ProcessCommandRunner`;
/// unit tests use a scripted runner so no real service manager is touched.
public protocol CommandRunning: Sendable {
    func run(executable: URL,
             arguments: [String],
             environment: [String: String]?,
             timeout: TimeInterval) throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    /// A small, explicit PATH. The GUI's environment is not a shell login
    /// environment and must not decide which `term-llm` we execute.
    public static let defaultPATH = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

    public init() {}

    public func run(executable: URL,
                    arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval = 20) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = env["PATH"].map { Self.defaultPATH + ":" + $0 } ?? Self.defaultPATH
        if let environment {
            for (key, value) in environment { env[key] = value }
        }
        // Never inherit a caller's token through an unrelated variable; the
        // managed service token is read explicitly by ServiceController.
        process.environment = env
        try Task.checkCancellation()
        let deadline = DispatchTime.now() + max(0, timeout)
        let stdout = Pipe()
        let stderr = Pipe()
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        var out = try CommandOutput(handle: stdout.fileHandleForReading)
        var err = try CommandOutput(handle: stderr.fileHandleForReading)
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }
        // Process has inherited the write ends. Keeping our own copies open
        // would prevent EOF even for commands that have no descendants.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                process.terminate()
                // Cleanup has a short, independent grace period, never an
                // unbounded waitUntilExit (including after SIGKILL).
                if finished.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
                   process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            // Observe exit before testing the deadline: successful completion
            // must not become a timeout just because this thread woke up late.
            if !process.isRunning {
                // Collect final bytes for at most 100 ms without extending the
                // command deadline. A descendant continuously writing either
                // pipe must not turn a completed child into a timeout.
                let outputDeadline = min(deadline, DispatchTime.now() + .milliseconds(100))
                repeat {
                    try Task.checkCancellation()
                    let readOut = try out.drain(into: &buffer)
                    let readErr = try err.drain(into: &buffer)
                    if !readOut && !readErr { break }
                } while DispatchTime.now() < outputDeadline
                break
            }
            guard DispatchTime.now() < deadline else {
                throw CommandError.timedOut(seconds: timeout)
            }

            // Nonblocking, bounded reads service BOTH pipes on every turn, so
            // neither a chatty stdout nor stderr can starve the other/deadline.
            let readOut = try out.drain(into: &buffer)
            let readErr = try err.drain(into: &buffer)
            if readOut || readErr { continue }

            // Wake regularly for process-exit/cancellation checks even when a
            // descendant holds an otherwise idle pipe open.
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline.uptimeNanoseconds - min(now, deadline.uptimeNanoseconds)
            let milliseconds = Int32(min(50, remaining / 1_000_000 + 1))
            var descriptors = [out.pollDescriptor, err.pollDescriptor]
            let ready = poll(&descriptors, nfds_t(descriptors.count), milliseconds)
            if ready < 0 && errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        return CommandResult(status: process.terminationStatus,
                             stdout: out.text,
                             stderr: err.text)
    }
}

/// Only the calling thread owns these nonblocking descriptors and buffers.
/// Unlike blocking reader tasks, closing them cannot strand a reader in read().
private struct CommandOutput {
    private static let limit = 2 * 1024 * 1024
    private let descriptor: Int32
    private var reachedEOF = false
    private var data = Data()
    private var truncated = false

    init(handle: FileHandle) throws {
        descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw CommandError.launchFailed("Could not configure command output pipes.")
        }
    }

    var pollDescriptor: pollfd {
        pollfd(fd: reachedEOF ? -1 : descriptor, events: Int16(POLLIN), revents: 0)
    }

    /// Returns whether bytes were consumed (or an interrupted read needs retry).
    mutating func drain(into buffer: inout [UInt8]) throws -> Bool {
        guard !reachedEOF else { return false }
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
            let retained = min(count, Self.limit - data.count)
            data.append(contentsOf: buffer.prefix(retained))
            truncated = truncated || retained < count
            return true
        }
        if count == 0 {
            reachedEOF = true
        } else if errno == EINTR {
            return true
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return false
    }

    var text: String {
        String(decoding: data, as: UTF8.self)
            + (truncated ? "\n[output truncated after \(Self.limit) bytes]\n" : "")
    }
}
