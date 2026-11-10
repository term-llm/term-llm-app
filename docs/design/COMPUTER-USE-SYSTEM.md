# ComputerUseSystem primitives handoff

Port of `browser-use/macos-harness` **43d9edf**, limited to `ax.py`, `events.py`,
`keys.py`, `pasteboard.py`, `lockscreen.py`, `screenshot.py`, `permissions.py`.
See [the feature plan](COMPUTER-USE.md). No shared contract or Package.swift edits.

## Public production API

Types below live in `ComputerUseSystem`. `WindowRef` means
`ComputerUseCore.WindowRef` (qualify it when importing AppKit/ApplicationServices,
which also exports a Carbon `WindowRef`). Likewise qualify
`ComputerUseSystem.Pasteboard` to disambiguate the legacy Carbon type.
Injection parameters are optional; production uses real system calls by default.

```swift
SystemAX.init(messagingTimeout: Float? = nil,
              calls: SystemAX.Calls = .init(),
              observerCalls: SystemAX.ObserverCalls = .init())
```

`SystemAX: AXBackend` implements every signature in the unchanged Core `AX.swift`:
`app(pid:)`, `get(_:_:) throws`, `names(_:)`, `getMany(_:_:) throws`,
`set(_:_:_:) throws`, `settable(_:_:)`, `actionNames(_:)`,
`actionDescription(_:_:)`, `perform(_:_:) throws`, `param(_:_:_:)`, `pid(_:) throws`,
`windowID(_:)`, `frame(_:)`, `at(_:x:y:)`, `alive(_:)`,
`observe(pid:element:names:callback:) throws -> AXObservation`.

Additional lazy-description API:

```swift
SystemAX.actions(_ element: UIElementRef) -> AXActions
AXActions.names: [String]
AXActions.subscript(name: String) -> String? // cached on first ask; nil for unknown

Events.mouse(_ kind: String, point: CGPoint, window: WindowRef,
             button: Int = 0, click: Int = 1, flags: UInt64 = 0) -> CGEvent
Events.wheel(_ point: CGPoint, dx: Int, dy: Int, window: WindowRef) -> CGEvent
Events.key(_ code: Int, flags: UInt64, text: String? = nil, down: Bool = true) -> CGEvent
Events.flagsChanged(_ flags: UInt64) -> CGEvent
Events.heldFlags() -> UInt64
Events.notice(_ kind: UInt, subtype: Int, windowID: UInt32 = 0,
              flags: UInt64 = 0) -> CGEvent
Events.post(_ pid: pid_t, event: CGEvent, delay: TimeInterval = 0,
            send: (pid_t, CGEvent) -> Void = /* postToPid */,
            sleep: (TimeInterval) -> Void = /* Thread.sleep */,
            timestamp: () -> UInt64 = /* monotonic ns */)
Events.privateSymbol(_ name: String) -> UnsafeMutableRawPointer?

Keys.table: [String: Keys.Key] // Key has code: Int?, flags: Int
Keys.chords(_ spec: String, lenient: Bool = true) throws -> [Keys.Chord]
Keys.modifiers(_ spec: String, lenient: Bool = true) throws -> Int
Keys.currentLayout() throws -> Keys.Layout // (Int, Int) -> String?
Keys.presses(_ text: String, layout: Keys.Layout? = nil,
             typeUnmatched: Bool = true) throws -> [Keys.KeyPress]
// Chord: code: Int, flags: Int; KeyPress adds text: String.
// Convert key flags to UInt64 at the Events boundary.

Pasteboard.init(board: () -> Pasteboard.Backend = /* general board */,
                stateDirectory: () -> URL = /* Paths.stateDirectory */,
                wait: (@escaping () -> Bool, TimeInterval, TimeInterval) -> Bool = /* wait */)
Pasteboard.paste(_ text: String, format: String, sendPasteKey: () throws -> Void,
                 timeout: TimeInterval = 2, landed: (() -> Bool)? = nil) throws
Pasteboard.restoreSaved()
Pasteboard.markdownHTML(_ text: String) -> String // static
Pasteboard.representations(_ text: String, format: String) throws -> [String: Data] // static
Pasteboard.snapshot(_ board: NSPasteboard) -> [[String: Data]] // static
Pasteboard.write(_ board: NSPasteboard, provider: LazyPasteData) -> Int? // static
Pasteboard.restore(_ board: NSPasteboard, saved: [[String: Data]], ours: Int) -> Bool // static
Pasteboard.wait(_ done: @escaping () -> Bool, timeout: TimeInterval,
                poll: TimeInterval = 0.01) -> Bool // static

LockScreen.locked(session: () -> [String: Any]? = /* CG session */) -> Bool
LockScreen.gate(stateRead: Bool, isLocked: () -> Bool = /* locked */) throws

Screenshot.init(folder: URL = /* Paths.screenshotDirectory */,
                stateDirectory: () -> URL = /* Paths.stateDirectory */,
                captureTool: String = "/usr/sbin/screencapture",
                runner: Screenshot.Runner = /* child process */,
                sources: [Screenshot.Source]? = nil,
                uptime: () -> TimeInterval = /* monotonic */,
                appName: (pid_t) -> String = /* NSRunningApplication name */)
Screenshot.capture(_ window: WindowRef, extras: [(UInt32, CGRect)] = []) throws -> Shot
Screenshot.keep(_ path: String, appName: String, now: Date = Date()) throws -> String
Screenshot.proofFolder() -> URL
Screenshot.canCapture() -> Bool
Screenshot.toolImage(_ windowID: UInt32, extraIDs: [UInt32] = []) -> CGImage?
Screenshot.firstImage(_ windowID: UInt32, extraIDs: [UInt32] = []) -> CGImage?
Screenshot.cleanup(maxAge: TimeInterval = 3600, now: Date = Date())
Screenshot.fileName(_ appName: String, now: Date = Date(),
                    timeZone: TimeZone = .current) -> String // static
Screenshot.writeJPEG(_ image: CGImage, path: URL) throws // static
Screenshot.composed(_ base: CGImage, frame: CGRect, extras: [(CGImage, CGRect)],
                    scale: Double) throws -> (CGImage, CGPoint) // static
Screenshot.run(_ executable: String, arguments: [String], timeout: TimeInterval) throws // static
// Source = (UInt32, [UInt32]) -> CGImage?
// Runner = (String, [String], TimeInterval) throws -> Void

Permissions.init(calls: Permissions.Calls = .init())
Permissions.status() -> [String: Bool]
Permissions.request(_ kind: Permissions.Kind)
Permissions.openSettings(_ kind: Permissions.Kind)
Permissions.gate(deadline: TimeInterval, abandoned: () -> Bool = { false },
                 requestUI: Bool = true) throws
Permissions.diagnostics() -> [String: Any]
Permissions.toolCanCapture() -> Bool
Permissions.url(_ kind: Permissions.Kind) -> URL // static
Permissions.names(_ kinds: [Permissions.Kind]) -> String // static
Permissions.responsibleApp() -> String // static; always product
// Kind: accessibility, screenRecording, postEvents, inputMonitoring;
// raw values retain the upstream underscore names. Exposes pane and why.
```

