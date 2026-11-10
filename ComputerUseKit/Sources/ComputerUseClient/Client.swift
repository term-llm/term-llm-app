import ComputerUseCore
import Darwin
import Foundation

/// A transport-only client. The helper, never this process, parses or executes tools.
public enum ComputerUseClient {
    /// `argv` includes the executable name, like `CommandLine.arguments`.
    public static func main(_ argv: [String]) -> Int32 {
        let words = Array(argv.dropFirst())
        if words.first == "--version" {
            output(ComputerUseVersion.current + "\n", to: STDOUT_FILENO)
            return 0
        }
        // Some agent hosts leave commands orphaned after interrupting their shell.
        // Watch during frame reads AND stdin waits, not only before the first byte.
        let parent = getppid()
        let watcher = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watcher.schedule(deadline: .now(), repeating: .milliseconds(200))
        watcher.setEventHandler { if getppid() != parent { _exit(130) } }
        watcher.resume()
        defer { watcher.cancel() }
        do {
            let answer = try call(words)
            if let error = answer["error"] as? [String: Any] {
                let failure = HarnessError(
                    code: error["code"] as? Int ?? 100,
                    name: error["errorName"] as? String ?? "jsonRPCError",
                    message: error["message"] as? String ?? "Invalid helper response")
                return fail(failure, json: words.contains("--json"))
            }
            guard let result = answer["result"] as? [String: Any], let code = result["exit"] as? Int,
                let stdout = result["stdout"] as? String, let stderr = result["stderr"] as? String
            else {
                throw Errors.make("helper_stopped")
            }
            output(stdout, to: STDOUT_FILENO)
            output(stderr, to: STDERR_FILENO)
            return Int32(clamping: code)
        } catch let error as HarnessError {
            return fail(error, json: words.contains("--json"))
        } catch {
            return fail(Errors.make("helper_stopped"), json: words.contains("--json"))
        }
    }

    private static func fail(_ error: HarnessError, json: Bool) -> Int32 {
        if json,
            let data = try? JSONSerialization.data(
                withJSONObject: error.failureJSON, options: [.sortedKeys, .withoutEscapingSlashes])
        {
            output(String(decoding: data, as: UTF8.self) + "\n", to: STDOUT_FILENO)
        } else {
            output(error.message + "\n", to: STDERR_FILENO)
        }
        return 1
    }

    private static func call(_ argv: [String]) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(Limits.callTimeout)
        var stdin: String?
        var retried = false
        while true {
            let fd = try connect(deadline: deadline)
            let answer: [String: Any]
            do {
                defer { close(fd) }
                answer = try Wire.call(
                    Wire.request(
                        argv: argv, stdin: stdin,
                        cwd: FileManager.default.currentDirectoryPath, env: ProcessInfo.processInfo.environment,
                        deadline: deadline.timeIntervalSince1970, version: ComputerUseVersion.current),
                    on: fd, deadline: deadline)
            } catch WireError.timedOut { throw Errors.make("request_timed_out") } catch {
                throw Errors.make("helper_stopped")
            }
            let transport = (answer["error"] as? [String: Any])?["errorName"] as? String
            if ["versionMismatch", "stopping"].contains(transport ?? ""), !retried {
                // The helper explicitly ran nothing, so only here may we retry.
                // Ask the main app to replace it; never spawn a helper ourselves.
                retried = true
                if let old = try? tryConnect() {
                    _ = try? Wire.call(Wire.control("shutdown"), on: old, deadline: Date().addingTimeInterval(2))
                    close(old)
                }
                Thread.sleep(forTimeInterval: 0.2)
            } else if let result = answer["result"] as? [String: Any], result["needStdin"] as? Bool == true,
                stdin == nil
            {
                stdin = readStdin(deadline: deadline)
            } else {
                return answer
            }
        }
    }

    private static func tryConnect() throws -> Int32? {
        let path = Paths.socketPath()
        do {
            try UnixSocket.ownFolder((path as NSString).deletingLastPathComponent)
            let fd = try UnixSocket.connect(path, timeout: 0.25)
            guard UnixSocket.peerUID(fd) == getuid() else {
                close(fd)
                throw Errors.make("helper_unavailable")
            }
            // Wire waits against an absolute deadline before each partial I/O;
            // keep the actual writes nonblocking too, even for an 8 MiB frame.
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                close(fd)
                throw Errors.make("helper_unavailable")
            }
            return fd
        } catch WireError.system(_, let code) where code == ENOENT || code == ECONNREFUSED || code == ETIMEDOUT {
            return nil
        } catch WireError.timedOut { return nil } catch { throw Errors.make("helper_unavailable") }
    }

    private static func connect(deadline: Date) throws -> Int32 {
        if let fd = try tryConnect() { return fd }
        guard FileManager.default.fileExists(atPath: Paths.stateDirectory().appendingPathComponent("enabled").path)
        else {
            throw Errors.make("app_unavailable")
        }
        // LaunchServices opens the MAIN app, which owns the helper's lifecycle.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", "-b", "com.termllm.app"]
        open.standardInput = FileHandle.nullDevice
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
        let until = min(deadline, Date().addingTimeInterval(8))
        while Date() < until {
            Thread.sleep(forTimeInterval: 0.1)
            if let fd = try tryConnect() { return fd }
        }
        throw Errors.make("app_unavailable")
    }

    private static func readStdin(deadline: Date) -> String {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0,
            info.st_mode & S_IFMT == S_IFIFO || info.st_mode & S_IFMT == S_IFREG
        else { return "" }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count < Limits.maxFrameBytes {
            do {
                try Wire.wait(
                    STDIN_FILENO, events: Int16(POLLIN), deadline: min(deadline, Date().addingTimeInterval(2)))
            } catch { break }
            let count = Darwin.read(STDIN_FILENO, &buffer, min(buffer.count, Limits.maxFrameBytes - data.count))
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func output(_ text: String, to fd: Int32) {
        // Allow callers to use `| head` without terminating on SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let data = Data(text.utf8)
        data.withUnsafeBytes { bytes in
            var at = 0
            while at < bytes.count {
                let sent = Darwin.write(fd, bytes.baseAddress! + at, bytes.count - at)
                if sent < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if sent == 0 { return }
                at += sent
            }
        }
    }
}

public enum ComputerUseClientInfo { public static let version = ComputerUseVersion.current }
