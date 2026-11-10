import CoreGraphics
import Darwin
import Foundation
import os

// The wire between `term-llm-computer` and the helper (macos-harness protocol.py):
// one frame is a 4-byte little-endian length, then UTF-8 JSON-RPC. Envelopes and
// paths live here so client and helper agree on them.

public enum WireError: Error, Equatable {
    case closed
    case timedOut
    case frameTooLarge(Int)
    case badJSON
    case system(String, Int32)
}

public enum Wire {
    // MARK: Envelopes

    /// The part of the caller's environment the helper gets. Only names that identify
    /// the session or configure computer use: never tokens such as TERM_LLM_HUB_TOKEN.
    public static func passed(_ env: [String: String]) -> [String: String] {
        env.filter { name, _ in
            name.hasPrefix("TERM_LLM_COMPUTER_") || name == "TERM_LLM_SESSION_ID" || name == "HOME"
        }
    }

    private static let ids = Counter()

    /// The envelope of one tool call. `deadline` is seconds since 1970.
    public static func request(argv: [String], stdin: String?, cwd: String, env: [String: String],
                               deadline: TimeInterval, version: String) -> [String: Any] {
        var params: [String: Any] = [
            "callerApi": Limits.apiVersion,
            "clientVersion": version,
            "deadlineMs": Int64(deadline * 1000),
            "argv": argv,
            "cwd": cwd,
            "env": passed(env),
        ]
        params["stdin"] = stdin ?? NSNull()
        return ["id": ids.next(), "jsonrpc": "2.0", "method": "request", "params": params]
    }

    /// `ping`, `shutdown`, `status`, `stop` (the person's Stop) and friends.
    public static func control(_ method: String, params: [String: Any]? = nil) -> [String: Any] {
        var message: [String: Any] = ["id": ids.next(), "jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        return message
    }

    public static func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["id": id, "jsonrpc": "2.0", "result": value]
    }

    public static func reply(id: Any, exit: Int32, stdout: String, stderr: String) -> [String: Any] {
        result(id: id, ["exit": Int(exit), "stdout": stdout, "stderr": stderr])
    }

    /// Transport errors of the helper: name -> (code, text).
    public static let transportErrors: [String: (Int, String)] = [
        "notAuthenticated": (101, "The calling process may not use this socket"),
        "versionMismatch": (102, "term-llm-computer and the term-llm Computer Use helper are different versions. Update or restart term-llm, then call the tool again."),
        "invalidRequest": (-32600, "The id of a JSON-RPC message has to be a string or a number."),
        "methodNotFound": (-32601, "Method not found"),
        "deadlineExceeded": (-32000, "The deadline of the request has passed"),
        "stopping": (-32002, "The term-llm Computer Use helper is shutting down. Run the command again."),
        "responseTooLarge": (-32001, "The response is larger than one frame may be"),
    ]

    public static func error(id: Any, name: String, data: [String: Any]? = nil) -> [String: Any] {
        let (code, message) = transportErrors[name] ?? (-32603, name)
        let body: [String: Any] = ["code": code, "message": message, "errorName": name, "data": data ?? NSNull()]
        return ["id": id, "jsonrpc": "2.0", "error": body]
    }

    // MARK: Frames

    public static func pack(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw WireError.badJSON }
        let body = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard body.count <= Limits.maxFrameBytes else { throw WireError.frameTooLarge(body.count) }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Write one frame. A peer that went away raises `.closed` (SIGPIPE is never raised:
    /// sockets made here set SO_NOSIGPIPE).
    public static func write(_ object: [String: Any], to fd: Int32, deadline: Date? = nil) throws {
        let frame = try pack(object)
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let sent = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if sent < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    if errno == EPIPE || errno == ECONNRESET { throw WireError.closed }
                    throw WireError.system("write", errno)
                }
                offset += sent
            }
        }
    }

    /// The next frame. `.closed` when the other side is gone.
    public static func read(from fd: Int32, deadline: Date? = nil) throws -> [String: Any] {
        let header = try exactly(4, from: fd, deadline: deadline)
        let size = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard size <= Limits.maxFrameBytes else { throw WireError.frameTooLarge(size) }
        let body = try exactly(size, from: fd, deadline: deadline)
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw WireError.badJSON
        }
        return object
    }

    /// Send one message and read its answer.
    public static func call(_ message: [String: Any], on fd: Int32, deadline: Date? = nil) throws -> [String: Any] {
        try write(message, to: fd, deadline: deadline)
        return try read(from: fd, deadline: deadline)
    }

    private static func exactly(_ count: Int, from fd: Int32, deadline: Date?) throws -> Data {
        var data = Data(count: count)
        var have = 0
        while have < count {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let got = data.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress! + have, count - have)
            }
            if got == 0 { throw WireError.closed }
            if got < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                if errno == ECONNRESET { throw WireError.closed }
                throw WireError.system("read", errno)
            }
            have += got
        }
        return data
    }

    /// Wait until `fd` is ready for `events`, or throw `.timedOut` at `deadline`.
    public static func wait(_ fd: Int32, events: Int16, deadline: Date?) throws {
        while true {
            var timeout: Int32 = -1
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                if left <= 0 { throw WireError.timedOut }
                timeout = Int32(min(left * 1000, Double(Int32.max)).rounded(.up))
            }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&poller, 1, timeout)
            if ready > 0 { return }
            if ready == 0 { continue }
            if errno == EINTR { continue }
            throw WireError.system("poll", errno)
        }
    }
}

