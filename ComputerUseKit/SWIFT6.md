# Swift language-mode boundary

`TermLLMMacKit` and the Xcode `TermLLMComputerUse` / `TermLLMComputerCLI`
entry-point targets use Swift 6. **ComputerUseKit explicitly remains in Swift 5
language mode**, using the Swift 6 toolchain and a macOS 14 minimum (matching its
host app). This is a deliberate, temporary compatibility boundary, not a claim
that the helper's worker architecture is fully checked by Swift 6.

## Why not enable Swift 6 yet?

The initial migration compiled after adding `@unchecked Sendable` to the system
adapters and helper server. That would promise more than their APIs guarantee:

- `Apps`, `Focus`, `Windows`, and `Person` expose mutable `system` / `hooks`
  properties. Their callback captures are not `@Sendable`; locking a cache does
  not make those captures safe. `Person` additionally owns a main-run-loop event
  tap and worker-visible state whose lifecycle needs explicit isolation.
- `Presence`, `Approvals`, and `Screenshot` have non-Sendable injected callbacks.
  A `let` closure is not proof that the objects it captures are synchronized.
- `HelperServer` captures a `ToolExecutor`, configuration callbacks, and
  `Sessions` on socket workers. Its condition protects server bookkeeping, not
  the complete executor/dependency graph or externally assigned `onShutdown`.
- `AXBackend` / `AXObservation` expose heterogeneous values and callbacks without
  a Sendable contract. Locking replacement of `AX.backend` only protects the
  backend reference, not every backend implementation or fake.

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
  --filter 'ComputerUseCoreTests|ComputerUseClientTests'
```

Inspect tests before expanding that allowlist. In particular, do **not** run the
whole package merely because most system tests have fakes. `PasteboardTests`
uses the system pasteboard service (even though it creates a unique board),
`EventsTests` builds real CoreGraphics events and resolves private window-server
symbols, and helper tests can take a display-awake assertion and declare user
activity. Compile those tests without executing them when the task
prohibits real app/input/pasteboard/system activity. Fixture passes are not live
helper, accessibility, screenshot, input or device verification.