`SystemAX.Calls`, `SystemAX.ObserverCalls`, `Pasteboard.Backend`, and
`Permissions.Calls` expose injectable closures. `LazyPasteData` is the promised
`NSPasteboardItemDataProvider`, with public `payload`, `wasRead`, and
`init(payload:)`. Constants (key modifier bits, event own-tag and field, timing,
format names, screenshot limits/phases) are public on their corresponding type.

## Integration points

Resolved by final orchestration:

- ComputerUseRuntime installs `AX.backend = SystemAX()` with no messaging timeout.
- It restores saved pasteboard contents before accepting requests and on shutdown.
- HarnessExecutor gates every read/action through LockScreen after permissions,
  before Person and the app FIFO; locked calls never reach the read/action pipeline.
- Actions supplies paste's pid-targeted Command-V closure and a landed predicate
  watching the focused field. The pasteboard primitive invents no focus behavior.
- Agent permission gates are passive (`requestUI: false`). Only human controls
  invoke permission requests/open-pane methods, in the helper on MainThread.

Other caller responsibilities (no missing imported modules): windows supplies
`WindowRef` and screenshot extras; tools calls `keep` for `--keep`; helper owns
one long-lived `Permissions` instance (grant/tool caches) and `Screenshot` instance
(source cooldown). Permission requests run **in the LSUIElement helper**, on
`MainThread.callOnMain`; never request on the main app's behalf. Helpers supply a
wall-clock deadline (seconds since 1970) to the permission gate.

## Intentional differences / omissions

- No hierarchy/subtree path: upstream `SUBTREE = False`, with the measured reason
  retained in `SystemAX.swift`. No disabled private hierarchy constants exported.
- AX values are normalized to the Core seam, not exposed as PyObjC/CF wrappers.
  Batch error slots become nil. Nested arrays/dictionaries omit failed entries
  because the seam's `[Any]`/`[String: Any]` entries are nonoptional.
- `AXBackend.frame` is nonthrowing, so a whole-batch error there returns nil; direct
  `getMany` still throws and never retries single reads. Descriptions are cached
  per `AXActions` snapshot, not globally on a stale element.
- A failed observer registration cleans earlier registrations up. This avoids
  leaving callbacks with a dead context (upstream does not unwind partial adds).
- Restore files enforce 0600 even on an existing file, reject symlinks, and a
  failure saving the restore file still restores the current clipboard. Upstream
  only starts its cleanup try/finally after saving the file.
- Proof fallback is renamed `~/.term-llm-computer/proof` when the configured state
  path has spaces. Normal proof storage is `Paths.stateDirectory()/proof`.
- No Python/terminal responsibility lookup or `doctor` naming. `diagnostics`
  always names `product`, using the existing Core missing-grants texts.
- No in-process window capture or unrelated presence/windows/focus/person/apps
  implementation. App-name labels use `NSRunningApplication` directly, as upstream.
- No real app/UI, TCC, device, or signed-helper verification is claimed.

## Tests and verification

