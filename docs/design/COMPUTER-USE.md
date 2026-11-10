# Computer use in term-llm.app

Status: **in progress.** The app-shell wave is implemented; see
[Computer Use shell integration](COMPUTER-USE-SHELL.md) for its public APIs,
controls, tests, and deliberately stubbed execution/permission seams. A Swift port of `browser-use/macos-harness` at
`43d9edf` (v0.2.1, MIT; its licence notice ships with the ported code in
`ComputerUseKit/LICENSE-macos-harness`). This replaces the "Computer use /
macOS Harness integration: Deferred" row in
[MACOS-COMPANION.md](../MACOS-COMPANION.md).

## Goal

Computer use is a **term-llm feature**. When it is turned on in the Mac app:

- a helper app bundled inside term-llm.app (**term-llm Computer Use**) holds
  Accessibility and Screen Recording, plus the optional Input Monitoring and
  event-posting grants. They are granted once, to it, and never to a terminal
  or to the main app;
- the term-llm menu-bar item gains a Computer Use section (state, Stop, Pause,
  Allow…, settings);
- term-llm agents reach it through a per-user Unix socket with the bundled
  command `term-llm-computer` (`term-llm-computer get_app_state --app
  Finder`), taught by a `term-llm-computer` skill that the app installs into
  term-llm's own skill folder.

Nothing is installed for Claude Code, Codex, Pi or OpenCode: no skills, hooks or
plugins. When the feature is off, nothing listens, no helper runs and the menu
shows nothing extra.

## Sources studied

### macOS Harness (the code being ported)

~11.5k lines of Python/PyObjC, 1,056 pytest tests, 38 modules.

| Piece | How it works |
|---|---|
| Client (`cli.py`, `protocol.py`) | Stdlib only. Sends **argv + cwd + filtered env** to the helper and prints the `{exit, stdout, stderr}` it gets back. Parses nothing. Exits (closing the socket) if its parent dies, which cancels the action. |
| Wire | Unix socket, 0600 in a 0700 folder, peer-uid check. Frame = 4-byte LE length + UTF-8 JSON-RPC (8 MiB cap). Methods `request` (argv, stdin, cwd, env, deadlineMs), `ping`, `shutdown`, `show`. `needStdin` round trip. 120 s deadline. |
| Helper (`helper.py`) | One per user. Main thread = AppKit loop (overlay, panel); socket and calls on worker threads; FIFO lock per app; display-awake assertion while working; single-instance flock. |
| Agent identity | `LOCAL_PEERPID` → parent chain past shells and wrappers → the first other process is "the agent". Sessions (element numbers, last state for diffs) are keyed per agent and per app. `MACOS_HARNESS_SESSION` overrides. Turn hooks: `turn-started`, `turn-ended [--cancel]`. |
| Tools | 11 model tools: `list_apps`, `get_app_state`, `click`, `drag`, `press_key`, `type_text`, `set_value`, `scroll`, `select_text`, `perform_secondary_action`, `paste`; plus `doctor`, `skill`, `approve`, `turn-*`. |
| Read path | `ax` (incl. private `AXUIElementCopyHierarchy`, `_AXUIElementGetWindow`) → `tree` → `prune` (12 passes) → `elements` (stable numbers) → `render` / `diff` → `richtext`, `instructions`, `settle`, `lockscreen`. |
| Act path | AX action first → events posted **to the app's pid** (private `CGEventSetWindowLocation`) → keys after a faked activation (private CGS calls). The real pointer never moves and the front app stays in front. Layout-aware `keys`; `pasteboard` with a promised item and clipboard restore. |
| Screenshots | **`/usr/sbin/screencapture` in a child process**, on purpose: in-process window capture on macOS 27 can wedge the capture service for every process. |
| Person first | A listen-only event tap: the user's input on a driven app makes the next call wait 5 s and fail with "read again". |
| Presence | Drawn pointer, flash and window halo; approval panel; `policy.toml`. |
| Tests | Fakes for every system seam; portable golden fixtures: `fixtures/trees/*.json → *.txt`, `fixtures/diffs/*.txt`, key tables, pointer motion. |

### Codex Computer Use (OpenAI's shipped equivalent)

Studied: the `computer-use` plugin skill and `~/.codex/computer-use/Codex
Computer Use.app` (bundle layout, plists, entitlements, symbol strings).

