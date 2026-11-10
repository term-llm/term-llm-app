import CoreGraphics
import Foundation

// Every error text the model can receive (macos-harness errors.py). One place, so
// each wording is written and tested once. Rule for new texts: say what happened,
// then what to do next.

public let product = "term-llm Computer Use"
public let commandName = "term-llm-computer"

/// A tool call failed. `message` is printed to the model as it is.
public struct HarnessError: Error, Equatable, CustomStringConvertible {
    public var code: Int
    public var name: String
    public var message: String
    /// The person did it (took over, said no). Not a failure of the tool.
    public var cancelled: Bool
    /// Machine-readable extra, for example "invalid_element_id".
    public var tag: String?
    /// Bad arguments, raised before any app is touched. Exit code 2.
    public var isUsage: Bool

    public init(code: Int, name: String, message: String, cancelled: Bool = false,
                tag: String? = nil, isUsage: Bool = false) {
        self.code = code
        self.name = name
        self.message = message
        self.cancelled = cancelled
        self.tag = tag
        self.isUsage = isUsage
    }

    public var description: String { message }

    /// The `--json` form of a failed call.
    public var failureJSON: [String: Any] {
        var body: [String: Any] = ["code": code, "name": name, "message": message, "cancelled": cancelled]
        if let tag { body["tag"] = tag }
        return ["error": body]
    }
}

public enum Usage {
    /// Argument checks. The texts are part of the tool contract.
    public static let texts: [String: String] = [
        "python_stdin": "Run one tool per command, for example: term-llm-computer get_app_state --app Finder",
        "app": "Give the app: --app <name, bundle id or path>",
        "element_index": "--element_index takes a whole number",
        "coordinate": "--x and --y must both be numbers",
        "from": "--from_x and --from_y must both be numbers",
        "to": "--to_x and --to_y must both be numbers",
        "mouse_button": "--mouse_button takes left, right or middle (also l, r, m or 0, 1, 2)",
        "mouse_button_number": "--mouse_button as a number takes 0, 1 or 2",
        "key": "Give the key: --key <name or chord>",
        "pages": "--pages takes a number above 0",
        "direction": "--direction takes up, down, left or right",
        "pixels": "scroll takes --pages here; --pixels is not supported.",
        "selection_type": "--selection_type cannot be {value}. Use text, cursor_before or cursor_after.",
        "duration": "--duration is not a usable time",
        "click_count": "clickCount must be {most} or less",
        "text_length": "text is longer than {most} characters. Use paste for long text",
        "finite_duration": "--duration takes a number of seconds",
        "unknown_flag": "Unknown flag --{flag} for {tool}. Flags: {flags}",
        "unknown_tool": "Unknown tool {tool}. Tools: {tools}",
        "unexpected_argument": "Unexpected argument {argument} for {tool}.",
    ]

    /// `values` fill `{name}` fields. Python's `{argument!r}` is written by the caller
    /// (see `pythonRepr`).
    public static func error(_ key: String, _ values: [String: String] = [:]) -> HarnessError {
        HarnessError(code: 0, name: "usage", message: format(texts[key] ?? key, values), isUsage: true)
    }
}

/// `{name}` replaced by `values[name]`; `{product}` by the product name.
public func format(_ text: String, _ values: [String: String]) -> String {
    var result = text.replacingOccurrences(of: "{product}", with: product)
    for (key, value) in values {
        result = result.replacingOccurrences(of: "{\(key)}", with: value)
    }
    return result
}

/// Python's repr() of a str, as the harness texts print it: single quotes unless the
/// text holds a single quote and no double quote.
public func pythonRepr(_ text: String) -> String {
    let quote: Character = text.contains("'") && !text.contains("\"") ? "\"" : "'"
    var out = String(quote)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if Character(scalar) == quote { out += "\\\(quote)" }
            else if scalar.value < 0x20 || scalar.value == 0x7f { out += String(format: "\\x%02x", scalar.value) }
            else { out.unicodeScalars.append(scalar) }
        }
    }
    out.append(quote)
    return out
}

/// Python's repr() of a float: shortest round-trip form, always with a decimal point.
public func pythonFloat(_ value: Double) -> String {
    if value.isNaN { return "nan" }
    if value.isInfinite { return value > 0 ? "inf" : "-inf" }
    if value == value.rounded(), abs(value) < 1e16 {
        return String(format: "%.1f", value)
    }
    return "\(value)"
}

