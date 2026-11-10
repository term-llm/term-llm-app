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
Permissions.gate(deadline: TimeInterval, abandoned: () -> Bool = { false }) throws
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

Marked `TODO(integration)` in code:

- Helper startup: `AX.backend = SystemAX()` (default **no** messaging timeout).
- Before accepting requests: `Pasteboard().restoreSaved()` for crash recovery.
- Every request: call `LockScreen.gate(stateRead:)` before touching an app.
- Actions supplies paste's pid-targeted Command-V closure and optional `landed`
  predicate. The primitives do not activate apps or invent focus behavior.

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
