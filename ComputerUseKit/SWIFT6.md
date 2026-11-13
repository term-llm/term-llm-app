# Swift 6 ownership migration

`TermLLMMacKit` and the Xcode `TermLLMComputerUse` / `TermLLMComputerCLI`
entry-point targets use Swift 6. ComputerUseKit now uses Swift 6 for every library
and test target, with explicit per-target settings retained for clarity:

| Target | Language mode |
| --- | --- |
| `ComputerUseClient` | Swift 6 |
| `ComputerUseClientTests` | Swift 6 |
| `ComputerUseCoreTests` | Swift 6 |
| `ComputerUseCore` | Swift 6 |
| `ComputerUseSystem`, `ComputerUseSystemTests` | Swift 6 |
| `ComputerUseHelper`, `ComputerUseHelperTests` | Swift 6 |

All targets use the Swift 6 toolchain and a macOS 14 minimum. The rounds below
record how the temporary Swift 5 boundaries were removed without declaring whole
mutable dependency graphs unchecked. Compiler checking does not establish live
SDK, permission, target-app or device behavior; those limits remain explicit.

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
also passed isolated Swift 6 typechecks with warnings as errors before the rest
of the System module's migration. No unchecked
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

## Fifth incremental round: shared SDK and main-loop infrastructure

The single HID event source is retained with its existing identity and nil-source
behavior, behind a private synchronized owner that serializes source-backed event
construction. `PrivateSymbols` is checked Sendable with immutable library ownership
and a typed hit/miss cache. A missing symbol is published before logging outside
the cache lock, so a logger can reenter without repeated lookup or warning. The
injected resolver must not reenter the cache; the default is synchronous `dlsym`.
Libraries remain loaded because returned function pointers can outlive the cache.

Two narrow SDK exceptions remain explicit: the private HID source owner, and an
immutable opaque library/code address wrapper. Neither exposes mutable Swift
storage or introduces a blanket adapter conformance. `MainThread.run` now requires
an explicitly Sendable main-actor startup callback; run-loop scheduling, inline
fallback and shutdown are unchanged.

Opus found no defects. Its optional singleflight-test strengthening was applied.
The 285-test allowlist passes normally and under TSan, scoped sources/tests pass
isolated Swift 6 warnings-as-errors checking, and Mac app/test compilation passes.
Seven new symbol-cache tests use fabricated addresses and fake resolvers only.
Existing event-building tests compile but are not executed; the inline MainThread
test starts no AppKit loop. No events are posted and no UI/tap/permission operation
is exercised. Actual SDK event-source concurrency remains a documented boundary,
not something the fabricated-address tests establish.

## Sixth incremental round: approval ownership and turn lifecycle

`Approvals` now has checked Sendable conformance, immutable Sendable hooks and
separate typed ownership for question state and same-instance persistence commits.
An ordered, reentrant effect drain calls enqueue-only UI hooks outside the state
lock. Liveness probes also run outside locks; session revisions reject stale
samples before serialized read/modify/write. `ApprovalStore` is checked Sendable
for immutable URL ownership, not a cross-instance/process filesystem transaction.
Persistent-write failures still leave the session grant in place.

Stop publishes cancellation before invoking an executor retirement hook outside
the server condition. Cancelled waits and already-returned pending questions are
retired without consuming newer replacements. Normal non-cancelling turn end only
clears denials: existing waits and questions remain answerable. New turns,
cancelling ends and agent exit retire stale questions and prune generation state.
The default executor hook is a no-op for other implementations.

Opus rechecked the lifecycle fixes and found no merge blockers. One pre-existing
window remains: a call admitted before Stop but reaching `ensure` afterwards can
create an answerable prompt before observing abandonment. Stop retires existing
questions, not future calls; an explicit click is still required. Tightening this
admission/registration boundary is a separate follow-up. Non-empty server Stop
key selection is inspected structurally, not exercised through live socket tools.

The audited subset contains 335 tests, including 41 Approvals tests and seven
standalone Helper lifecycle tests. Normal and TSan runs and Mac app/test
compilation pass. Scoped approval sources/tests pass isolated Swift 6
warnings-as-errors checks. Negative controls reproduce the original Stop and
normal-turn regressions. Lifecycle tests never start a server or execute socket
tools; no real UI, input, AX, pasteboard or power assertion is exercised.