- **The service is its own app.** `com.openai.sky.CUAService` is an
  `LSUIElement` app with its own bundle id and TCC identity, Developer ID
  signed, hardened runtime, **no special entitlements for AX or screen
  capture**. The client is a separate signed bundle in
  `Contents/SharedSupport/`. Codex.app itself holds no computer-use grants.
- **Caller identity from the audit token:** it records the sender's
  *responsible* bundle id, signing id and team id, not just a pid.
- **Default deny list:** password managers (1Password, Bitwarden, Dashlane,
  LastPass, NordPass, Apple Passwords, Keychain Access), `SecurityAgent`,
  LocalAuthentication UI, the Privacy & Security settings extension,
  terminals (Terminal, iTerm2, Ghostty, WezTerm, Rio) and its own apps.
- **Approval per app, per session, on by default:** `sessions/<id>.toml` holds
  `[apps] allowed = [...]`, with "Always allow" as a persistent option.
- **A visible "using your computer · Esc to cancel" banner,** with strings
  provided by the host (`config.json`). Esc on the Mac stops the agent.
- **Confirmation policy in the skill:** a risk taxonomy (hand off to the user,
  always confirm, pre-approval works, no confirmation) and prompt-injection
  hygiene: third-party content is never permission.
- Same 11-tool surface and settle behaviour as the harness (the harness copied it).
- Not adopted: a JS REPL/MCP transport (we use a shell command), an XPC
  endpoint bootstrapped through an Apple event (a Unix socket suits scripts),
  and a lock-screen "guardian" that can unlock the Mac (we never unlock).

## Decisions

1. **Native Swift port; no Python in the app.**
2. **The helper is a separate LSUIElement app bundle** (`term-llm Computer
   Use.app`, `com.termllm.app.computeruse`) at
   `term-llm.app/Contents/Helpers/`. The main app launches it through
   LaunchServices, so it is its own TCC principal, as with Codex. The main
   app, which renders remote web content, never gets AX or Screen Recording.
   The helper isolates crashes and hangs, and the main app can kill and restart it.
3. **Command `term-llm-computer`**, a command-line tool at
   `term-llm.app/Contents/Helpers/term-llm-computer`, linked from
   `~/.local/bin/term-llm-computer` by the app.
4. **term-llm only.** The skill goes into
   `~/.config/term-llm/skills/term-llm-computer/SKILL.md`. The helper serves
   calls whose process ancestry contains a `term-llm` executable and refuses
   other callers by default. Ancestry is advisory, not a security boundary,
   but it keeps the feature scoped.
5. **Approvals:** ask before each app's first use in a session (Codex-style
   panel, Allow once for the session or Always allow). Pre-approved apps are
   managed in the Computer Use window. Built-in deny list as in Codex, plus
   term-llm.app and the Computer Use helper itself.
6. **Stop on the Mac:** while an agent acts, a small "term-llm is using your
   computer · Esc to stop" banner shows. Esc, or **Stop** in the menu, cancels
   the running action and refuses calls for the rest of that turn. This
   matters because term-llm chats are often driven from the phone or web, away
   from the Mac.
7. **Skill includes a confirmation policy** adapted from Codex's.
8. **No telemetry.**

## Architecture

```text
term-llm agent shell ── term-llm-computer <tool> ... ──┐
                                                        │ ~/.config/term-llm/app/computer-use/helper.sock
term-llm.app (main) ── launches (LaunchServices) ──▶ term-llm Computer Use.app (LSUIElement)
   menu section, Computer Use window ◀── status ──── helper: AX, events, screencapture child,
                                                        overlay, banner, approval panel
```

### Code layout

| Path | Contents |
|---|---|
| `ComputerUseKit/` (SwiftPM) | `ComputerUseCore`: pure Foundation. Wire, model, errors, argv parser and tool tables, prune, render, elements, diff, richtext, key tables, pointer maths, policy parsing, skill text. `ComputerUseSystem`: AppKit/AX/Quartz implementations behind seams. `ComputerUseHelper`: sessions, tool orchestration, socket server. `ComputerUseClient`: the client. Tests: core plus golden fixtures, and helper orchestration with fakes. |
| `TermLLMComputerUse/` | Helper app target: thin `main.swift`, Info.plist (`LSUIElement`), entitlements (hardened runtime only). |
| `TermLLMComputerCLI/` | `term-llm-computer` tool target: thin `main.swift`. |
| `TermLLMMac/ComputerUse*.swift` | `ComputerUseController`: setting, launch and stop, status, menu section, Computer Use window, PATH link, skill install. |