`cd ComputerUseKit && swift build && swift test` passes on this Mac.
System tests: **91** (90 newly added + 1 pre-existing); Core **3**, Helper **1**,
**95 total**, no failures or runtime skips. The new tests consolidate Python
parameterized cases (210 key rows, chord errors/aliases, event button types, etc.)
into XCTest loops rather than counting every row as a test. The key golden fixture
is loaded via `Bundle.module`. JPEG quality is checked against the exact upstream
quantization tables, using a small native JPEG marker parser (no PIL dependency).

Tests do not post real input, alter the general clipboard, prompt for permissions,
or open Settings. They use fake AX/observer calls, permission clocks/system calls,
a uniquely named private pasteboard, fake screenshot sources/runners, and temporary
files. Child-process timeout tests run only `true` and `sleep`, not screencapture.

Not ported from the listed Python test files:

- AX tests for the explicitly disabled hierarchy path/array cap, tree-module
  constants, Python fake-export introspection; live parent-app and test-app AX
  reads/notifications.
- Event tests of actions/focus/windows target resolution, activation tiers, click
  sequence timings and focus behavior; those modules are outside this task.
  Event builders, private window-local readback, tagging, and pid-only posting
  are tested. Readback alone may skip on a future OS lacking its private getter.
- Keys' action-layer hold signature test and real current-layout US assumptions.
  Layout search and missing-layout refusal are fake-backed instead.
- Python-only import/loading/signature assertions and terminal-responsibility
  ancestry tests, replaced by Swift compile/API tests and fixed helper identity.
- Lock-screen's 11 parameterizations of nonexistent unlock features are one
  source-safety regression, not 11 duplicate tests.

## App/window context port (`cu-ctx`)

Added `Apps.swift`, `Windows.swift`, `Focus.swift`, `Settle.swift`, `Person.swift`,
and `Instructions.swift`, ported from the same pinned Python reference. No shared
Core/System primitive files or `Package.swift` were changed. Instance modules have
`.shared` defaults (except `Instructions`, a value with an injectable state path).
All AX access goes through `AX.backend`; error text comes from `Errors.make`.

Primary public API (default arguments abbreviated here):

```swift
Apps.init(system: Apps.System = .init())
Apps.resolve(_ identifier: String) throws -> AppTarget
Apps.running(_ target: AppTarget) throws -> AppTarget
Apps.launch(_ target: AppTarget, abandoned: () -> Bool = { false }) throws -> AppTarget
Apps.kind(_ target: AppTarget) -> AppKind
Apps.bundleID(_ pid: pid_t) -> String
Apps.panelService(_ pid: pid_t) -> pid_t?
Apps.panelOwner(_ candidates: [AppTarget]) throws -> AppTarget
Apps.frontmost(hosts: Set<String> = [], procs: [Apps.Proc]? = nil) -> AppTarget?
Apps.prewarm()
Apps.catalog() -> [Apps.Used]
Apps.listApps(hosts: Set<String> = []) -> [[String: Any]]

Windows.init(system: Windows.System = .init())
Windows.keyWindow(_ target: AppTarget) throws -> WindowRef // instance + static shared wrapper
Windows.ordered(_ target: AppTarget) throws -> [WindowRef]
Windows.at(_ target: AppTarget, point: CGPoint) throws -> WindowRef
Windows.ref(_ element: UIElementRef) throws -> WindowRef
Windows.windowRef(_ element: UIElementRef) throws -> WindowRef
Windows.serverWindows(pid: pid_t? = nil) -> [Windows.Row]
Windows.serverWindow(_ id: UInt32) -> Windows.Row?
Windows.extraWindows(target: AppTarget, windowID: UInt32) -> [Windows.Row]
Windows.openMenu(_ target: AppTarget) throws -> UIElementRef?
Windows.shownMenu(_ target: AppTarget) throws -> UIElementRef?
Windows.waitForMenu(_ target: AppTarget, opener: UIElementRef) throws -> UIElementRef?
Windows.keepMenu(_ target: AppTarget, title: UIElementRef)
Windows.closeMenu(_ target: AppTarget)
Windows.watch(_ target: AppTarget) throws
Windows.unwatch(_ target: AppTarget)

Focus.init(system: Focus.System = .init())
Focus.enforcer(_ target: AppTarget) -> Focus.Enforcer
Focus.Enforcer.active<T>(window: WindowRef?, _ work: () throws -> T) throws -> T
Focus.Enforcer.reallyActive / believesActive / believesFocus: Bool
Focus.release(_ target: AppTarget)
Focus.releaseAll()
Focus.frontPID() -> pid_t // static
Focus.noAttention(_ pid: pid_t) // static
Focus.focusElement(_ element: UIElementRef) -> Bool // static

Settle.wait(target: AppTarget, kind: AppKind, read: (WindowRef) throws -> Capture,
            poll: TimeInterval? = nil, quiet: TimeInterval = 0.25, limit: TimeInterval = 5,
            now: @escaping () -> TimeInterval, sleep: (TimeInterval) -> Void,
            abandoned: () -> Bool = { false },
            keyWindow: (AppTarget) throws -> WindowRef = Windows.keyWindow) throws -> Capture?
// now/sleep also default to uptime/Thread.sleep. Static method; observer always stopped.

Person.init(system: Person.System = .init(), hooks: Person.Hooks = .init())
Person.startWatch(ownPID: pid_t)
Person.gate(agent: AgentSession, target: AppTarget, stateRead: Bool,
            abandoned: () -> Bool = { false }) throws
Person.interrupted(_ target: AppTarget, since: TimeInterval) -> Bool
Person.afterStateRead(_ target: AppTarget)
Person.turnEnded(_ agent: AgentSession)
Person.driven() -> [AppTarget]
Person.wentTo(_ pid: pid_t, since: TimeInterval) -> Bool
Person.secureInputPID() -> pid_t? // static
Person.saw(kind: UInt32, sourcePID: pid_t, tag: Int64, pid: pid_t,
           keycode: Int = 0, stray: Bool = false, command: Bool = false)

Instructions.init(stateDirectory: @escaping () -> URL = { Paths.stateDirectory() })
Instructions.personalDirectory() -> URL
Instructions.note(_ bundleID: String) -> String?
Instructions.prefix(agent: AgentSession, bundleID: String) -> String?
```