## Seventh incremental round: Person input and tap ownership

`Person` now has checked Sendable conformance and immutable System/Hooks values.
Worker-visible input state uses typed snapshots and a short state lock; clocks,
input fallbacks and callbacks remain outside it. Only event-tap/source creation,
installation, enabling and removal belong to a main-actor owner. The listen-only
C callback copies fields before delivery and never suppresses or modifies input.
Generation claims reject stale starts, and queued cleanup retains the resource
until removal; a debug assertion checks the live handle's teardown invariant.

Opus cleared the implementation and its test/comment follow-ups. The 38 Person
tests include fake lifecycle/reentrant teardown, stale input samples, human-first
gating and two-driver quiet-timer coverage. They pass normally and under TSan;
scoped strict Swift 6 checks also pass. Runtime and Focus deliberately retain the
same Person.shared composition. No live tap, permission query or actual
main-loop teardown has been verified.

One nonblocking projection follow-up remains: paused/loading hooks execute outside
the state lock and concurrent delivery can show an older overlay message after a
newer one (including after turnDone). Actual input gating and human priority are
unaffected; ordering needs a focused Presence handoff design, not callbacks under
the Person state lock.

## Eighth incremental round: Apps, Focus and Windows ownership

All three adapters have checked Sendable conformance and immutable dependency
snapshots. Apps keeps caches and pending catalog ownership under a typed lock,
with query callbacks and waits outside it. Focus separates per-enforcer belief
state from the existing physical-input execution lock. Human-priority bringBack
and leak polling intentionally remain independent of that execution lock, so a
long action in another app cannot prevent restoration. Arbitrary worker hops
capture the caller's AX backend explicitly.

Windows separates menu generations from attention delivery. AX callbacks only
record and signal; queued attention survives retirement and observer uninstall,
is claimed once, and flushes off-main with the original backend. Menu waits
reacquire the current generation after unwatch/rewatch. Observation registration,
teardown and injected callbacks do not hold registry state locks.

Opus's Focus restoration blocker and its three other findings were fixed and
rechecked clear. On the integrated tree, the 442-test audited allowlist passes
normally and under TSan, and Mac app/helper/test compilation passes. Focus's
previously blocked primary-file Swift 6 warnings-as-errors check now passes with
the migrated symbol cache and Person dependencies. This is fake-only evidence:
actual app focus, WindowServer attention and native observer delivery remain
unverified. Existing event-oriented Focus tests are compile-only.

## Ninth incremental round: native pasteboard ownership

`Pasteboard`, its immutable Backend and LazyPasteData have checked Sendable
conformance. A private main-actor owner contains the native pasteboard handle;
native operations and rich conversion alone cross the synchronous main boundary.
Fake hooks run inline on their caller. A worker without a running loop fails
closed without accessing the general board. Receipt state is typed and locked;
wait predicates stay synchronous and nonescaping, so operation-local landed state
is not transferred to another worker.

Opus cleared the candidate and its follow-ups. The 24 new pure tests cover
transaction serialization, conflict/error precedence, promised-data receipts and
recovery protections. Existing live tests compile only. Provider threading,
native HTML conversion and real promised-data delivery remain unverified.
Transactions require a stable, servicing main loop; startup recovery precedes
workers and shutdown recovery follows their drain. Native unavailability currently
maps restore to false and deletes recovery state; a distinct unavailable status
is a tracked follow-up if that lifecycle contract changes. The provider check is
debug-only, not a new release-build crash.

## Tenth incremental round: Actions, Policy and Instructions dependencies

`Actions` stores an immutable checked-Sendable System snapshot with explicit
Sendable callbacks. Menu workers capture only the caller's backend, element,
action and typed completion box. One completion/error snapshot prevents a late
failure from being mistaken for success. Runtime rebuilds Actions from its
configured builder, retaining the same clipboard recovery instance and policy.
Six new pure tests cover parallel callers, backend capture, reentrancy and late
completion; completion assertions use deterministic joins rather than a real-time
0.25-second scheduling assumption. Event-building tests remain compile-only.

