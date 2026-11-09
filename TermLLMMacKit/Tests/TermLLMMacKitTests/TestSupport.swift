import XCTest
@testable import TermLLMMacKit
import Foundation

final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _results: [CommandResult] = []
    var handler: ((URL, [String], [String: String]?) throws -> CommandResult)?
    var fallback = CommandResult(status: 0, stdout: "", stderr: "")

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func enqueue(_ result: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        _results.append(result)
    }

    func run(executable: URL,
             arguments: [String],
             environment: [String: String]?,
             timeout: TimeInterval) throws -> CommandResult {
        lock.lock()
        _calls.append(Call(executable: executable.path, arguments: arguments))
        let result = _results.isEmpty ? fallback : _results.removeFirst()
        lock.unlock()
        if let handler { return try handler(executable, arguments, environment) }
        return result
    }
}

enum ServiceHelpFixtures {
    /// Verbatim shape of 0.9.94's answer to `service rebind --help` and
    /// `service reload web`: the parent help, exit 0.
    static let parentHelp = """
    Manage one Web service and one Hub service through systemd (Linux) or launchd
    (macOS). New installs default to loopback and passkey authentication.

    Examples:
      term-llm service install web
      term-llm service rebind web --binary /path/to/term-llm

    Usage:
      term-llm service [command]

    Available Commands:
      autostart   Change or query login autostart without starting or stopping
      install     Install or reconcile a service (defaults to web)

    Flags:
      -h, --help   help for service

    Use "term-llm service [command] --help" for more information about a command.
    """

    static func subcommandHelp(_ operation: String) -> String {
        """
        Change the service executable, preserving state and autostart

        Usage:
          term-llm service \(operation) [web|hub] [flags]

        Flags:
          -h, --help   help for \(operation)
        """
    }

    static func help(for operation: String, supported: Bool) -> CommandResult {
        CommandResult(status: 0, stdout: supported ? subcommandHelp(operation) : parentHelp, stderr: "")
    }
}

enum ServiceFixtures {
    static let readyJSON = """
    {
      "schema_version": 1,
      "generated_at": "2026-11-07T09:00:00Z",
      "uid": 501,
      "platform": "darwin",
      "services": [
        {
          "kind": "web",
          "installed": true,
          "managed": true,
          "registered": true,
          "state": "ready",
          "running": true,
          "pid": 1234,
          "autostart": true,
          "binary": "/Users/tester/.config/term-llm/app/bin/term-llm",
          "url": "http://127.0.0.1:8765/ui/",
          "host": "127.0.0.1",
          "port": 8765,
          "base_path": "/ui",
          "auth": "bearer",
          "enrollment": "not_required",
          "healthy": true,
          "spec_path": "/Users/tester/.config/term-llm/services/web/service.json",
          "native_path": "/Users/tester/Library/LaunchAgents/com.term-llm.web.plist"
        }
      ]
    }
    """

    static let stoppedJSON = """
    {
      "schema_version": 1,
      "services": [
        {
          "kind": "web", "installed": true, "managed": true, "registered": true,
          "state": "stopped", "running": false, "autostart": false,
          "url": "http://localhost:9000/prefix/", "host": "localhost", "port": 9000,
          "base_path": "/prefix", "auth": "passkey", "enrollment": "pending",
          "healthy": false
        }
      ]
    }
    """
}