`Apps.System` covers processes, kernel executable checks, bundles/files, Launch
Services, usage query, window readiness, panel ownership and clocks. `Proc` and
`Used` are public value rows. `Windows.System` supplies CG rows/associations, clock
and no-attention hook; `Row` exposes `id`, `pid`, `title`, `layer`, `frame`.
Screenshot extras are `extraWindows(...).map { ($0.id, $0.frame) }`.
`Focus.System` supplies front-pid, event posting, freeze/thaw, clocks, background
work and the person's-switch predicate. Private symbol wrappers also accept fake
symbol resolvers for grant-free tests. `Person.System` supplies the front process,
bundle lookup, hardware idle, secure-input owner and listen preflight; `Hooks`
supplies presence activity, timers, shown-menu and pid-only posting. Its callback
logic (`onEvent(kind:event:reenable:)`) can be tested without installing a tap.

Final integration: ComputerUseRuntime connects Person.pointerActivity to Presence,
starts the Person watch on the helper main loop, and prewarms Apps. HarnessExecutor
supplies Settle's reader, clears needsSettle before waiting and reuses the returned
capture. Session lifetimes balance Windows.watch/unwatch and Revisions.watch/reset;
calls use Person.gate both before and after queueing, afterStateRead and its
interruption predicate. Turn cleanup calls Person.turnEnded and Focus.release;
shutdown calls releaseAll. The upstream window-bounds TODO remains deliberately
outside orchestration: bounds are refreshed per state/action, not by a live tracker.

Deliberate Swift differences: module-global state becomes injectable long-lived
instances; Python context managers become throwing closure scopes; AX points are
already normalized by the shared backend; a typed `System` closure cannot raise
an arbitrary Python exception into the event callback. Notes are embedded/trimmed
Swift literals (all eight checked against upstream SHA-256), with no library
resources. Personal overrides remain under `Paths.stateDirectory()/instructions`,
case-insensitive by basename, and unreadable/empty files suppress built-ins too.
Process ids use `pid_t`, and Core's existing `AgentSession` replaces Python's
session object; no dependency on the pending `AppSession` was introduced.

Verification: `cd ComputerUseKit && swift build && swift test` passes: **96 new
context tests**, **187 System**, **3 Core**, **1 Helper**, **191 total**, zero
failures/runtime skips. Tests consolidate Python parameterizations into loops and
use fake AX, clocks, app systems, C function pointers, hooks and temporary files.
They do not launch apps, post input, install taps, change focus, or require grants.

Not run/ported as live tests: Python's real-kernel/process inventory, real Mac
resolve/background launch, idle-app AX settling, live event-tap/input and modifier
state checks. Python-specific source/signature/import assertions and tests of
unmerged actions/tools/CLI/Session settle-flag or cell-chaining behavior are not
claimed here; equivalent local context decisions are exercised directly. Existing
SystemAX tests own observer-registration unsupported/error-code behavior. No UI,
signed-helper, TCC, or live focus-restore verification is claimed. The deprecated
`NSWorkspace.fullPath(forApplication:)` fallback is intentionally retained for the
upstream name-resolution behavior.
## Presence, policy and approvals (cu-presence)

The following is additive to the primitives above. No shared base files or
`Package.swift` were changed. These ports use the same Python reference commit,
`43d9edf`; library targets still have no bundled resources or third-party deps.

### Core API

