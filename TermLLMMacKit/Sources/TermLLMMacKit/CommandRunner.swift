import Foundation

/// Result of one non-interactive child process. Standard output is bounded by
/// the caller's timeout; diagnostics must never print credentials.
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
        let stdout = Pipe()
        let stderr = Pipe()
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
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CommandError.timedOut(seconds: timeout)
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = CommandResult(status: process.terminationStatus,
                                   stdout: String(decoding: outData, as: UTF8.self),
                                   stderr: String(decoding: errData, as: UTF8.self))
        return result
    }
}
