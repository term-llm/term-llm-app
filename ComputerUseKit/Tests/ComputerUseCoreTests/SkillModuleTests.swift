import JavaScriptCore
import XCTest

@testable import ComputerUseCore

/// Runs the embedded `skill:computer-use` source in JavaScriptCore with a
/// fake `tools.shell` that answers in term-llm's shell-tool text format. QuickJS
/// is term-llm's engine; JSC stands in for syntax and behaviour, not for it.
final class SkillModuleTests: XCTestCase {
    func testFrontmatterDeclaresTheModule() {
        XCTAssertTrue(ComputerUseSkill.text.contains("code-mode:\n  module: js/index.mjs\n  files: [js/index.mjs]\n  requires:\n    tools: [shell]\n---"))
        XCTAssertEqual(ComputerUseSkill.modulePath, "js/index.mjs")
        XCTAssertTrue(ComputerUseSkill.text.contains("import('skill:\(ComputerUseSkill.name)')"))
        XCTAssertTrue(ComputerUseSkill.text.hasPrefix("---\nname: \(ComputerUseSkill.name)\n"), "term-llm needs the folder's name")
        XCTAssertEqual(ComputerUseSkill.name, "computer-use")
    }

    func testSkillPrefersSafeBatching() {
        let text = ComputerUseSkill.text
        XCTAssertTrue(text.contains("use one cell for multi-step UI tasks"))
        XCTAssertTrue(text.contains("do not batch speculative clicks or discard intermediate reads"))
        XCTAssertTrue(text.contains("Stop for failures, approval boundaries"))
        XCTAssertFalse(text.contains("Plain shell calls are the default"))
    }

    func testModuleAgainstFakeShell() throws {
        // Modules aren't available to JSContext.evaluateScript: drop `export`.
        let script = ComputerUseSkill.module
            .replacingOccurrences(of: "export const ", with: "const ")
            .replacingOccurrences(of: "export async function ", with: "async function ")
            .replacingOccurrences(of: "export function ", with: "function ")
        XCTAssertFalse(script.contains("export "))
        let context = try XCTUnwrap(JSContext())
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() }
        context.evaluateScript(Self.fakes + script + Self.checks)
        XCTAssertNil(thrown)
        XCTAssertEqual(context.objectForKeyedSubscript("result")?.toString(), "ok 6")
    }

    private static let fakes = #"""
        const calls = [], replies = [];
        globalThis.tools = {
          shell: async (request) => { calls.push(request); return { text: replies.shift(), isError: false, timedOut: false }; },
          view_image: async ({ file_path }) => ({ content: [{ type: "text", text: "x" }, { type: "image", handle: "cell-image:1", path: file_path }] }),
        };

        """#

    private static let checks = #"""

        function check(ok, what) { if (!ok) throw new Error("failed: " + what); }
        async function rejects(promise, test, what) {
          try { await promise; } catch (e) { check(test(e), what + ": " + e.message); return; }
          throw new Error("did not throw: " + what);
        }
        (async () => {
          const state = 'Window: "Untitled", App: TextEdit.\n0 standard window Untitled\n\t1 button Save\n\t2 text area (settable) Value: it\'s\n\nScreenshot (800x600 px): /tmp/a b.jpeg\n';
          replies.push("stdout:\n" + state + "\nexit_code: 0\n\nfilesystem_tracking: x");
          const read = await computer.get_app_state({ app: "Text'Edit", disableDiff: true, keep: false });
          check(calls[0].command === "term-llm-computer 'get_app_state' '--app' 'Text'\\''Edit' '--disableDiff'", "quoting " + calls[0].command);
          check(calls[0].timeout_seconds === 130 && calls[0].working_dir === undefined, "shell options");
          check(read.screenshot === "/tmp/a b.jpeg" && read.width === 800 && read.height === 600, "screenshot");
          check(!read.text.includes("Screenshot") && read.text.endsWith("Value: it's"), "text");
          check(find(read, /button Save/) === 1 && find(read, "text area") === 2 && find(read, "nothing") === null, "find");
          check((await computer.screenshot(read)).handle === "cell-image:1", "image block");
          check(find("\t13 radio button Dictionary, Value: 0\n~\t\t14 radio button Dictionary, Value: 1", /Dictionary/) === 14, "find newest diff line");
          check(changes("x\n\t1 a\n~\t2 b\n+\t3 c") === "~\t2 b\n+\t3 c", "changes");

          replies.push("[note]\nstdout:\nDone. Call `get_app_state` to see the new state of the UI.\n\nexit_code: 0");
          computer.options.working_dir = "/tmp";
          check(await computer.click({ app: "TextEdit", element_index: 1 }) === undefined, "action result");
          check(calls[1].working_dir === "/tmp", "working dir");
          check(calls[1].command === "term-llm-computer 'click' '--app' 'TextEdit' '--element_index' '1'", "click words");

          replies.push("stderr:\nNo element has the ID 9 in the last read.\n\nexit_code: 1");
          await rejects(computer.click({ app: "TextEdit", element_index: 9 }), (e) => e.exitCode === 1 && e.message === "No element has the ID 9 in the last read.", "helper error");

          replies.push("[Command timed out]\n\nstdout:\npartial\n");
          await rejects(computer.press_key({ app: "TextEdit", key: "Return" }), (e) => e.outcome === "unknown" && /may or may not have run/.test(e.message), "timeout");

          replies.push('stdout:\n[{"name":"Finder"}]\n\nexit_code: 0');
          check((await computer.list_apps())[0].name === "Finder", "list_apps");

          replies.push("stdout:\nxxxx\n\nexit_code: 0\n\n[Output truncated due to size limit]");
          check(/output cut/.test(await computer.run("get_app_state", "--app", "Big")), "truncation");
          globalThis.result = "ok " + calls.length;
        })().catch((e) => { globalThis.result = String(e && e.stack || e); });
        """#
}