```swift
// Pointer.swift: global screen points, origin top-left; degrees clockwise.
Pointer.Shape.init(a: Double = 0, sx: Double = 1, sy: Double = 1, b: Double = 0)
Pointer.Move // mode, start/end, path, response, damping, duration, arrive
Pointer.plan(_ start: CGPoint, _ end: CGPoint, bounds: CGRect) -> Pointer.Move
Pointer.position(_ move: Pointer.Move, _ t: Double) -> (point: CGPoint, heading: CGPoint)
Pointer.pose(_ move: Pointer.Move, _ t: Double) -> (point: CGPoint, shape: Pointer.Shape)
Pointer.outlinePoints(chords: Int = 6) -> [CGPoint]
Pointer.pressScale(_ t: Double) -> Double
Pointer.clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double
Pointer.add(_ p: CGPoint, _ v: CGPoint, _ k: Double = 1) -> CGPoint
Pointer.distance(_ p: CGPoint, _ q: CGPoint) -> Double
Pointer.toward(_ p: CGPoint, _ q: CGPoint) -> CGPoint
Pointer.interpolate(_ rows: [(Double, Double)], _ key: Double) -> Double
Pointer.spring(_ t: Double, response: Double, damping: Double) -> Double
Pointer.cubic(_ curve: [CGPoint], _ t: Double) -> CGPoint
Pointer.tangent(_ curve: [CGPoint], _ t: Double) -> CGPoint
Pointer.reach(_ bounds: CGRect, _ p: CGPoint, _ v: CGPoint, _ length: Double) -> CGPoint
Pointer.candidates(_ start: CGPoint, _ end: CGPoint, bounds: CGRect) -> [[[CGPoint]]]
Pointer.measure(_ path: [[CGPoint]], bounds: CGRect)
    -> (length: Double, energy: Double, sharpest: Double, turn: Double, inside: Bool)
Pointer.glide(_ start: CGPoint, _ end: CGPoint, bounds: CGRect)
    -> (path: [[CGPoint]], response: Double)
// Look/motion constants are public on Pointer.

// Pure overlay geometry/state. Rectangles are CGRect (not LTRB tuples).
OverlayGeometry.ease(_ u: Double) -> Double
OverlayGeometry.grow(_ box: CGRect, by: Double) -> CGRect
OverlayGeometry.holds(_ box: CGRect, _ point: CGPoint) -> Bool
OverlayGeometry.flashBox(_ frame: CGRect, within: CGRect?) -> CGRect?
OverlayGeometry.flipScreens(_ frames: [CGRect]) -> [CGRect]
OverlayGeometry.bounds(of screens: [CGRect], points: [CGPoint]) -> CGRect
OverlayGeometry.windowFrame(_ box: CGRect, primaryHeight: Double) -> CGRect
OverlayGeometry.windowOrigin(_ point: CGPoint, primaryHeight: Double) -> CGPoint
OverlayGeometry.targetWindow(_ point: CGPoint, pid: Int32?,
    windows: [OverlayGeometry.Window], window: Int = 0) -> OverlayGeometry.Window?
OverlayGeometry.stacking(_ point: CGPoint, pid: Int32?, frontmost: Int32?,
    windows: [OverlayGeometry.Window], window: Int = 0) -> OverlayGeometry.Place?
// Window = id/pid/level/bounds; Place = level/window; public initializers.
OverlayCommand // .move(point,pid:window:animate:), .press(count),
               // .activity("idle"|"loading"|"paused"),
               // .flash(rect,within:pid:window:), .halo(rect,pid:window:), .done
OverlayCommand.valid: Bool
PointerTrack.init(now: Double, idle: Double = OverlayGeometry.idle)
PointerTrack.go(_ target: CGPoint, now: Double, screens: [CGRect], animate: Bool = true)
PointerTrack.lands(_ now: Double) -> Double
PointerTrack.press(_ count: Int, now: Double)
PointerTrack.act(_ state: String, now: Double)
PointerTrack.frame(_ now: Double) -> PointerTrack.Frame?
// Frame = point/shape/press/opacity/blur/wake/fill; public initializer.
OverlayMark.init()
OverlayMark.show(_ box: CGRect?, now: Double, until: Double,
                 appear: Double = OverlayGeometry.fade)
OverlayMark.alive(_ now: Double) -> Bool
OverlayMark.alpha(_ now: Double) -> Double
OverlayMark.follow(_ windows: [OverlayGeometry.Window], now: Double) -> OverlayGeometry.Place?
OverlayMark.wake(_ now: Double) -> Double
OverlayScene.init(now: Double, idle: Double = OverlayGeometry.idle)
OverlayScene.command(_ command: OverlayCommand, now: Double, screens: [CGRect], calm: Bool = false)
OverlayScene.wake(_ now: Double, frame: PointerTrack.Frame) -> Double
// Scene exposes track, flash, halo, pid, window; caller serializes mutable state.

Ask.init(title: String, subtitle: String? = nil, choices: [String],
         onAnswer: @escaping (String) -> Void)
AskQueue.init()
AskQueue.asks: [Ask] // read-only, FIFO
AskQueue.append(_ ask: Ask)
AskQueue.answer(_ ask: Ask, choice: String) // removes before callback, once by identity
AskQueue.withdraw(title: String) // never answers
PanelGeometry.origin(size: CGSize, visible: CGRect) -> CGPoint // AppKit y-up
PanelGeometry.width: Double // 340
PanelGeometry.margin: Double // 16
ActivityWindow.init()
ActivityWindow.update(working: Bool, now: TimeInterval) // mutating
ActivityWindow.visible(now: TimeInterval) -> Bool
ActivityWindow.remaining(now: TimeInterval) -> TimeInterval
ActivityWindow.linger: TimeInterval // static, 3 seconds

PolicyTOML.parse(_ text: String) throws -> PolicyTOML.Document
// Document.values: [String: Value], bundleIDs: [String: String]
// Value = .bool(Bool), .string(String), .strings([String]); ParseError.description.
Policy.init(managedFile: URL = Policy.managedFile,
            userFile: URL = Paths.stateDirectory().appendingPathComponent("policy.toml"),
            appKind: @escaping (AppTarget) -> AppKind = { _ in AppKind() })
Policy.load() throws -> Policy.Configuration
Policy.evaluate(agent: AgentSession, target: AppTarget) throws -> PolicyDecision
Policy.evaluate(agent: AgentSession, target: AppTarget,
                config: Policy.Configuration) throws -> PolicyDecision
Policy.decide(agent: AgentSession, target: AppTarget) throws -> PolicyDecision
Policy.checkRecipient(_ bundleID: String) throws
Policy.watchesURLs() throws -> Bool
Policy.checkURL(_ url: String?) throws
Policy.displayName(_ target: AppTarget) -> String // static
Policy.shellMatch(_ text: String, pattern: String) -> Bool // static
// Configuration(layers: [Policy.Layer]); Layer() / Layer(document:).
// Public sets: terminals, passwordManagers, elevated, security, ownBundles.
// Public managedFile and warning constants.

ApprovalStore.init(directory: URL = Paths.stateDirectory())
ApprovalStore.file: URL // approvals.json
ApprovalStore.sessionsFile: URL // sessions.json
ApprovalStore.always() -> [String: String]
ApprovalStore.save(bundleID: String, now: Date = Date()) throws
ApprovalStore.sessions(alive: (String) -> Bool) -> Set<ApprovalStore.SessionGrant>
ApprovalStore.saveSession(agent: String, bundleID: String, alive: (String) -> Bool) throws
ApprovalStore.write(_ object: Any, to file: URL) throws // static, atomic 0600
// SessionGrant.init(agent: String, bundleID: String), Hashable.
```

