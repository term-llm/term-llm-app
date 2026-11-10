import Foundation

/// Table-driven argv contract, ported from macos-harness tools.py (43d9edf).
/// Validation of numeric values belongs to the executor, not the argv parser.
public struct ToolDefinition {
    public let name: String
    public var params: [String] = []
    public var bare: [String] = []
    public var defaults: [String: Any] = [:]
    public var description: String = ""
    public var example: String = ""
    public var hidden: [String] = []
    public var refused: [String: String] = [:]
    public var stdin: String? = nil
}

public struct ParsedToolCall {
    public let name: String
    public var arguments: [String: Any]
    public var tool: ToolDefinition { ToolParser.table[name]! }
}

public enum ToolParser {
    public static let parameters: [String: (kind: String, description: String)] = [
        "app": ("str", "The app: its name, its bundle id or the full path of its bundle"),
        "disableDiff": ("bool", "Print the whole tree, not only what changed"),
        "emit": ("bool", "false: do the read and print only the Screenshot line"),
        "keep": ("bool", "Keep the screenshot for good, as proof (a path without spaces)"),
        "element_index": ("int", "The number of the element in the last get_app_state text"),
        "x": ("num", "Horizontal pixel position in the screenshot"),
        "y": ("num", "Vertical pixel position in the screenshot"),
        "mouse_button": ("button", "Which mouse button: left (the default), right or middle."),
        "click_count": ("int", "How many clicks (default 1)"),
        "key": (
            "str",
            "A key name, or a chord joined with + (X11 keysym names: a, space, Return, Tab, Control_L+a, Super_L+d). Spaces around + do not matter; Control, Ctrl, Alt and Shift work too. With click: the keys held during the click"
        ),
        "duration": ("num", "Seconds to hold each press (0 to 30)"),
        "duration_ms": ("num", "The same in milliseconds (0 to 30000)"),
        "from_x": ("num", "Where the drag starts: horizontal pixel position in the screenshot"),
        "from_y": ("num", "Where the drag starts: vertical pixel position in the screenshot"),
        "to_x": ("num", "Where the drag ends: horizontal pixel position in the screenshot"),
        "to_y": ("num", "Where the drag ends: vertical pixel position in the screenshot"),
        "text": ("str", "The text, exactly. Missing or -: read from stdin"),
        "value": ("str", "Replacement value. Missing or -: read from stdin"),
        "direction": ("str", "up, down, left or right"),
        "pages": ("num", "How many pages to scroll; fractions work (default 1)"),
        "prefix": ("str", "The text just before the wanted text, when it occurs more than once"),
        "suffix": ("str", "The text just after the wanted text, when it occurs more than once"),
        "selection_type": ("str", "text, cursor_before or cursor_after. Defaults to text"),
        "action": ("str", "A name from the element's Secondary Actions"),
        "format": ("str", "text, md or html. Defaults to text"),
        "agent": ("str", "The agent CLI to install the skill for"),
        "scope": ("str", "project or user"),
        "always": ("bool", "Keep the approval after this session"),
        "cancel": ("bool", "Also stop the action the agent still runs"),
        "tool": ("str", "A tool name"),
        "json": ("bool", "Print the result object as JSON"),
        "help": ("bool", "Show this text"),
    ]
    public static let spellings: [String: String] = [
        "disablediffing": "disableDiff", "selection": "selection_type", "index": "element_index",
        "element": "element_index", "button": "mouse_button", "count": "click_count",
    ]
    public static let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "list_apps", defaults: ["emit": true],
            description:
                "Show the apps on this Mac: those running now and those used in the past 14 days, with how often each was used",
            example: "term-llm-computer list_apps", hidden: ["emit"]),
        ToolDefinition(
            name: "get_app_state", params: ["app", "disableDiff", "keep"], bare: ["app"],
            defaults: ["disableDiff": false, "emit": true, "keep": false],
            description:
                "Read an app's key window as an accessibility tree plus a screenshot, opening a session for the app first when there is none. Needed once in every assistant turn before any action on that app",
            example: "term-llm-computer get_app_state --app Finder", hidden: ["emit"]),
        ToolDefinition(
            name: "click",
            params: ["app", "element_index", "x", "y", "mouse_button", "click_count", "key", "duration"],
            bare: ["app", "element_index"], defaults: ["mouse_button": "left", "click_count": 1],
            description: "Click one element, given by its index or by a pixel position in the screenshot",
            example: "term-llm-computer click --app Finder --element_index 40", hidden: ["duration_ms"]),
        ToolDefinition(
            name: "perform_secondary_action", params: ["app", "element_index", "action"],
            bare: ["app", "element_index", "action"], description: "Run one of the secondary actions an element lists",
            example: "term-llm-computer perform_secondary_action --app Finder --element_index 0 --action Raise"),
        ToolDefinition(
            name: "set_value", params: ["app", "element_index", "value"], bare: ["app", "element_index", "value"],
            description: "Write a new value into an element that is marked settable",
            example: "term-llm-computer set_value --app Finder --element_index 2 --value \"report.txt\"", stdin: "value"
        ),
        ToolDefinition(
            name: "select_text", params: ["app", "element_index", "text", "prefix", "suffix", "selection_type"],
            bare: ["app", "element_index", "text"], defaults: ["selection_type": "text"],
            description:
                "Select a piece of text in a text element, or put the cursor right before or after it. Give the text as the accessibility tree prints it, Markdown marks included. When it occurs more than once, add the text before or after it as prefix or suffix.",
            example: "term-llm-computer select_text --app TextEdit --element_index 3 --text \"hello\""),
        ToolDefinition(
            name: "scroll", params: ["app", "element_index", "x", "y", "direction", "pages"],
            bare: ["app", "element_index", "direction", "pages"], defaults: ["pages": 1],
            description: "Scroll one element up, down, left or right by pages",
            example: "term-llm-computer scroll --app Finder --element_index 3 --direction down --pages 1",
            refused: ["pixels": "pixels"]),
        ToolDefinition(
            name: "drag", params: ["app", "from_x", "from_y", "to_x", "to_y"],
            bare: ["app", "from_x", "from_y", "to_x", "to_y"],
            description: "Drag between two pixel positions of the screenshot",
            example: "term-llm-computer drag --app Finder --from_x 200 --from_y 300 --to_x 400 --to_y 300"),
        ToolDefinition(
            name: "press_key", params: ["app", "key", "duration"], bare: ["app", "key"],
            description:
                "Press one key or a chord, modifiers and navigation keys included, written the way xdotool writes keys: \"a\", \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\" (the 0 of the number pad).",
            example: "term-llm-computer press_key --app Finder --key super+c", hidden: ["duration_ms"]),
        ToolDefinition(
            name: "type_text", params: ["app", "text"], bare: ["app", "text"],
            description: "Type the given text as key presses",
            example: "term-llm-computer type_text --app TextEdit --text \"hello world\"", stdin: "text"),
        ToolDefinition(
            name: "paste", params: ["app", "text", "format"], bare: ["app", "text"], defaults: ["format": "text"],
            description: "Paste text into an app's window and put back what was on the clipboard before.",
            example: "term-llm-computer paste --app TextEdit --text \"hello world\"", stdin: "text"),
    ]
    public static let commands: [ToolDefinition] = [
        ToolDefinition(name: "doctor"),
        ToolDefinition(name: "skill"),
        ToolDefinition(name: "turn-started"),
        ToolDefinition(name: "turn-ended", params: ["cancel"], defaults: ["cancel": false]),
        ToolDefinition(name: "approve", params: ["app", "always"], bare: ["app"], defaults: ["always": false]),
        ToolDefinition(name: "help", bare: ["tool"]),
    ]
    public static var table: [String: ToolDefinition] {
        Dictionary(uniqueKeysWithValues: (tools + commands).map { ($0.name, $0) })
    }
    private static func plain(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
    }
    private static func example(_ error: HarnessError, _ name: String) -> HarnessError {
        var error = error
        error.message += "\nExample: " + (table[name]?.example ?? "")
        return error
    }
    public static func known(_ word: String) throws -> String {
        guard let tool = (tools + commands).first(where: { plain($0.name) == plain(word) }) else {
            throw example(
                Usage.error("unknown_tool", ["tool": word, "tools": tools.map(\.name).joined(separator: ", ")]),
                "get_app_state")
        }
        return tool.name
    }
    private static func flag(_ word: String, tool: ToolDefinition) throws -> String {
        let key = plain(spellings[plain(word)] ?? plain(word))
        if let refused = tool.refused[key] { throw Usage.error(refused) }
        guard let param = (tool.params + tool.hidden + tool.bare + ["json", "help"]).first(where: { plain($0) == key })
        else {
            let shown = tool.params.isEmpty ? "none" : tool.params.map { "--" + $0 }.joined(separator: ", ")
            throw example(Usage.error("unknown_flag", ["flag": word, "tool": tool.name, "flags": shown]), tool.name)
        }
        return param
    }
    private static let bools = ["true": true, "1": true, "false": false, "0": false]
    private static func string(_ value: Any) -> String {
        if let value = value as? String { return value }
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
    }
    public static func parse(_ argv: [String]) throws -> ParsedToolCall {
        var words = argv
        var args: [String: Any] = [:]
        while let word = words.first, word.hasPrefix("--"), ["json", "help"].contains(plain(word)) {
            args[plain(words.removeFirst())] = true
        }
        guard !words.isEmpty else {
            if args["help"] as? Bool == true { return ParsedToolCall(name: "help", arguments: args) }
            throw Usage.error("python_stdin")
        }
        let name = try known(words[0])
        let tool = table[name]!
        var at = 1
        var bare: [String] = []
        if words.count > 1, words[1].hasPrefix("{"), let data = words[1].data(using: .utf8),
            let given = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            for (key, value) in given {
                let param = try flag(key, tool: tool)
                if !(value is NSNull) { args[param] = value }
            }
            at = 2
        }
        while at < words.count {
            let word = words[at]
            at += 1
            guard word.hasPrefix("--"), word.count > 2 else {
                bare.append(word)
                continue
            }
            let parts = word.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let param = try flag(String(parts[0]), tool: tool)
            var value: String? = parts.count == 2 ? String(parts[1]) : nil
            if parts.count == 1 {
                if parameters[param]?.kind == "bool" {
                    value = "true"
                    if at < words.count, bools[words[at].lowercased()] != nil {
                        value = words[at]
                        at += 1
                    }
                } else if at < words.count {
                    value = words[at]
                    at += 1
                }
            }
            if let value { args[param] = value }
        }
        let point = args["x"] != nil || args["y"] != nil
        let free = tool.bare.filter { args[$0] == nil && !(point && $0 == "element_index") }
        if bare.count > free.count {
            throw example(
                Usage.error("unexpected_argument", ["argument": pythonRepr(bare[free.count]), "tool": name]), name)
        }
        for (key, value) in zip(free, bare) { args[key] = value }
        for (param, value) in args {
            switch parameters[param]?.kind {
            case "bool": args[param] = bools[string(value).lowercased()] ?? true
            case "str": args[param] = string(value)
            default: break
            }
        }
        return ParsedToolCall(name: name, arguments: tool.defaults.merging(args) { _, new in new })
    }
    public static func help(_ asked: String? = nil) throws -> String {
        guard let asked else {
            return "\(commandName) <tool> [--flag value ...]\n\n"
                + tools.map { "  " + $0.example }.joined(separator: "\n")
                + "\n\nOther commands: doctor, skill\nOne tool: \(commandName) <tool> --help"
        }
        let tool = table[try known(asked)]!
        return ([tool.description] + tool.params.map { "  --\($0): \(parameters[$0]!.description)" } + [tool.example])
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Version of the bundled Swift shell, shared by the two executables.
public enum ComputerUseVersion { public static let current = "0.1.0" }
