import XCTest

@testable import ComputerUseCore

final class ToolParserTests: XCTestCase {
    func testUpstreamParserCases() throws {
        let cases: [([String], [String: Any])] = [
            (["click", "--app", "X", "--element_index", "40"], ["element_index": "40"]),
            (["click", "--app", "X", "--element-index", "40"], ["element_index": "40"]),
            (["click", "--app", "X", "--elementIndex", "40"], ["element_index": "40"]),
            (["click", "--APP", "X", "--mouseButton", "right"], ["mouse_button": "right"]),
            (["click", "--app", "X", "--clickCount", "2"], ["click_count": "2"]),
            (["select_text", "X", "1", "a", "--selectionType", "cursor_before"], ["selection_type": "cursor_before"]),
            (["get_app_state", "X", "--disableDiffing"], ["disableDiff": true]),
            (["get_app_state", "X", "--disable-diff"], ["disableDiff": true]),
            (["select_text", "X", "1", "a", "--selection", "cursor_after"], ["selection_type": "cursor_after"]),
            (["click", "X", "--index", "3"], ["element_index": "3"]),
            (["click", "X", "--element", "3"], ["element_index": "3"]),
            (["click", "X", "3", "--button", "r"], ["mouse_button": "r"]),
            (["click", "X", "3", "--count", "2"], ["click_count": "2"]),
            (["click", "--app=X", "--element_index=40"], ["app": "X", "element_index": "40"]),
            (["type_text", "X", "--text=a=b"], ["text": "a=b"]),
            (["type_text", "X", "--text="], ["text": ""]),
            (["type_text", "--app", "X", "--text", "-5"], ["text": "-5"]),
            (["type_text", "--app", "X", "--text", "--force"], ["text": "--force"]),
            (["type_text", "--app", "X", "--text", "--json"], ["text": "--json"]),
            (["press_key", "--app", "X", "--key", "minus"], ["key": "minus"]),
            (["paste", "X", "-PASTE"], ["text": "-PASTE"]),
            (["get_app_state", "X"], ["disableDiff": false, "emit": true]),
            (["get_app_state", "X", "--disableDiff"], ["disableDiff": true]),
            (["get_app_state", "X", "--disableDiff", "true"], ["disableDiff": true]),
            (["get_app_state", "X", "--disableDiff", "false"], ["disableDiff": false]),
            (["get_app_state", "X", "--disableDiff", "0"], ["disableDiff": false]),
            (["get_app_state", "X", "--disableDiff=1"], ["disableDiff": true]),
            (["get_app_state", "--disableDiff", "X"], ["disableDiff": true, "app": "X"]),
            (["get_app_state", "X", "--emit", "false"], ["emit": false]),
            (["list_apps", "--emit", "false"], ["emit": false]),
            (["list_apps"], ["emit": true]),
            (["click", "{\"app\":\"Finder\",\"element_index\":40}"], ["app": "Finder", "element_index": 40]),
            (
                ["click", "{\"app\": \"Google Chrome\", \"element_index\": \"7\", \"click_count\": 1}"],
                ["app": "Google Chrome", "element_index": "7", "click_count": 1]
            ),
            (
                ["get_app_state", "{\"app\":\"Finder\",\"emit\":false,\"disableDiffing\":true}"],
                ["app": "Finder", "emit": false, "disableDiff": true]
            ),
            (
                ["click", "{\"app\":\"X\",\"elementIndex\":4,\"mouseButton\":2}"],
                ["element_index": 4, "mouse_button": 2]
            ),
            (["type_text", "X", "{\"not\":\"arguments\"}"], ["text": "{\"not\":\"arguments\"}"]),
            (["type_text", "{curly"], ["app": "{curly"]),
            (["get_app_state", "Finder"], ["app": "Finder"]),
            (["click", "X", "11"], ["app": "X", "element_index": "11"]),
            (
                ["set_value", "X", "7", "https://example.invalid"],
                ["element_index": "7", "value": "https://example.invalid"]
            ),
            (["type_text", "X", "pine nuts"], ["text": "pine nuts"]),
            (["press_key", "X", "Return"], ["key": "Return"]),
            (
                ["scroll", "Slack", "338", "up", "3"],
                ["app": "Slack", "element_index": "338", "direction": "up", "pages": "3"]
            ),
            (["select_text", "X", "5", "The model"], ["element_index": "5", "text": "The model"]),
            (["perform_secondary_action", "X", "0", "Raise"], ["element_index": "0", "action": "Raise"]),
            (["paste", "X", "salt"], ["text": "salt", "format": "text"]),
            (
                ["drag", "X", "200", "850", "800", "1000"],
                ["from_x": "200", "from_y": "850", "to_x": "800", "to_y": "1000"]
            ),
            (["click", "--app", "Finder", "40"], ["app": "Finder", "element_index": "40"]),
            (
                ["scroll", "X", "--direction", "up", "338", "3"],
                ["element_index": "338", "pages": "3", "direction": "up"]
            ),
            (
                ["scroll", "Slack", "--x", "611", "--y", "310", "up", "5"],
                ["x": "611", "y": "310", "direction": "up", "pages": "5"]
            ),
            (["click", "X", "--x", "415", "--y", "481"], ["x": "415", "y": "481"]),
            (["click", "X", "423", "--mouseButton", "right"], ["element_index": "423", "mouse_button": "right"]),
            (
                ["get_app_state", "X", "--emit", "false", "--disableDiffing", "true"],
                ["emit": false, "disableDiff": true]
            ),
            (["paste", "X", "<p>hi</p>", "--format", "html"], ["text": "<p>hi</p>", "format": "html"]),
            (
                ["get_app_state", "--app", "/Applications/Demo 2.app", "--disableDiff", "true"],
                ["app": "/Applications/Demo 2.app", "disableDiff": true]
            ),
            (
                ["type_text", "--app", "com.apple.Safari", "--text", "https://example.com/a"],
                ["app": "com.apple.Safari", "text": "https://example.com/a"]
            ),
        ]
        for (argv, expected) in cases {
            let call = try ToolParser.parse(argv)
            XCTAssertEqual(call.name, argv[0])
            for (key, value) in expected {
                XCTAssertEqual(
                    NSDictionary(dictionary: [key: call.arguments[key] ?? NSNull()]),
                    NSDictionary(dictionary: [key: value]), "\(argv): \(key)")
            }
        }
    }
    func testTablesAndHelp() throws {
        XCTAssertEqual(ToolParser.tools.count, 11)
        XCTAssertThrowsError(try ToolParser.parse(["approve", "Finder"]))
        XCTAssertThrowsError(try ToolParser.help("approve"))
        XCTAssertFalse(try ToolParser.help().contains("approve"))
        XCTAssertTrue(ComputerUseSkill.text.contains("Never operate the permission or settings controls of term-llm Computer Use: they are the person's."))
        XCTAssertEqual(
            Set(ToolParser.commands.map(\.name)),
            Set(["doctor", "skill", "turn-started", "turn-ended", "help"]))
        for tool in ToolParser.tools {
            XCTAssertFalse(tool.description.isEmpty)
            XCTAssertTrue(tool.example.hasPrefix(commandName + " " + tool.name))
            for param in tool.params + tool.bare + tool.hidden { XCTAssertNotNil(ToolParser.parameters[param]) }
        }
        for name in ["get-app-state", "getAppState", "GET_APP_STATE"] {
            XCTAssertEqual(try ToolParser.parse([name, "Finder"]).name, "get_app_state")
        }
        XCTAssertEqual(try ToolParser.parse(["turn_ended"]).name, "turn-ended")
        XCTAssertEqual(try ToolParser.parse(["--help"]).name, "help")
        XCTAssertTrue(try ToolParser.help().contains("Other commands: doctor, skill"))
        XCTAssertFalse(try ToolParser.help("get_app_state").contains("--emit"))
        XCTAssertNil(
            try ToolParser.parse(["scroll", "Slack", "--x", "611", "--y", "310", "up", "5"]).arguments["element_index"])
        XCTAssertEqual(try ToolParser.parse(["--json", "list_apps"]).arguments["json"] as? Bool, true)
        XCTAssertEqual(try ToolParser.parse(["list_apps", "--json"]).arguments["json"] as? Bool, true)
    }
    func testUsageErrors() {
        for (argv, contains) in [
            (["click", "--window", "2"], "Unknown flag --window for click. Flags: --app, "),
            (["launch_app", "Finder"], "Unknown tool launch_app. Tools: list_apps"),
            (["click", "X", "1", "extra"], "Unexpected argument 'extra' for click."),
            (["scroll", "X", "--pixels", "3"], "scroll takes --pages here; --pixels is not supported."),
        ] {
            XCTAssertThrowsError(try ToolParser.parse(argv)) { error in
                let error = error as! HarnessError
                XCTAssertTrue(error.isUsage)
                XCTAssertTrue(error.message.contains(contains), error.message)
                if argv[0] != "scroll" { XCTAssertTrue(error.message.contains("\nExample: term-llm-computer")) }
            }
        }
    }
}