`approvals.json` is documented in the source for the main app to list/remove
persistent entries. Example:

```json
{
  "always": {"com.apple.TextEdit": "2026-11-10T08:00:00Z"},
  "modified": "2026-11-10T08:00:00Z"
}
```

`always` maps **bundle ID → UTC ISO-8601 approval date**. Removing a key revokes
that persistent grant for future sessions; already granted session approvals
continue for that session/helper's life, as upstream. Both files are reread when
checking approvals. `sessions.json` is an array of `[agentKey, bundleID]` pairs;
numeric process keys require a matching pid **and start time** to survive helper
restart. PID-only targets never get an `always` entry. Missing/malformed approval
files grant nothing. Scratch files use exclusive creation, no symlink following,
0600 from creation, fsync and atomic rename, rather than a shared `.tmp` path.

### System API

```swift
Overlay.shared: Overlay
Overlay.init()
Overlay.enabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool // static
Overlay.send(_ command: OverlayCommand) // fire-and-forget, invalid commands dropped
Overlay.transform(shape: Pointer.Shape, press: Double) -> CATransform3D // static
Overlay.pointerImage(coverOnly: Bool = false, fill: Double = Pointer.fill) -> NSImage // static
Overlay.accent: NSColor // static, upstream orange (255,127,39)

Panel.shared: Panel
Panel.questions: AskQueue
Panel.append(_ ask: Ask) // main thread only
Panel.withdraw(title: String) // main thread only
Panel.draw() // main thread only
Panel.makePanel(_ ask: Ask, target: AnyObject) -> NSPanel // static, main, starts offscreen

Presence.shared: Presence
Presence.init(enabled: @escaping () -> Bool = /* pointer switch */,
              now: @escaping () -> Double = /* uptime */,
              send: @escaping (OverlayCommand) -> Void = /* Overlay.shared.send */,
              schedule: @escaping (@escaping () -> Void) -> Void = MainThread.onMain,
              ask: @escaping (Ask) -> Void = /* Panel.shared.append */,
              withdraw: @escaping (String) -> Void = /* Panel.shared.withdraw */)
Presence.pointerMove(_ point: CGPoint, window: WindowRef? = nil) -> Bool
Presence.pointerPress(count: Int = 1) -> Bool
Presence.pointerActivity(_ state: String) -> Bool
Presence.flash(_ rect: CGRect, window: WindowRef? = nil) -> Bool
Presence.halo(_ window: WindowRef?) -> Bool
Presence.liveView(_ window: WindowRef?) -> Bool // intentional no-op
Presence.turnDone() -> Bool
Presence.ask(_ question: Ask) -> Bool
Presence.ask(title: String, subtitle: String? = nil, choices: [String],
             onAnswer: @escaping (String) -> Void) -> Bool
Presence.withdraw(title: String) -> Bool
Presence.pause: Double // static, 4.75 s; turnDone clears pause, keeps questions
// All return at once, never throw. Bool = handed over, NOT proof of visible UI.
// shared also refuses questions before the helper's AppKit run loop starts.

Approvals.init(store: ApprovalStore = ApprovalStore(),
               ask: @escaping (Ask) -> Bool = /* Presence.shared.ask */,
               withdraw: @escaping (String) -> Void = /* Presence.shared.withdraw */,
               now: @escaping () -> TimeInterval = /* wall-clock seconds */,
               sleep: @escaping (TimeInterval) -> Void = /* Thread.sleep */,
               alive: @escaping (String) -> Bool = Approvals.namedSessionAlive)
Approvals.stored() -> (always: [String: String], session: [String])
Approvals.approve(bundleID: String, always: Bool) throws // human-facing/library API, no agent route
Approvals.approved(agent: AgentSession, bundleID: String, policy: PolicyDecision) -> Bool
Approvals.ensure(agent: AgentSession, target: AppTarget, policy: PolicyDecision,
                 deadline: TimeInterval, abandoned: () -> Bool = { false }) throws
Approvals.clearDenials(agent: AgentSession)
Approvals.namedSessionAlive(_ key: String) -> Bool // static, numeric keys fail closed
// Public constants: deny, session, always (button texts), poll=0.25, giveUp=10.

ActivityBanner.shared: ActivityBanner
ActivityBanner.init()
ActivityBanner.onStop: (() -> Void)? // thread-safe property, callback on main
ActivityBanner.update(working: Bool) // enqueues on main, no focus
ActivityBanner.stop() // hides and removes monitors; helper teardown
ActivityBanner.isStopKey(code: UInt16, tag: Int64) -> Bool // static, pure gate
ActivityBanner.text: String // static, "term-llm is using your computer · Esc to stop"
```

