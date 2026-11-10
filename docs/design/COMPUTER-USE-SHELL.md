# Computer Use shell integration

The shell and final orchestration wave of [COMPUTER-USE.md](COMPUTER-USE.md),
ported from macos-harness `43d9edf`. The bundled helper now runs
`ComputerUseRuntime` → `HarnessExecutor`, not the stub: all eleven tools, app
approvals, the read/action pipeline, permissions status/controls, presence and Esc
cancellation are wired. No Python runtime or third-party agent installation is
shipped. Fake-backed tests and the unsigned no-grants socket smoke pass; live
AX/actions, real permission grants, appearance and signed-release behavior remain
unverified.

## Products and ownership

- `TermLLMComputerUse` → `term-llm Computer Use.app`, bundle ID
  `com.termllm.app.computeruse`, LSUIElement, hardened runtime, no sandbox,
  entitlements file, or provisioning profile requirement.
- `TermLLMComputerCLI` → `term-llm-computer`.
- `TermLLMMac` depends on both, links only `ComputerUseCore`, and embeds both
  products with CodeSignOnCopy under `Contents/Helpers`.
- The main app launches the helper with `NSWorkspace.openApplication`, **not**
  `Process`. Launch configuration disables activation, recent items, and new
  application instances. It supplies its pid for the helper's host-death monitor.
- The CLI only connects. With no listener it checks `<state>/enabled`, opens the
  **main** app via `/usr/bin/open -g -j -b com.termllm.app`, and waits up to **8 s**.
  Without that file it reports `app_unavailable` and does not launch anything.

All state is in `Paths.stateDirectory()`, default
`~/.config/term-llm/app/computer-use`. `TERM_LLM_COMPUTER_HOME` and
`TERM_LLM_COMPUTER_SOCKET` allow isolated tests. The app passes the same paths to
its LaunchServices-launched helper. `enabled` is off by default. `paused`
persists across helper restarts. Neither flag uses UserDefaults.

The command installer records its owned symlink targets in
`<state>/command-link.json`. It repairs an app move only if the existing symlink
points to the current binary or a previously recorded target. Ordinary files and
foreign links (including dangling links) are left alone. An absent command is
installed only on the person's explicit Install/Repair action. The skill goes
only to `~/.config/term-llm/skills/computer-use/SKILL.md`. Installing it also
removes the `term-llm-computer/` skill earlier builds wrote: only a real
`SKILL.md` with that name in a real folder, plus its module, never links or
other files.

## Public package APIs

### Parser and skill (`ComputerUseCore`)

- `ToolParser.tools`, `.commands`, `.parameters`, `.spellings`, `.table` expose
  the data-only tool contract. `ToolDefinition` has name, params, bare, defaults,
  description, example, hidden, refused, and stdin fields.
- `ToolParser.parse(_ argv: [String]) throws -> ParsedToolCall`: argv **without**
  the executable; returns `.name`, `.arguments`, and `.tool`. Numeric/action
  validation belongs to the executor. Usage failures are `HarnessError` with
  `isUsage == true`.
- `ToolParser.help(_ asked: String? = nil)` and `ComputerUseSkill.text`.
- `ComputerUseVersion.current` is shared by client and server. Wire API remains
  `Limits.apiVersion == "TermLLMComputerUse-1"`.

### Client (`ComputerUseClient`)

`ComputerUseClient.main(_ argv: [String]) -> Int32` takes argv **including** the
executable, like `CommandLine.arguments`. The entry point calls `exit(...)`.
It prints `--version` locally, otherwise sends argv/cwd/filtered environment,
reads piped/file stdin only after `needStdin`, and uses the 120-second deadline.
A parent-pid change exits 130, including during partial frame reads/stdin waits.
Only explicit versionMismatch/stopping refusals permit one retry; a broken socket
never replays a possibly executed action. Both peers check kernel peer uid.

### Execution (`ComputerUseHelper`)

```swift
public protocol ToolExecutor {
    func execute(_ call: ToolCallRequest) throws -> ToolOutcome
    func shutdown() // default no-op
    func agentExited(_ agent: AgentSession,
                     withAppQueue: (String, () throws -> ToolOutcome) throws -> ToolOutcome)
    // default no-op; HarnessExecutor uses the same letGo path as turn-ended
}
```

Execution is on socket-worker threads. `shutdown()` runs after workers drain,
before the AppKit loop stops: release focus, tree/watchers, clipboard, presence,
and capture state there. Never require the main thread while holding a lock
that another main-thread callback needs.

`ToolCallRequest` contains:

- `name`, normalized/defaulted `arguments`, `stdin`, filtered `environment`, `cwd`;
- `agent: AgentSession`, `sessions: Sessions`, `deadline: Date`;
- `abandoned: () -> Bool` (socket closed, Stop, Pause, shutdown, host gone,
  cancellation generation changed, or deadline passed);
