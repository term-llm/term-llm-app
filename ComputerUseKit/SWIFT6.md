# Swift language-mode boundary

`TermLLMMacKit` and the Xcode `TermLLMComputerUse` / `TermLLMComputerCLI`
entry-point targets use Swift 6. ComputerUseKit now defaults new targets to
Swift 6, with an explicit per-target migration boundary:

| Target | Language mode |
| --- | --- |
| `ComputerUseClient` | Swift 6 |
| `ComputerUseClientTests` | Swift 6 |
| `ComputerUseCoreTests` | Swift 6 |
| `ComputerUseCore` | Swift 6 |
| `ComputerUseSystem`, `ComputerUseHelper` | Swift 5 |
| `ComputerUseSystemTests`, `ComputerUseHelperTests` | Swift 5 |

All targets use the Swift 6 toolchain and a macOS 14 minimum. Swift 6 clients and
tests can consume a Swift 5 module; this does **not** make that module's internals
concurrency-checked. These explicit legacy settings are temporary compatibility
boundaries, not claims that the helper's worker architecture is fully checked.

## First incremental round

Client and the safe Core/Client test targets compile in Swift 6 without unsafe
annotations. `ActivityWindow` and `ApprovalStore.SessionGrant` now have checked
`Sendable` conformances: their stored state is entirely value-based. Two worker
snapshot tests exercise independent activity copies and shared immutable grant
values. The safe test subset contains 171 tests (169 existing plus two added).
It passes normally and under Thread Sanitizer. All package test targets and the
Mac app/helper/CLI/test bundle compile with the mixed language modes. System and
Helper tests are compile-only in this round; this is not live Computer Use or
interactive UI verification.

At the end of the first round, a Core-only Swift 6 probe failed on `AX.installed`
in `Sources/ComputerUseCore/AX.swift`:

> Static property `installed` is not concurrency-safe because it is nonisolated
> global shared mutable state.

The Swift 5 complete strict-concurrency probe reported that same warning. The
second round below resolves the ownership boundary rather than suppressing that
diagnostic. No new unsafe annotations were added in the first round.

## Second incremental round: Core and the AX contract

Core now compiles in Swift 6. The synchronous backend API remains concurrent;
ordinary AX calls have not been routed to the main actor or serialized globally.

- `AXBackend` and `AXObservation` require `Sendable`; observation callbacks and
  injected `SystemAX.Calls` / `ObserverCalls` closures require `@Sendable`.
  SystemAX owns immutable copies of those dependency values.
- A checked `AXBackendRegistry` protects the reference to a genuinely Sendable
  backend. Backend calls and release of replaced backends occur outside the
  registry lock, including reentrant deinitializers.
- `AX.withBackend` supplies a synchronous task-local test scope. Nested scopes and
  concurrent tests do not change each other's backend or the production registry.
  Structured tasks inherit the scope; arbitrary GCD workers do **not**. Pass a
  captured backend to those workers and join work before leaving a test scope.
- Heterogeneous `Any` arguments/results are synchronous operation-local values,
  not Sendable payloads. Do not share mutable results or capture them in tasks;
  use typed snapshots at real concurrency boundaries. Opaque SDK values needed
  for synchronous parameterized round trips retain that same restriction.
- Fake backends, nodes and logs now synchronize their mutable state. Hooks run
  outside locks. Their five heterogeneous state locks use the unchecked lock APIs
  solely for value/immutable/synchronized fixture contents; an arbitrary mutable
  object must not be inserted into those fixture graphs.
- `Revisions`, `Windows` and `Settle` callbacks capture synchronized recorders,
  not their mutable owner graphs. Resetting/rewatching Revisions starts a fresh
  recorder, so a previously claimed callback cannot invalidate a later watch.
- Observer creation and target-app registration/removal run on their calling
  worker, not the helper's main thread: these AX requests can block on a busy
  target. Only local run-loop source install/uninstall hop to main. Teardown
  closes delivery, claims cleanup once, uninstalls the source, then removes the
  registrations. No claim lock spans a callback or a main-thread wait. The
  first worker stop may wait for an in-flight SDK main callback while uninstalling;
  subsequent stops do not wait for cleanup, and reentrant stop does not wait for
  its own callback. The delivery gate itself only prevents future claims, so
  an already claimed fake/off-main callback may still finish after stop returns.

