import Foundation

extension ComputerUseSkill {
    /// js/index.mjs next to SKILL.md: `skill:computer-use` for term-llm's
    /// spawn_script cells. Each function runs term-llm-computer through the
    /// cell's `shell` tool; it holds no authority of its own.
    public static let modulePath = "js/index.mjs"
    public static let module = #"""
        // skill:computer-use: term-llm-computer from a spawn_script cell.
        // Every call is one `shell` tool call, with that tool's approvals, session and
        // cancellation. Results are the text the command prints; only list_apps is parsed.

        export const options = { working_dir: undefined, timeout_seconds: 130 };

        const quote = (word) => "'" + String(word).replaceAll("'", "'\\''") + "'";

        function words(tool, args = {}) {
          const out = [tool];
          for (const [name, value] of Object.entries(args)) {
            if (value === undefined || value === null || value === false) continue;
            out.push("--" + name);
            if (value !== true) out.push(String(value));
          }
          return out;
        }

        function section(output, name) {
          const found = output.match(new RegExp("(?:^|\\n)" + name + ":\\n([\\s\\S]*?)(?=\\n\\nstderr:\\n|\\nexit_code: -?\\d+|\\n\\n\\[Output truncated|$)"));
          return found ? found[1].replace(/\n$/, "") : "";
        }

        // Runs `term-llm-computer <words...>` and returns what it printed. A failure
        // throws the helper's own message: do what it says, and read the app before
        // any retry, since a timed-out or cancelled action may have run.
        export async function run(...argv) {
          const shell = tools.shell;
          if (!shell) throw new Error("term-llm-computer needs the shell tool, which this agent does not have");
          const request = { command: "term-llm-computer " + argv.map(quote).join(" "), timeout_seconds: options.timeout_seconds };
          if (options.working_dir) request.working_dir = options.working_dir;
          const result = await shell(request);
          const output = String(result.text ?? "");
          const code = output.match(/\nexit_code: (-?\d+)/);
          if (!code) {
            const error = new Error("term-llm-computer did not finish (" + (output.split("\n").find(Boolean) || "no output") + "). The action may or may not have run: read the app before trying again.");
            error.outcome = "unknown";
            throw error;
          }
          if (code[1] !== "0") {
            const error = new Error(section(output, "stderr") || section(output, "stdout") || output);
            error.exitCode = Number(code[1]);
            throw error;
          }
          const stdout = section(output, "stdout");
          if (output.includes("[Output truncated due to size limit]")) return stdout + "\n[term-llm: output cut at the shell limit]";
          return stdout;
        }

        // One line per element; null when no line matches.
        export function find(state, pattern) {
          const text = typeof state === "string" ? state : state.text;
          const test = typeof pattern === "string" ? (line) => line.includes(pattern) : (line) => pattern.test(line);
          for (const line of text.split("\n").reverse()) {
            const index = line.match(/^[~+]?\t*(\d+) /);
            if (index && test(line)) return Number(index[1]);
          }
          return null;
        }

        // What changed in a diff read: the ~ and + lines, or the whole text of a full read.
        export function changes(state) {
          const text = typeof state === "string" ? state : state.text;
          const lines = text.split("\n").filter((line) => /^[~+]/.test(line));
          return lines.length ? lines.join("\n") : text;
        }

        function appState(printed) {
          const shot = printed.match(/^Screenshot \((\d+)x(\d+) px\): (.+)$/m);
          const text = printed.replace(/\n*^Screenshot[ :(].*$/m, "");
          return shot
            ? { text, screenshot: shot[3], width: Number(shot[1]), height: Number(shot[2]) }
            : { text, screenshot: null };
        }

        // An image block of the state's screenshot for image(...), or null.
        export async function screenshot(state) {
          if (!state.screenshot) return null;
          if (!tools.view_image) throw new Error("Showing a screenshot needs the view_image tool, which this agent does not have");
          const viewed = await tools.view_image({ file_path: state.screenshot });
          return (viewed.content || []).find((block) => block.type === "image") || null;
        }

        const action = (tool) => async (args) => { await run(...words(tool, args)); };

        export const computer = {
          run, find, changes, screenshot, options,
          list_apps: async () => JSON.parse(await run("list_apps")),
          get_app_state: async (args) => appState(await run(...words("get_app_state", args))),
          click: action("click"),
          drag: action("drag"),
          press_key: action("press_key"),
          type_text: action("type_text"),
          set_value: action("set_value"),
          scroll: action("scroll"),
          select_text: action("select_text"),
          perform_secondary_action: action("perform_secondary_action"),
          paste: action("paste"),
        };
        """#
}