`Policy` is checked Sendable with immutable URLs and a Sendable appKind callback;
its value configuration types are also checked. Files still reload on every call,
with the same defaults and fail-closed errors. Two new Core tests cover concurrent
configured-policy callbacks and reentrant loads. No default-policy substitution
is used to satisfy Runtime's callback contract.

`Instructions` is a Sendable value with a Sendable directory hook. Files are read
outside the agent lock, followed by an atomic once-per-bundle claim. This prevents
duplicate prefixes from concurrent readers; the old insertion accessor already
protected marks for other bundles. Two new tests reproduce the duplicate against
the old implementation and cover callback reentrancy. Its eight existing tests
are also audited file-only tests. Opus cleared all three dependency candidates.

## Eleventh incremental round: System language mode and fixtures

System and SystemTests now compile in Swift 6; Helper and HelperTests remain
explicitly Swift 5. Settle callbacks capture typed boxes instead of mutable
locals/test cases; live PasteboardTests owns its setup/teardown state in a
main-actor fixture without touching the clipboard during test discovery. Test
names, assertions and excluded-suite behavior are preserved.

The integrated allowlist contains 497 tests (179 Core, 3 Client, 308 System and
7 standalone Helper lifecycle tests). Normal and TSan runs pass, including all
13 now-audited fake Settle tests; Mac app/helper/test compilation passes with the
new language modes. The System source and scoped fixtures pass warnings-as-errors
checks; whole-fixture warnings-as-errors still reports an existing AXTests cast
warning. No live pasteboard/event/unsafe Helper suites were run. Opus found no
code defects in the mode/fixture delta; its Settle execution gap was closed with
normal and TSan runs before integration sign-off.

## Twelfth incremental round: Core model and app-session ownership

WindowRef, Line, Capture, Revisions and AppSession now have checked Sendable
conformances with typed lock-owned state. Reference identity and existing
synchronous APIs are retained. Revisions separates short state locking from
per-instance numbering/refetch execution ownership; observation callbacks only
record into their own generation. Observe, stop, equality, liveness, rereads,
cancellation callbacks and displaced-object release stay outside state locks.

Property access and shallow snapshots are not logical transactions. The canonical
app FIFO still owns coordinated reads, rendering, actions and lifecycle changes;
callers must not mutate captures/lines during presentation or refetch. A PID-only
watch change no longer prevents a numbered capture from committing; reset and
superseding presentation/refetch versions still invalidate stale commits.
AppSession.cancel now requires a Sendable closure: copy immutable captures or use
synchronized state, and never retain the request's heterogeneous arguments.

Opus cleared the implementation and follow-ups. Twenty-two pure ownership tests
cover shared identity, concurrent fields, reentrant lifetime operations, stale
watch/resolve results, exact stale errors, and footer-format parity. Core goldens
remain unchanged. Real SDK observation and concurrent target-app behavior remain
unverified.

## Thirteenth incremental round: process/session sampling

Sessions and ProcessIdentity are checked Sendable. The immutable process provider
runs outside registry locks. Per-entry revisions reject stale environment and
wrapper updates, with no retry/join loop around reentrant providers. Separate
session/shell tombstones prevent same-key resurrection without falsely exiting an
unrelated live or explicitly named session. Lookup epochs are released on every
path; tombstones prune as the oldest active epoch advances and clear when no
lookup remains. A stalled oldest provider can extend retention; there is no
absolute memory-bound claim.

Opus reproduced and blocked the first global-retirement fence, then cleared the
per-key fix and its final fallback hardening. Its independent parallel/reentrant
stress runs observed no false exits or live reaping. Thirty-four new pure tests
cover identity, Stop/turn state, wrapper orphans, stale samples and epoch cleanup.
Superseded calls do not overwrite a newer environment snapshot; request consumers
should use their per-call environment rather than assuming agent.env is the last
writer's request. Real process lookup is not exercised by these fixtures.

## Fourteenth incremental round: executor and FIFO contracts

ToolExecutor, ToolOutcome, HarnessExecutor and its dependency values now have
checked Sendable contracts. ToolCallRequest remains deliberately operation-local
and non-Sendable: its heterogeneous arguments are constructed and executed on the
receiving worker. Escaping cancellation/queue entry hooks are Sendable, while
queue work stays synchronous and nonescaping.