private let retry = "Read the app state again, then retry with the new element IDs."

/// The makers of every error text (errors.TEXTS). A nil code is a server error
/// (code 100 and the bare text).
public enum Errors {
    struct Spec {
        let code: Int?
        let name: String
        let text: String
    }

    static let specs: [String: Spec] = [
        // the person
        "user_changed": Spec(code: 110, name: "user_took_over", text: "The user did something in '{app_path}' since your last read. Call `get_app_state` again before you act on it."),
        "still_interacting": Spec(code: 110, name: "user_took_over", text: "The user is working in '{app_path}' right now. Wait 5 seconds, then try again."),
        "turn_ended": Spec(code: 111, name: "turn_ended", text: "The turn is over, so {product} takes no more calls. It takes calls again after the user's next message."),
        "stopped_by_user": Spec(code: 111, name: "stopped_by_user", text: "The user stopped {product} on the Mac (Esc or Stop in the term-llm menu). Do not use it again in this turn; tell the user what you had done so far."),
        "not_active": Spec(code: 112, name: "no_session", text: "No session is open for '{app}'. Call `get_app_state` for it first: every other {product} action needs that read."),
        "paused": Spec(code: 113, name: "paused", text: "The user paused {product} from the term-llm menu, so it takes no calls now. Stop here and tell the user; only they can resume it."),
        // policy, approval, permissions
        "forbidden": Spec(code: 120, name: "app_refused", text: "For safety, {product} may not use the app '{bundle_id}'. Tell the user, and do not try to use it another way."),
        "denied_by_policy": Spec(code: 120, name: "app_refused", text: "Your policy file says {product} may not use the app '{bundle_id}'. Tell the user; only they can change that file."),
        "disabled": Spec(code: 120, name: "app_refused", text: "{product} is switched off in its policy file. Tell the user; only they can switch it on."),
        "caller_refused": Spec(code: 120, name: "caller_refused", text: "{product} serves term-llm agents only, and this command was not started by term-llm."),
        "security_process": Spec(code: nil, name: "", text: "'{bundle_id}' is a system password or security window, which {product} never touches. Ask the user to answer it."),
        "not_approved": Spec(code: 120, name: "not_approved", text: "The user did not allow {product} to use {display_name}. Do not use it in this turn; ask the user if you need it."),
        "approval_pending": Spec(code: 121, name: "approval_waiting", text: "Waiting for the user to allow {display_name} in the {product} panel on the Mac. Call this tool again now, and do not end your turn."),
        "permissions_pending": Spec(code: 121, name: "permissions_waiting", text: "The user is still allowing {app} under {grants} in System Settings. Call this tool again now, and do not end your turn."),
        "permissions_not_granted": Spec(code: 122, name: "permissions_missing", text: "{product} cannot work without {grants}. Ask the user to allow {app} under {grants} in System Settings; the Computer Use item of the term-llm menu shows what is missing."),
        "blocked_url": Spec(code: 123, name: "page_off_limits", text: "{product} may not be used on the page that is open in the browser, so this session is over. Stop here and say why in your final message. For {product} the page stays off limits even when the user opens it themselves."),
        "approval_unavailable": Spec(code: 121, name: "approval_unavailable", text: "{product} cannot ask the user about \"{display_name}\" because its on-screen panel is switched off. Ask the user to approve \"{display_name}\" in the Computer Use window of term-llm, then call this tool again."),
        "approval_not_saved": Spec(code: 100, name: "approval_not_saved", text: "{product} could not save the approval of '{bundle_id}' to disk, so it lasts only until the helper stops. Go on; the user can approve it again later."),
        "policy_unreadable": Spec(code: 120, name: "app_refused", text: "{product} cannot read its policy file '{path}': {reason}. Ask the user to fix or remove the file, then call this tool again."),
        // apps and windows
        "invalid_app": Spec(code: 130, name: "no_such_app", text: "No app called {identifier} was found on this Mac. Call `list_apps` and use a name or bundle id from it."),
        "no_file_panel": Spec(code: 130, name: "no_such_app", text: "No app you have read shows an open or save panel now. Call `get_app_state` for the app that opened it, then act on the panel there."),
        "agent_left": Spec(code: 111, name: "turn_ended", text: "Stopped: the agent's turn ended (or its app exited) during this action. Do not act again until the user asks."),
        "agent_exited": Spec(code: 111, name: "agent_exited", text: "The agent that started this command has exited, so {product} ignores it."),
        "app_not_running": Spec(code: 131, name: "app_not_running", text: "{identifier} is not running any more: it quit or crashed. Call `get_app_state` to open it again."),
        "accessibility": Spec(code: 132, name: "accessibility_failed", text: "An accessibility request to the app failed ({ax_error_name}). Call `get_app_state` again; if it fails again, click by pixel or tell the user."),
        "not_responding": Spec(code: 132, name: "app_not_responding", text: "{app_name} is not responding: it did not answer in time. It may be busy or frozen. Wait a few seconds and call get_app_state again. If it still fails, tell the user the app is frozen and stop using it."),
        "timeout_reached": Spec(code: nil, name: "", text: "The app started but showed no window within 5 seconds. Call `get_app_state` once more; if it fails again, tell the user."),
        "front_not_back": Spec(code: nil, name: "", text: "{product} could not put the user's front app back in front. Tell the user."),
        "no_windows": Spec(code: nil, name: "", text: "The app has no open window. Open one with its menu or a shortcut, or tell the user."),
        "invalid_process": Spec(code: nil, name: "", text: "No usable process id for {identifier}"),
        "no_capturable_window": Spec(code: nil, name: "", text: "No window of {identifier} can be captured"),
        "app_quit": Spec(code: nil, name: "", text: "The app quit during the call. Call `get_app_state` to open it again."),
        "failed_to_launch": Spec(code: nil, name: "", text: "macOS could not start the app. Tell the user."),
        "no_window_id": Spec(code: nil, name: "", text: "No window could be found for this element"),
        "element_outside_app": Spec(code: nil, name: "", text: "This element is drawn by another process and has no parent in the app"),
        // elements
        "stale_element": Spec(code: nil, name: "", text: "That element ID is from an older read. " + retry),
        "invalid_element_id": Spec(code: nil, name: "", text: "No element has the ID {index} in the last read. Use an ID from the newest `get_app_state` text."),
        // actions
        "key_not_found": Spec(code: nil, name: "", text: "No key is called \"{name}\""),
        "key_chord": Spec(code: nil, name: "", text: "{case}"),
        "no_text_to_type": Spec(code: nil, name: "", text: "No text was given to type"),
        "no_text_to_paste": Spec(code: nil, name: "", text: "No text was given to paste"),
        "no_value_to_set": Spec(code: nil, name: "", text: "No value was given to set"),
        "not_settable": Spec(code: nil, name: "", text: "The value of this element cannot be set"),
        "text_not_found": Spec(code: nil, name: "", text: "The element does not contain that text"),
        "cannot_select_text": Spec(code: nil, name: "", text: "This element does not let its text selection be set"),
        "invalid_secondary_action": Spec(code: nil, name: "", text: "{action} is not among the secondary actions of element {index}"),
        "cannot_click_offscreen": Spec(code: nil, name: "", text: "This element is off screen and cannot be clicked"),
        "invalid_click_count": Spec(code: nil, name: "", text: "Invalid click count"),
        "mouse_key_requires_single_key": Spec(code: nil, name: "", text: "A click takes one chord of keys, not a sequence"),
        "menu_click_failed": Spec(code: nil, name: "", text: "The menu item could not be clicked"),
        "menu_fills_on_open": Spec(code: nil, name: "", text: "The {title} menu is filled only when it opens on screen, which would take the user's mouse and keyboard. Use its keyboard shortcut (press_key) or a control in the window instead."),
        "menu_action_not_supported": Spec(code: nil, name: "", text: "A menu takes plain clicks only"),
        "path_in_file_name": Spec(code: nil, name: "", text: "The Save As field takes a file name, not a path: nothing was typed. Type the name alone. To choose the folder: press_key super+shift+g, set_value the path field (ID: PathTextField) to the folder, press_key Return, check the Where: pop-up, then click Save."),
        "paste_not_read": Spec(code: nil, name: "", text: "The app did not take the text from the clipboard in time"),
        "paste_write_failed": Spec(code: nil, name: "", text: "The text could not be put on the clipboard"),
        "paste_conflict": Spec(code: nil, name: "", text: "The clipboard changed during the paste, probably by the user. Read the app state and check that your text was pasted, not theirs, before you go on."),
        "no_keyboard_layout": Spec(code: nil, name: "", text: "The current keyboard layout could not be read."),
        "no_scroll_direction": Spec(code: nil, name: "", text: "No scroll direction was given"),
        "no_scroll_amount": Spec(code: nil, name: "", text: "No scroll amount was given"),
        "no_tree": Spec(code: nil, name: "", text: "The accessibility tree is missing."),
        "capture_failed": Spec(code: nil, name: "", text: "Reading the UI tree failed."),
        "screenshot_failed": Spec(code: nil, name: "", text: "Taking the screenshot failed."),
        "screenshot_size": Spec(code: nil, name: "", text: "The screenshot has an unusable size: {size}"),
        "no_invalidation_monitor": Spec(code: nil, name: "", text: "Internal error: this app session has no change monitor."),
        "skill_missing": Spec(code: nil, name: "", text: "the skill file is missing"),
        // the helper itself
        "helper_unavailable": Spec(code: 103, name: "helper_unavailable", text: "{product} is not running. Run the command again. If it fails again, ask the user to check Computer Use in the term-llm menu."),
        "app_unavailable": Spec(code: 103, name: "app_unavailable", text: "Computer use is off. Ask the user to turn it on from the term-llm menu (Computer Use…)."),
        "helper_stopped": Spec(code: 103, name: "helper_stopped", text: "The {product} helper stopped during this call. Call `get_app_state` again before sending more actions."),
        "request_timed_out": Spec(code: 103, name: "request_timed_out", text: "{product} did not answer within 2 minutes, so the action may or may not have run. Call `get_app_state` to see the app before you try again."),
    ]