- `withAppQueue(path, work)`: shared FIFO across agents. Resolve the app first,
  then pass its **canonical bundle path**, not the user's alias. Other apps have
  independent queues. Queue waiters are cancellable.
- `withCleanupQueue(path, work)`: the **same FIFO**, without the ended turn's
  cancellation predicate, so cancellation cannot prevent resource release.

`ToolOutcome(exit: Int32, stdout: String, stderr: String)` also has `.text` and
`.failure` factories for text/JSON results. Throw `HarnessError` for a normal tool
failure. Throw `NeedStdin()` only **before effects** if text is needed: the client
will reconnect with stdin. The server already performs this preflight for the
table's stdin-taking tools, strips exactly one terminal newline, and fills the
argument. It converts execution failures to exit 1 (usage errors to exit 2).

`HarnessExecutor` implements help, skill, doctor, turn hooks and the eleven tools.
Its injectable `Dependencies` supplies the existing Apps/Windows/Person/Focus,
Presence, Permissions, Screenshot, Approvals, Policy, Instructions and Actions
instances, with effect-only closures for gates, reading, settling, screenshots,
refetching and action dispatch. `Actions.System` similarly injects event posting,
clocks, layout, focus, clipboard, presence and app/window primitives. Tests execute
the real ordering/validation/state machine with fake effects.

`HarnessExecutor.appSessions(_:)` returns sessions in first-use order (important
for file-panel ownership), keyed by agent key and canonical app path. Mutations of
an AppSession's revisions/active/settle/screenshot state occur under that app's
FIFO. AgentSession state, including collection mutations, is synchronized across
app workers, turn hooks and approval callbacks. AppSession target/watch snapshots
are also synchronized for panel resolution and reaping.

`StubToolExecutor` is retained only as a shell/protocol fixture. The helper app
never selects it. There is **no agent-callable `approve` command**, parser entry or
executor path. The person approves in the panel or the main app's window, which
uses `ApprovalStore` directly.

### Sessions and server

- `ProcessIdentity.lookup` uses libproc (`proc_pidinfo` / `proc_pidpath`). Birth
  time is checked to prevent pid reuse inheriting an identity.
- `Sessions(process:)` accepts an injectable ancestry provider. `agent(peerPID:env:)`
  keys by nonempty `TERM_LLM_SESSION_ID`, then `TERM_LLM_COMPUTER_SESSION`, then
  the first non-shell/wrapper parent pid + birth time. It records all `.app`
  bundle paths on the chain, and detects an orphaned wrapper left by a dead host.
- Use `.turnStarted`, `.letGo(cancel:)`, `.isStopped`, `.hasEnded`,
  `.cancellationGeneration`, `.hostGone`, and `.reap` for lifecycle marks.
  `HarnessExecutor` owns app element/diff state. `HelperServer.reapSessions()` calls
  executor `agentExited` for every reaped process session, under the same app FIFOs;
  reaping is drained with socket workers before shutdown.
- Tool callers must have an ancestor whose executable basename is exactly
  `term-llm`. This is advisory product scoping, not a security boundary. The sole
  development override is the hidden `<state>/allow-any-caller` file. Environment
  variables cannot bypass this gate. Same-uid controls remain available to the
  main app/person without term-llm ancestry.
- `HelperConfiguration(environment:grants:allow:)` supplies permission hooks.
  `grants` returns `[String: Bool]` (default empty); `allow` takes a grant name
  (default explicit not-implemented failure). These hooks run off-main; marshal
  permission UI via `MainThread` as necessary. Production names are Accessibility,
  Screen Recording, Input Monitoring and Event Posting. Agent permission gates are
  passive (`requestUI: false`): missing grants return the shared missing-permissions
  text, never open Settings or request a grant. Only the human `allow` control calls
  the helper's permission request/open-pane methods.
- `HelperServer(executor:configuration:sessions:)` exposes start/stop,
  requestShutdown, status, and answer (the latter for deterministic protocol
  tests). `start` acquires flock before binding a 0600 socket in a 0700 folder.
  Stop drains/cancels workers, calls executor cleanup, removes the socket, then
  unlocks. Signals and shutdown have a 130-second stuck-exit cap.
- `HelperMain.run(executor:) -> Never` runs through `MainThread.run`. An overload
  accepts configuration. App-owned helpers exit if their owner pid/birth changes;
  standalone development helpers idle out after 15 minutes. Reaping runs every
  two seconds. Logs contain only known command names/timing and lifecycle, never
  argv, environment, app names, UI contents, or typed text.
- `Sessions.letGo(cancel:)` preserves upstream turn semantics: plain turn-ended
  releases app sessions but permits a new read; `--cancel` also increments the
  cancellation generation and marks a signalled turn ended until turn-started.
  Denials are cleared at turn boundaries. Lifecycle cleanup uses `withCleanupQueue`.

## Controls and status

All controls use `Wire.control`; replies have the normal JSON-RPC result wrapper.