There is one new narrow `@unchecked Sendable`: the private `ObserverToken` that
owns an SDK `AXObserver` handle and its retained callback context. The SDK does
not declare the handle Sendable. The token is creator-owned before source
installation; only source install/uninstall use the main run loop, and after
uninstall a single claimant removes registrations. Observation retains the token
for its full lifetime, including after stop, and the callback context is kept
alive through invocation. Injected tokens must themselves be Sendable. This is
not an unchecked conformance for SystemAX, a fake backend, or an arbitrary
dependency graph. No new `nonisolated(unsafe)` or `@preconcurrency` annotations
were added.

Source compatibility changes: custom AX backends/observations must satisfy the
new Sendable contracts; observer-injection tokens use `any Sendable` instead of
`AnyObject`. The injected Settle clock and Windows `noAttention` closure are now
`@Sendable`. `noAttention` is snapshotted at watch creation; edits take effect on
the next watch rather than during an existing observation. The Mac controller now
imports Core without `@preconcurrency`; approval-store instances are constructed
inside their worker tasks, transferring only the Sendable directory URL.

After the Opus review corrections, the 205-test AX/Core/Client allowlist passed
normally and under Thread Sanitizer, and the Mac app/helper/CLI/test bundle
compiled. System/Helper tests outside that allowlist
remain compile-only. Live AX observation delivery, actual app interaction and
permissions are not established by these fake-only checks.

## Third incremental round: Screenshot dependencies

`Screenshot` now has checked Sendable conformance. Its stored dependencies are
immutable and `Runner`, `stateDirectory`, `uptime`, and `appName` callbacks require
`@Sendable` (capture sources already did). The cooldown dictionary is owned by an
`OSAllocatedUnfairLock`; no injected callback executes while holding that lock.
Concurrent timeout publications retain the later deadline so a delayed clock
sample cannot shorten a newer cooldown. Capture order, timeout constants,
answered-nil retries and exact-deadline eligibility remain unchanged.

Four fake-only regressions cover sharing one instance across capture workers,
shared cooldown/deadline behavior, out-of-order timeout publication and reentrant
clock callbacks. Injected runners write fixture pixels into private temporary
directories; no screenshot command or permission request is made. The existing
process test runs only `/usr/bin/true` and `/bin/sleep`. The source and its tests
also pass isolated Swift 6 typechecks with warnings as errors, even though the
rest of their System module still explicitly uses Swift 5. No unchecked
conformance, unsafe isolation annotation or actor was added for this round.

## Fourth incremental round: Presence and Permissions

Both adapters now have checked Sendable conformance, immutable `@Sendable`
dependencies and typed lock-owned state. Presence samples its clock outside the
pause lock; older samples cannot shorten a newer human-input pause. Permission
preflights and capture checks remain on their caller; only request/open uses the
synchronous main-thread handoff. No callback, main-thread hop or wait runs under
the state lock.

Required-grant and capture probes have explicit owner/completion tokens. Passive
gates distinguish pending from denied and wait with cancellation/deadline checks,
so an initially successful concurrent probe cannot cause a false permission
refusal. A gate reentered by its own unfinished probe reports pending rather than
self-waiting; a directly reentrant Boolean capture query uses the last published
cache value. The synchronous SDK probe itself remains non-preemptible, as before.
Relaunch-intent revisions prevent stale preflight or Settings samples from
consuming newer Allow intent. Waiting gates poll at 0.25 seconds; unlike the old
lock wait they can observe cancellation/deadlines during another worker's probe.

Opus reviewed this milestone with no merge blockers. Its test-strength findings
were addressed with negative completion checks and concurrent denied passive-gate
coverage. The audited subset is now 277 tests, including 14 Presence and 36
Permissions tests. Normal and TSan runs pass, both adapters/tests pass isolated
Swift 6 checks with warnings as errors, and Mac app/test compilation passes.
Permissions tests use explicit fail-fast fakes; no real grant query, prompt,
Settings launch, capture or UI is exercised. No unsafe annotation was added.

