import ComputerUseCore
import Foundation
import IOKit.pwr_mgt

/// One immutable request envelope. Session turn marks must be accessed through
/// `sessions`; UI state is the integration executor's responsibility.
public struct ToolCallRequest {
    public let name: String
    public let arguments: [String: Any]
    public let stdin: String?
    public let environment: [String: String]
    public let agent: AgentSession
    public let sessions: Sessions
    public let cwd: String
    public let deadline: Date
    public let abandoned: () -> Bool
    /// Same FIFO, but turn cancellation must not prevent releasing its resources.
    public let withCleanupQueue: (_ path: String, _ work: () throws -> ToolOutcome) throws -> ToolOutcome
    /// The executor resolves the app first, then uses its canonical bundle path.
    /// This queue is shared across ALL agents, not just this session.
    public let withAppQueue: (_ path: String, _ work: () throws -> ToolOutcome) throws -> ToolOutcome
    public init(name: String, arguments: [String: Any], stdin: String?, environment: [String: String],
                agent: AgentSession, sessions: Sessions, cwd: String, deadline: Date,
                abandoned: @escaping () -> Bool,
                withCleanupQueue: ((_ path: String, _ work: () throws -> ToolOutcome) throws -> ToolOutcome)? = nil,
                withAppQueue: @escaping (_ path: String, _ work: () throws -> ToolOutcome) throws -> ToolOutcome) {
        self.name = name; self.arguments = arguments; self.stdin = stdin; self.environment = environment
        self.agent = agent; self.sessions = sessions; self.cwd = cwd; self.deadline = deadline
        self.abandoned = abandoned; self.withAppQueue = withAppQueue
        self.withCleanupQueue = withCleanupQueue ?? withAppQueue
    }
}

public struct NeedStdin: Error { public init() {} }

public struct ToolOutcome {
    public var exit: Int32
    public var stdout: String
    public var stderr: String
    public init(exit: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.exit = exit
        self.stdout = stdout
        self.stderr = stderr
    }
    public static func failure(_ error: HarnessError, json: Bool) -> ToolOutcome {
        if json,
            let data = try? JSONSerialization.data(
                withJSONObject: error.failureJSON, options: [.sortedKeys, .withoutEscapingSlashes])
        {
            return ToolOutcome(exit: error.isUsage ? 2 : 1, stdout: String(decoding: data, as: UTF8.self) + "\n")
        }
        return ToolOutcome(exit: error.isUsage ? 2 : 1, stderr: error.message + "\n")
    }
    public static func text(_ text: String, json: Bool) -> ToolOutcome {
        if json,
            let data = try? JSONSerialization.data(
                withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        {
            return ToolOutcome(stdout: String(decoding: data, as: UTF8.self) + "\n")
        }
        return ToolOutcome(stdout: text.isEmpty || text.hasSuffix("\n") ? text : text + "\n")
    }
}

public protocol ToolExecutor {
    /// Called off the main thread. May throw NeedStdin; the client will reconnect
    /// with stdin. No effects may precede that throw. Other errors become failures.
    func execute(_ call: ToolCallRequest) throws -> ToolOutcome
    /// Called after socket workers finish, with the AppKit loop still available.
    func shutdown()
    func agentExited(_ agent: AgentSession, withAppQueue: (String, () throws -> ToolOutcome) throws -> ToolOutcome)
}
extension ToolExecutor {
    public func shutdown() {}
    public func agentExited(_ agent: AgentSession, withAppQueue: (String, () throws -> ToolOutcome) throws -> ToolOutcome) {}
}

/// Integration seam: no Accessibility, event posting, or capture is done here.
public struct StubToolExecutor: ToolExecutor {
    public init() {}
    public func execute(_ call: ToolCallRequest) throws -> ToolOutcome {
        let json = call.arguments["json"] as? Bool == true
        switch call.name {
        case "help": return .text(try ToolParser.help(call.arguments["tool"] as? String), json: json)
        case "skill": return .text(ComputerUseSkill.text, json: json)
        case "turn-started":
            call.sessions.turnStarted(call.agent)
            return ToolOutcome(stdout: json ? "null\n" : "")
        case "turn-ended":
            call.sessions.turnEnded(call.agent, cancel: call.arguments["cancel"] as? Bool == true)
            return ToolOutcome(stdout: json ? "null\n" : "")
        default: throw Errors.serverError("Tool '\(call.name)' is not implemented yet in this Computer Use shell.")
        }
    }
}

/// Arrival-ordered lock with cancellable waiters. A cancelled ticket is removed,
/// not left at the head of the queue where it would stall every later caller.
public final class AppFIFO {
    private let condition = NSCondition()
    private var tickets: [UUID] = []
    private var busy = false
    public init() {}
    public func run<T>(abandoned: () -> Bool = { false }, _ work: () throws -> T) throws -> T {
        let ticket = UUID()
        condition.lock()
        tickets.append(ticket)
        while busy || tickets.first != ticket {
            if abandoned() {
                tickets.removeAll { $0 == ticket }
                condition.broadcast()
                condition.unlock()
                throw Errors.make("request_timed_out")
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        tickets.removeFirst()
        busy = true
        condition.unlock()
        defer {
            condition.lock()
            busy = false
            condition.broadcast()
            condition.unlock()
        }
        if abandoned() { throw Errors.make("request_timed_out") }
        return try work()
    }
}

/// One display-idle assertion for all calls; release exactly when the last exits.
final class DisplayAwake {
    private let lock = NSLock()
    private var count = 0
    private var token: IOPMAssertionID = 0
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count == 1 {
            _ = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "term-llm Computer Use at work" as CFString, &token)
        }
        var activity: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity(
            "term-llm Computer Use is working" as CFString,
            kIOPMUserActiveLocal, &activity)
    }
    func end() {
        lock.lock()
        defer { lock.unlock() }
        count -= 1
        if count == 0, token != 0 {
            IOPMAssertionRelease(token)
            token = 0
        }
    }
}