| Method | Parameters | Result |
|---|---|---|
| `ping` | none | `pid`, `version`, `apiVersion`, `paused`, `running` |
| `status` | none | shape below |
| `pause` / `resume` | none | status; persist/remove `paused`; Pause cancels in-flight actions |
| `stop` | none | status; cancel current agents and agents in the Working grace period; refuse their calls until turn-started |
| `allow` | `{"grant":"Accessibility"}` | status after permission hook; transport error on failure |
| `shutdown` | none | ping identity, then asynchronous clean shutdown |

```json
{
  "running": 0,
  "working": false,
  "paused": false,
  "grants": {"Accessibility": true, "Screen Recording": false}
}
```

`working` is true while a call runs or began/ended in the last three seconds.
Status polling never invokes `allow` or requests permissions. The main app polls
on background work (~2 seconds, ~400 ms while the status menu is open). The
menu's normal terminal icon is unchanged when disabled. Fixtures and hosted
tests suppress helper launch, polling, and installation side effects.

## Verification notes

Run `swift build && swift test` inside ComputerUseKit, and build TermLLMMac with
`CODE_SIGNING_ALLOWED=NO`. `TermLLMMacTests/ComputerUseTests` covers the file flag,
symlink ownership/move repair, skill install, and fixture suppression, without
starting a helper. On hosts where Xcode's LaunchServices test launcher fails,
the compiled file-only suite can also run with Xcode's `xctest` executable and
`DYLD_LIBRARY_PATH=<app>/Contents/MacOS`,
`DYLD_FRAMEWORK_PATH=<app>/Contents/Frameworks`, and `XCTestBundlePath=<test>`.
Call the Xcode test executable directly (not through SIP-protected xcrun, which
strips DYLD variables). This is not proof of a GUI/LaunchServices/TCC flow.

Unsigned build and local socket fixtures do not prove release signing,
notarization, grants, real UI actions, or Esc cancellation. Those checks belong
to integration/device and Developer ID release verification.

## Final integration behavior and verification

Request order is tool-specific argument validation, app argument, ended turn,
Apps.resolve, file-panel owner, Policy.decide, Approvals.ensure, Permissions.gate,
LockScreen.gate, Person.gate, canonical-app FIFO, Person.gate again, deadline/client
check, AppSession lookup, cancellation predicate, then read/action. An AX
cannotComplete is reported as the named app not responding, never retried as a
second action. Reads switch on Tree/Windows/Revisions once per process, reuse
Settle's capture, check browser URLs before screenshots, number/diff the tree and
record a shot for pixel coordinates. `TERM_LLM_COMPUTER_DIFF=0` disables diffs.
Keys settle pending UI first; only set_value refetches ignoring a changed value.
Browser chains check potentially changed URLs before the next action.

get_app_state --json returns `{app, screenshot: {url} | null, text}`; --keep copies
the screenshot into permanent proof and prints/returns its path/URI. Screenshot
failure retains the tree and numbered actions, but pixel actions require a shot.
Actions return the fixed “Done. Call `get_app_state`…” sentence, or JSON null.
Limits are ten clicks, 20,000 Unicode scalars for typing, 30 seconds total holds
(and the slow-app typing cap), with a one-second deadline margin checked again
after settling/refetching.

Startup installs SystemAX, restores the clipboard before serving, starts the
Person watch on the AppKit loop, prewarms Apps and schedules screenshot expiry on
the maintenance timer. The working callback aggregates running calls; ActivityBanner
supplies the same three-second grace as status. Esc and the stop control call
`stopCurrentTurn()`. Shutdown drains calls/reaping and releases Focus, AX tree
switches/watchers, saved clipboard, presence, banner and expired screenshots.

Verified on cu-integ: `swift build && swift test` (**454 tests**: 161 Core, 246
System, 47 Helper; zero failures/skips), and the unsigned TermLLMMac xcodebuild.
New logic coverage is 32 Actions tests, 34 executor tests and one concurrent-server
working/Stop regression, plus removal-of-approve parser assertions. Parameterized
Python cases are grouped into Swift methods/loops; Python import introspection,
disabled switches, installer/telemetry commands and live-app tests are not claimed.

Unsigned helper socket smoke used a disposable TERM_LLM_COMPUTER_HOME with
allow-any-caller and a disposable Finder ApprovalStore entry (to bypass the human
approval panel, **not TCC**). list_apps exited 0 with a JSON array including Finder.
get_app_state --app Finder exited 1, before any state tree capture or app input, with:

> term-llm Computer Use cannot work without Accessibility and Screen Recording.
> Ask the user to allow term-llm Computer Use under Accessibility and Screen
> Recording in System Settings; the Computer Use item of the term-llm menu shows
> what is missing.

The helper stopped cleanly on SIGTERM with empty stderr. No grant was requested,
no app input was posted, and no live AX/TCC/UI success is claimed. The two
main-app ComputerUse files and Core ApprovalStore were not edited by integration.
