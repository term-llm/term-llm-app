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
        return result
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
          "binary": "/Users/tester/Library/Application Support/TermLLM/bin/term-llm",
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