### Socket, protocol, client

- Path `~/.config/term-llm/app/computer-use/helper.sock`: folder 0700, socket 0600,
  peer uid checked on both sides.
- Harness framing and envelope unchanged, apart from the API string
  `TermLLMComputerUse-1`. Control methods: `ping`, `shutdown`, `status`.
- The client never starts a helper. If nothing listens and Computer Use is
  enabled, it opens term-llm in the background and waits up to 8 s. Otherwise
  it prints *"Computer use is off. Turn it on from the term-llm menu."*

### Sessions, turns and cancellation

- Session key: `TERM_LLM_SESSION_ID` when present (core's shell tool exports
  the session's ID and it wins over inherited values and model `env`
  overrides), else `TERM_LLM_COMPUTER_SESSION`, else the harness
  process-ancestry key.
- Core runs `term-llm-computer turn-started` / `turn-ended [--cancel]` around
  every tool-using, non-ephemeral session run (`internal/computeruse`), one
  at a time and in order, only on macOS while `<state>/enabled` and the socket
  exist. An interrupted run sends `--cancel`. Turn commands never open the app:
  with no helper listening they exit 0.
- `spawn_script` cells call the same command through `tools.shell`, so they
  carry the same session. A cell can outlive its turn; the skill tells agents
  to finish or cancel cells that drive apps before ending the turn.
- The skill ships `js/index.mjs` (`ComputerUseSkill.module`), admitted as
  `skill:term-llm-computer`: `computer.<tool>({app, ...flags})` runs the
  command through `tools.shell` with a 130 s timeout, returns the printed
  text, and throws the helper's message on failure (`outcome: "unknown"` when
  the command did not finish). It declares only `shell` as a dependency and
  holds no authority of its own. Agents without `spawn_script` still activate
  the skill and get its shell instructions (term-llm skips an unavailable
  module instead of refusing the skill). The installer writes the module
  before `SKILL.md`. `SkillModuleTests` runs the source in JavaScriptCore
  with a fake shell; it was also checked once in term-llm's QuickJS.
- Cancellation sources: client gone, Esc / Stop on the Mac, Pause, user input
  on the driven app. Each keeps its own error text.

### Menu and settings

- **Computer Use…** is always in the term-llm menu. When enabled, the menu
  adds the status line, Stop (while working), Pause/Resume and
  `Allow <grant>…` for missing grants.
- The Computer Use window has the enable switch, the grants with Allow…
  buttons, the command and skill status, the approved apps, and Advanced
  (socket path, log, Copy Diagnostics).

### Security

- Least privilege: only the helper holds the grants.
- Never drive: deny list, term-llm.app, the helper (banner and approval
  panel), password sheets, Privacy & Security.
- Files: `~/.config/term-llm/app/computer-use/` (policy, approvals, paused,
  log), screenshots in `~/Library/Caches/term-llm/computer-use/` (0700,
  one-hour expiry).
- Logs hold no screenshots, typed text or UI content.

## Build waves

1. **Base:** package skeleton, model, wire, errors, run loop.
2. **In parallel:** pure core (prune, render, elements, diff, richtext, parser,
   key tables, pointer maths, policy parsing, golden fixture tests); act
   primitives (events, key impl, actions, pasteboard); app shell (Xcode
   targets, client, server with a stub dispatcher, main-app controller, menu,
   window, PATH link, skill).
3. **In parallel:** read path (ax, windows, apps, tree, settle, screenshot,
   lockscreen, instructions, permissions, focus, person); presence (overlay,
   banner, approval panel, approvals store, policy runtime).
4. **Integration:** helper orchestration (tools execution, sessions),
   end-to-end on real apps, docs, release checks.

## Verification

- `swift test` in `ComputerUseKit`: golden fixtures byte-identical to the harness.
- Helper orchestration tests with fakes (sessions, FIFO, deadlines, cancel,
  pause, needStdin).
- Real UI: `term-llm-computer` against TextEdit, Finder, Safari and System
  Settings from a term-llm shell, with screenshots as proof.
- Notarized-release CI must sign and verify the two nested bundles. That needs
  the runner and can't be proven locally.

## Risks

- Private APIs (CGS/SkyLight, private AX) can break in any macOS release. A
  missing call switches its step off, as upstream does.
- The act path encodes measured per-app quirks; port the comments with the code.
- Recent macOS periodically re-asks about screen recording. Show it in the
  menu state.
- Upstream drift: the source commit is pinned above.