final class Counter: Sendable {
    private let value = OSAllocatedUnfairLock<Int64>(initialState: 0)

    func next() -> Int64 {
        value.withLock {
            $0 += 1
            return $0
        }
    }
}

// MARK: - Paths

public enum Paths {
    /// The folder for everything kept on disk:
    /// ~/.config/term-llm/app/computer-use (TERM_LLM_COMPUTER_HOME overrides, for tests).
    /// Fixed under the home folder like the rest of the app's files: GUI apps don't
    /// see XDG_CONFIG_HOME.
    public static func stateDirectory(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = env["TERM_LLM_COMPUTER_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return homeDirectory()
            .appendingPathComponent(".config/term-llm/app/computer-use", isDirectory: true)
    }

    /// The real home folder of this user, whatever HOME says.
    public static func homeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// A longer path does not fit a Unix socket address.
    public static let socketPathBytes = 100

    public static func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = env["TERM_LLM_COMPUTER_SOCKET"], !override.isEmpty { return override }
        let path = stateDirectory(env: env).appendingPathComponent("helper.sock").path
        if path.utf8.count > socketPathBytes {
            return "/tmp/term-llm-computer-\(getuid())/helper.sock"
        }
        return path
    }

    /// Next to the socket: one helper per socket.
    public static func lockPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        (socketPath(env: env) as NSString).deletingPathExtension + ".lock"
    }

    public static func logPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        stateDirectory(env: env).appendingPathComponent("helper.log").path
    }

    /// Screenshots: not in the temp folder (an agent's sandbox gives each process its own).
    public static func screenshotDirectory() -> URL {
        homeDirectory().appendingPathComponent("Library/Caches/term-llm/computer-use/screenshots", isDirectory: true)
    }
}

// MARK: - Unix sockets

public enum UnixSocket {
    /// The folder of a socket must be this user's alone. One that is too open is
    /// closed. One another user made first, a link of theirs, or something that is
    /// not a folder throws: whoever listens there is not our helper.
    public static func ownFolder(_ path: String) throws {
        var link = stat()
        var found = stat()
        if lstat(path, &link) != 0 {
            if errno == ENOENT { return }
            throw WireError.system("lstat", errno)
        }
        guard stat(path, &found) == 0 else { throw WireError.system("stat", errno) }
        let uid = getuid()
        guard link.st_uid == found.st_uid, link.st_uid == uid || found.st_uid == uid else {
            throw WireError.system("\(path) belongs to another user", EPERM)
        }
        guard (found.st_mode & S_IFMT) == S_IFDIR else {
            throw WireError.system("\(path) is not a folder", ENOTDIR)
        }
        if found.st_mode & 0o077 != 0 { chmod(path, 0o700) }
    }

    /// Make the folder (0700) and check it.
    public static func makeOwnFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ownFolder(path)
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw WireError.system("socket path too long", ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func newSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Connect, giving up after `timeout`. ENOENT/ECONNREFUSED mean nobody listens.
    public static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = try newSocket()
        var addr = try address(path)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let error = errno
            if error == EINPROGRESS || error == EAGAIN {
                do {
                    try Wire.wait(fd, events: Int16(POLLOUT), deadline: Date().addingTimeInterval(timeout))
                } catch {
                    close(fd)
                    throw error
                }
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                if soError != 0 {
                    close(fd)
                    throw WireError.system("connect", soError)
                }
            } else {
                close(fd)
                throw WireError.system("connect", error)
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    /// Bind and listen at `path`, mode 0600. A socket file left there is removed first:
    /// call this only while holding the helper lock.
    public static func listen(_ path: String, backlog: Int32 = 64) throws -> Int32 {
        unlink(path)
        let fd = try newSocket()
        var addr = try address(path)
        let old = umask(0o177)
        defer { umask(old) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw WireError.system("bind", error)
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            let error = errno
            close(fd)
            throw WireError.system("listen", error)
        }
        return fd
    }

    /// The user of the process at the other end (LOCAL_PEERCRED).
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var cred = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, 0x001 /* LOCAL_PEERCRED */, &cred, &length) == 0 else { return nil }
        return cred.cr_uid
    }

    /// The process at the other end (LOCAL_PEERPID), as it was when it connected.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &length) == 0 else { return nil }
        return pid
    }
}