## Next bounded rounds

1. Make System adapter dependencies immutable where possible and give their
   injected callbacks explicit Sendable/main-actor contracts. Start with a
   bounded adapter; do not declare whole mutable dependency graphs unchecked.
2. Separate Person's main-thread event-tap lifecycle from worker-visible
   interaction state. Preserve human-input priority and callback reentrancy.
3. Specify ownership of the Helper executor, session state, configuration and
   shutdown callbacks, then migrate the remaining targets and their tests.

Avoid a broad actor rewrite: per-app FIFO ordering, cancellation cleanup and the
helper's main run loop must keep their current behavior. Core's successful Swift 6
build does not establish thread safety for the remaining Swift 5 adapters.

## Why not enable Swift 6 for all library targets yet?

The initial migration compiled after adding `@unchecked Sendable` to the system
adapters and helper server. That would promise more than their APIs guarantee:

- `Apps`, `Focus`, `Windows`, and `Person` expose mutable `system` / `hooks`
  properties. Their callback captures are not `@Sendable`; locking a cache does
  not make those captures safe. `Person` additionally owns a main-run-loop event
  tap and worker-visible state whose lifecycle needs explicit isolation.
- `Approvals` still has non-Sendable injected callbacks.
  A `let` closure is not proof that the objects it captures are synchronized.
- `HelperServer` captures a `ToolExecutor`, configuration callbacks, and
  `Sessions` on socket workers. Its condition protects server bookkeeping, not
  the complete executor/dependency graph or externally assigned `onShutdown`.

These adapters have **not** been declared unchecked-Sendable to silence those
errors. Finishing the migration needs immutable, Sendable dependency seams (or
explicit actor/queue ownership), a separate main-thread tap lifecycle, and an
end-to-end audit of the AX callbacks and executor graph, including their fakes.
Do not enable package-wide Swift 6 by restoring blanket unchecked conformances
or adding `@preconcurrency` imports / unsafe compiler flags.

## Retained groundwork

- UI panels, overlays, banner state and the helper AppKit loop have explicit
  main-actor ownership. Main-queue/run-loop callbacks assert that documented
  boundary; no window is constructed by the no-run-loop worker fallback.
- Main-loop availability, question queues, counters, AX backend replacement,
  tree-switch bookkeeping, and process/capture result caches are lock-guarded.
  Questions use Sendable answer callbacks; an answer is removed under the lock
  and invoked outside it, so concurrent and reentrant answers happen once.
- Immutable cross-thread value types declare Sendable. `AppFIFO` has a narrow
  unchecked conformance: its entire mutable ticket/busy state is condition-locked.
  The existing AX handle and AgentSession conformances retain their documented
  invariants; they do not make the adapters above safe automatically.

## Verification without operating the Mac

Use private build directories, for example:

```sh
swift build --package-path ComputerUseKit --scratch-path /tmp/cu-build --build-tests
swift test --package-path ComputerUseKit --scratch-path /tmp/cu-build --skip-build \
  --filter 'ComputerUseCoreTests|ComputerUseClientTests|ComputerUseSystemTests.AXTests|ComputerUseSystemTests.ActionsBackendCaptureTests|ComputerUseSystemTests.ScreenshotTests|ComputerUseSystemTests.PresenceTests|ComputerUseSystemTests.PermissionsTests'
```

AXTests, ActionsBackendCaptureTests, ScreenshotTests, PresenceTests and
PermissionsTests are specifically audited:
their reads/actions/observer/capture hooks are injected fakes, not live
accessibility or capture operations. The allowlisted subset contains 277 tests
(175 Core, 3 Client, 25 AX, 2 Actions, 22 Screenshot, 14 Presence, 36 Permissions). Inspect tests before expanding
that allowlist. In particular, do **not** run the
whole package merely because most system tests have fakes. `PasteboardTests`
uses the system pasteboard service (even though it creates a unique board),
`EventsTests` builds real CoreGraphics events and resolves private window-server
symbols, and helper tests can take a display-awake assertion and declare user
activity. Compile those tests without executing them when the task
prohibits real app/input/pasteboard/system activity. Fixture passes are not live
helper, accessibility, screenshot, input or device verification.