The executor registry owns a typed graph of checked AppSessions and preserves
insertion order. Cleanup retires an entry only if it is still the snapshotted
session, so stale A1 cleanup cannot unregister replacement A2. Snapshot retention
can defer deinit beyond the cleanup loop and app FIFO, always outside registry
locks. Waiting FIFO abandonment callbacks now execute outside the condition;
tickets retain arrival order and cancelled waiters cannot strand later callers.

Opus cleared these changes and the identity/order follow-ups. Seven new pure
executor tests and the existing isolated FIFO arrival/cancellation method pass.
The integrated allowlist is now 561 tests (201 Core, 3 Client, 308 System and
49 Helper), passing normally and under TSan; Mac app/helper/test compilation also
passes. Only that single audited HelperTests method runs; the rest of HelperTests
and all HarnessExecutorTests remain compile-only pending fixture migration.

## Fifteenth incremental round: Helper source and lifecycle ownership

HelperConfiguration, HelperServer, HelperLog and DisplayAwake now have checked
Sendable ownership. Configuration is a value-builder snapshot; callback graphs
must uphold their Sendable contracts. Typed server state and its condition
coordinate admission, workers and resources. Startup, descriptor operations and
pause persistence have distinct execution gates; no process provider, UI hook or
filesystem wait holds the short bookkeeping state lock.

Admission samples processes outside bookkeeping locks and revalidates before
enrollment. Refusal during shutdown preserves the retryable `stopping` wire error;
only a refused, effect-free admission uses that reply. Running-call cancellations
remain non-retryable. Lifecycle calls (help, skill, turn-started, turn-ended) retain
their Stop exemption but never bypass shutdown refusal. Stop publishes Sessions
marks while holding the condition, after storage unlock, then calls the executor
outside both locks.

Working effects drain in order outside locks. Shutdown callbacks are synchronized,
claimed once, and invoked after resource release; replaced captures retire outside
locks. Worker-context shutdown cannot self-join. Startup abort teardown runs on a
worker while AppKit continues servicing, and only then stops the loop. Main-actor
timer ownership preserves the runtime's existing configured composition.

Opus found and blocked the first admission retry/lifecycle regressions, then
cleared their fixes and the startup/Stop ordering follow-ups. Twenty pure server
tests cover admission, callbacks, lifecycle exemptions and drain behavior. Fresh
strict-source build evidence records the command, effective flags and exit status.
Startup/flock/socket rollback, persistence failures, descriptor reuse and actual
power assertions remain compile/source-inspection-only. Admission finish-once is
an internal caller convention; production uses defer.

## Sixteenth incremental round: Helper fixtures and completed mode switch

HelperTests now also compiles in Swift 6. Typed fixture worlds and boxes replace
Sendable callbacks capturing XCTest cases or mutable locals; dynamic callback
configuration and shared model identity are preserved. The fixture-only migration
retains all 54 existing test names and 297 assertion sites. Teardown guards partial
setup and restores AX/breaks callback cycles in defer. Actions.Target gains checked
Sendable conformance now that its Line payload is checked.

Opus cleared the fixture migration and its capture/teardown follow-ups. Three
new pure fixture tests exercise synchronized storage and capture retirement.
The final audited allowlist contains 584 tests: 201 Core, 3 Client, 308 System and
72 Helper. It passes normally and under TSan with the sanitizer runtime linked;
all package test targets compile in Swift 6. All library products also pass
complete-concurrency checking with warnings as errors. Native Mac app/helper/CLI
and test compilation passes unsigned. The only ordinary test-build warning is an
existing AXTests unsafeBitCast suggestion.

These are not live UI/device results. The hazardous Helper/Harness suites, real
event-building suites and live pasteboard suite remain compile-only; only the
explicitly audited FIFO method from HelperTests executes. Startup, permissions,
real focus/input, clipboard delivery, Keychain and physical-device behavior are
not established by these fixtures.

## Remaining focused follow-ups

- Tighten the pre-existing Stop-to-approval registration window and order
  paused/loading/done overlay projections without callbacks under state locks.
- Give native clipboard restoration a distinct unavailable status if the stable
  main-loop lifecycle contract changes, preserving recovery state in that case.
- Validate the documented native SDK/lifecycle boundaries on an explicitly
  authorized live helper/device; fake fixtures are not a substitute.