`Approvals.approve` is **not an agent tool**. No `approve` command parser,
self-approval fallback, agent-key parameter or helper control method is exposed.
The main app's human-facing window edits `approvals.json` directly through
`ApprovalStore`; panel yeses use a private session-scoped recording method.
`ensure` refuses a denied/forbidden decision even with `ask == false`; the caller
must still use `Policy.decide` first (disabled/security-process gates).

### Integrated orchestration responsibilities

- ComputerUseRuntime starts the LSUIElement helper's MainThread loop and uses
  Presence.shared. There is no standalone overlay process/socket or resource set.
- HarnessExecutor injects Policy(appKind: Apps.kind), resolves apps then calls
  Policy.decide → Approvals.ensure before every app read/action. Actions calls
  checkRecipient before cross-process AX operations/events; reads/browser action
  chains call checkURL, with a blocked URL deactivating the app session.
- One long-lived Approvals instance checks named sessions or pid:startTime against
  helper process lookup. Malformed numeric identities fail closed. Turn boundaries
  clear denials; AgentSession.withState serializes lifecycle and panel mutations.
  Approval waits are worker-only, stop ten seconds before the deadline and retain
  questions after disconnection/timeout as upstream.
- There is no approval socket command or agent argv path. Persistent approval is
  owned by ApprovalStore in the human-facing main-app window.
- HelperServer aggregates running calls and calls ActivityBanner.update. The
  banner's three-second linger matches server working status. Its onStop and the
  stop control share stopCurrentTurn: active/recent agents are cancelled and
  refused until turn-started. No synthetic input implements Stop.
- Turn end and dead-agent reaping use one letGo path, app FIFOs and watcher/focus
  cleanup, then Presence.turnDone only when no agent drives an app. Shutdown
  drains reaping as well as socket workers and stops the banner.

### Intentional changes and verification limits

- Default `ask_before_first_use` and `strict` are **true**. Terminals are therefore
  forbidden; password managers/Keychain, both term-llm bundle IDs and the Privacy
  & Security extension join the forbidden list. ScreenContinuity stays elevated.
  As upstream, denies win, false wins for enabled/persistent, true wins for
  ask/strict/forbidden override. With the new true defaults, disabling ask/strict
  requires **both layers** explicitly false; a missing layer contributes defaults.
  The explicit `allow_forbidden_targets` override remains; system security
  recipients are never driven even with it.
- TOML is a closed subset, not a general TOML library: comments, whitespace,
  single/double quoted strings (basic escapes/Unicode), bools, multiline string
  arrays/trailing comma, and one `[bundle_ids]` string table. Duplicate/unknown
  keys, unsupported tables, numbers, inline tables and bad types fail closed as
  `policy_unreadable`. Unknown access strings deny rather than accidentally allow.
  Files are reread, not mtime-cached, so revocation cannot be hidden by timestamps.
  URL patterns match the whole lowercased URL or host with shell semantics,
  including literal backslashes (not regexes or filesystem slash/dot rules).
- Overlay windows are click-through borderless nonactivating panels that can
  never become key/main, join all Spaces, and initially use level 102. Background
  target stacking preserves upstream occlusion and the halo follows its window.
  Pointer uses a transparent screen-union window with a small animated glass/image
  layer (rather than moving a 112-point NSWindow each frame). Spring, press, fade,
  blur and loading-rock poses are sampled into Core Animation keyframes at 60 Hz;
  the render server advances them without worker/main per-frame drawing. A 0.1 s
  main-thread poll follows/re-stacks windows; it is not the pointer frame clock.
  Reduced motion jumps and reduced transparency hides the glass. Display hot-plug
  is picked up on the next command, as upstream refreshes its screen list there.