    /// The person did it (took over, said no): reported as such, not as a failure.
    static let cancelled: Set<String> = [
        "user_changed", "still_interacting", "turn_ended", "agent_left", "agent_exited",
        "not_approved", "blocked_url", "paused", "stopped_by_user",
    ]
    /// These carry the tag invalid_element_id.
    static let elementID: Set<String> = ["stale_element", "invalid_element_id"]

    /// The error `key` of TEXTS, with its `{fields}` filled from `values`.
    public static func make(_ key: String, _ values: [String: String] = [:]) -> HarnessError {
        guard let spec = specs[key] else { return serverError("unknown error \(key)") }
        let message = format(spec.text, values)
        guard let code = spec.code else {
            return serverError(message, tag: elementID.contains(key) ? "invalid_element_id" : nil)
        }
        return HarnessError(code: code, name: spec.name, message: message, cancelled: cancelled.contains(key))
    }

    /// An error with no code of its own: the model sees the code and the bare description.
    public static func serverError(_ description: String, tag: String? = nil) -> HarnessError {
        HarnessError(code: 100, name: "server_error", message: "\(product) error 100: \(description)", tag: tag)
    }

    public static func locked(stateRead: Bool) -> HarnessError {
        let text = stateRead
            ? "The Mac is locked, so its accessibility text cannot be read. It has to be unlocked first."
            : "The Mac is locked. Ask the user to unlock it, then go on."
        return HarnessError(code: 134, name: "mac_locked", message: text)
    }

    public static func ambiguousApp(bundleID: String, paths: [String]) -> HarnessError {
        HarnessError(code: 133, name: "several_apps_match",
                     message: "More than one app has the bundle id '\(bundleID)': \(paths.joined(separator: ", ")). Name the app, or give its full path.")
    }

    public static func windowNotFound(at point: CGPoint) -> HarnessError {
        serverError("No window of the app is at (\(pythonFloat(point.x)), \(pythonFloat(point.y)))")
    }

    public static func ambiguousRefetch(started: Bool) -> HarnessError {
        serverError("The element went away, and more than one element now fits its description, so looking it up again could not be \(started ? "finished" : "started"). " + retry,
                    tag: "invalid_element_id")
    }

    public static func invalidDuration() -> HarnessError { Usage.error("duration") }
    public static func invalidScrollPages() -> HarnessError { Usage.error("pages") }
}