Preserve per-app FIFO ordering, human-input priority, cancellation cleanup and the
helper's servicing main loop. Avoid broad actor rewrites or global serialization.

## Ownership decisions retained by the completed migration

The initial migration compiled after adding `@unchecked Sendable` to the system
adapters and helper server. That would promise more than their APIs guarantee:

- Adapters and executor graphs use checked Sendable values, immutable dependency
  snapshots and explicit callback contracts, not blanket unchecked conformances.
- Stateful services use typed ownership with callbacks, SDK teardown and retained
  capture release outside short state locks. Execution/persistence gates are
  separate where a whole synchronous operation must remain coherent.
- Native UI/tap/clipboard resources have explicit main-thread ownership; ordinary
  target-app IPC remains on its worker, and per-app operations stay independent.

The migration includes the corresponding fakes rather than merely importing
legacy unchecked modules. Preserve these boundaries: do not restore blanket
unchecked conformances, `@preconcurrency` imports or unsafe compiler flags to
silence future ownership errors.

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
swift build --package-path ComputerUseKit --scratch-path output/cu-build --build-tests
swift test --package-path ComputerUseKit --scratch-path output/cu-build --skip-build \
  --filter 'ComputerUseCoreTests|ComputerUseClientTests|ComputerUseSystemTests.AXTests|ComputerUseSystemTests.ActionsBackendCaptureTests|ComputerUseSystemTests.ScreenshotTests|ComputerUseSystemTests.PresenceTests|ComputerUseSystemTests.PermissionsTests|ComputerUseSystemTests.PrivateSymbolsTests|ComputerUseSystemTests.SystemTests|ComputerUseSystemTests.ApprovalsTests|ComputerUseSystemTests.PersonTests|ComputerUseSystemTests.PersonOwnershipTests|ComputerUseSystemTests.AppsTests|ComputerUseSystemTests.AppsOwnershipTests|ComputerUseSystemTests.FocusOwnershipTests|ComputerUseSystemTests.WindowsTests|ComputerUseSystemTests.WindowsOwnershipTests|ComputerUseSystemTests.ContextPrivateCallsTests|ComputerUseSystemTests.PurePasteboardOwnershipTests|ComputerUseSystemTests.PureActionsOwnershipTests|ComputerUseSystemTests.InstructionsTests|ComputerUseSystemTests.InstructionsOwnershipTests|ComputerUseSystemTests.SettleTests|ComputerUseHelperTests.ApprovalLifecycleTests|ComputerUseHelperTests.PureSessionsOwnershipTests|ComputerUseHelperTests.PureExecutorOwnershipTests|ComputerUseHelperTests.PureServerOwnershipTests|ComputerUseHelperTests.PureFixtureOwnershipTests|ComputerUseHelperTests.HelperTests/testFIFOArrivalOrderAndCancellation$'
```

AXTests, ActionsBackendCaptureTests, ScreenshotTests, PresenceTests,
PermissionsTests, PrivateSymbolsTests, ApprovalsTests, ApprovalLifecycleTests and
the inline SystemTests are specifically audited: their reads/actions/observer/
capture/UI hooks are injected fakes, not live accessibility or capture operations.
The allowlisted subset contains 584 tests (201 Core, 3 Client, 308 System and
72 Helper tests: 7 approval lifecycle, 34 pure Sessions, 7 pure executor,
20 pure server, 3 pure fixture and exactly one FIFO arrival/cancellation method). The System subset additionally includes
38 Person, 22 Apps, 8 Focus ownership, 35 Windows, 4 injected private-call,
24 pure Pasteboard, 6 pure Actions, 10 Instructions and 13 Settle tests.
These use inert/fail-fast system hooks; event-oriented FocusTests remain
compile-only. Inspect tests before expanding
that allowlist. In particular, do **not** run the
whole package merely because most system tests have fakes. `PasteboardTests`
uses the system pasteboard service (even though it creates a unique board),
`EventsTests` builds real CoreGraphics events and resolves private window-server
symbols, and helper tests can take a display-awake assertion and declare user
activity. Compile those tests without executing them when the task
prohibits real app/input/pasteboard/system activity. Fixture passes are not live
helper, accessibility, screenshot, input or device verification.