- Banner is click-through (optional Stop button omitted); it observes local/global
  keyDown, ignores `Events.ownTag`, returns local events unchanged, and only invokes
  injected `onStop`. It never consumes Esc or activates the helper.
- Live-view is an explicitly commented no-op. No caller process/argv, private app
  session code, or main-app UI is invented here.

Tests use fake clocks, queued UI closures, temporary stores and pure scene state;
**none of the new tests puts windows on screen or installs input monitors**.
The pointer JSON fixture is loaded from the existing test-only `Bundle.module`
resource. At rest, floating-point endpoint differences may choose `R(0)` or
`R(-134) * identity * R(134)`; the fixture test compares their identical net
rotation when scale is exactly identity, not arbitrary decomposed angles.

Not ported / intentionally skipped upstream tests (no runtime XCTest skips):

- Overlay datagram encoding, socket path/fallback, detached process startup,
  queue saturation/retry/crash and malformed datagram decoding: no datagrams or
  child drawing process exist. Typed commands have finite-number/activity tests.
- Pixel golden/rendering, glass/mask/Retina raster and live-window overlay tests:
  this task ports geometry/state tests, not Python/PyObjC rasterization guarantees.
- Panel fake-AppKit constructor/selector introspection and live question clicking:
  pure FIFO, answer-once, withdrawal, reentrancy and screen geometry are tested;
  actual window focus/style/click behavior awaits the integrated helper.
- Approvals/policy action decorators, listing-app wrappers, orchestration timeout
  suspension and process ancestry lookup: those modules are unmerged. Public
  seams are tested with fake answers, clocks, cancellation and alive predicates.
- Python import/monkeypatch/introspection checks and command-path self-approval:
  replaced with Swift API tests or deliberately absent command functionality.

The full package verification and exact test counts for this addition are recorded
below after the final build. Live UI validation was attempted with
`macos-harness get_app_state --app Simulator`; it returned "No app called Simulator",
and `list_apps` confirmed no Simulator. No integrated helper app is built in this
worktree yet. Thus live appearance, nonactivation/focus preservation, multi-display
CA composition, real Esc delivery/TCC and stop orchestration are **unverified**;
there is no UI Screenshot proof path to report.

### Verified package checks for cu-presence

`cd ComputerUseKit && swift build && swift test` passes: **171 tests**, zero
failures and zero runtime skips (**52 Core, 118 System, 1 Helper**). This addition
contributes **76 tests**: 4 pointer (the shared multi-case JSON fixture is a loop),
20 overlay state/geometry, 14 policy/TOML, 5 approval store, 6 question/banner
logic, 17 approval waiting and 10 presence/event-gate/transform tests. No app build,
TCC prompt, real input posting or live-device verification is claimed.

Shared base-file edits: **none**. The only existing file changed is this document,
by appending this section. All Swift source and test changes are new owned files.

## Final integration wave (cu-integ)

`Actions.swift` ports the AX → pid-targeted mouse → fake-activation keys ladder,
menu read/fill/pick/cancel, visible-part/scroll-area geometry, drag steps, scrolling,
held keys/clicks with unconditional release, layout-aware typing, clipboard paste,
value writes, rich-text selection and secondary actions. Timing/role constants and
measured app quirks are retained. The real pointer never moves; only an explicitly
requested Raise changes window order. The environment override is product-named
TERM_LLM_COMPUTER_ALWAYS_SIMULATE_CLICK. Oversized wheel deltas are refused rather
than trapping at Swift's Int32 boundary; nil text-marker results fail clearly.

Public orchestration/test seams: Actions.Target (.line/.point), Actions.System,
HarnessExecutor.Dependencies, appSessions, stillWanted, switchOff, letGo and
agentExited; HelperConfiguration onStarted/onMaintenance/onWorking/installStop;
ToolCallRequest withCleanupQueue; AgentSession.withState. Production defaults call
the real primitives. Fakes replace effects, not request ordering. App sessions are
per agent/canonical path and preserve first-use order for panel owner selection.

Startup/teardown and API/result details are in [the shell guide](COMPUTER-USE-SHELL.md).
All orchestration TODO(integration) markers are resolved. The sole remaining
source marker is Windows' upstream live-bounds tracker note; refreshing bounds on
each state/action is intentional. Live-view remains the existing intentional no-op.

Final checks: swift build and swift test pass (**454 tests**, zero failures/skips:
161 Core, 246 System, 47 Helper), including 32 new Actions tests, 34 executor tests
and a concurrent working/Stop regression. The unsigned TermLLMMac build passes.
The isolated no-grants socket smoke returns list_apps successfully and refuses
Finder state with the missing Accessibility and Screen Recording text; the helper
then stops cleanly. The disposable Finder app approval only bypassed the panel,
not TCC; no grants, real app input or live-app screenshots were used.

These checks do not establish real AX/action success, clipboard delivery to live
apps, background focus preservation, TCC grant/revocation UI, real Esc delivery,
pixel/appearance/multi-display correctness, signed LaunchServices responsibility,
notarization or release signing. Historical per-wave counts/limits above describe
those waves, not the final package totals. No live UI Screenshot proof is claimed.
