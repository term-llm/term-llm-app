# Read pipeline integration

Ported from macos-harness `43d9edf`. Implementation is Foundation-only, in
`ComputerUseCore`; there are no new dependencies or library resources.

## Public entry points

```swift
Tree.read(_ target: AppTarget, _ window: WindowRef, _ kind: AppKind,
          menu: UIElementRef? = nil) throws -> Capture
Tree.enable(_ target: AppTarget, _ kind: AppKind) -> Bool
Tree.disable(_ target: AppTarget)
Tree.disableAll()
Tree.askOnce(_ element: UIElementRef, limit: Int = Tree.firstAskLimit,
             clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
             sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws
Tree.printedText(_ element: UIElementRef) throws -> (String, [Int]?)

Revisions.init()
Revisions.present(_ capture: Capture, disableDiff: Bool = false) -> String
Revisions.resolve(_ index: Int, reread: () throws -> Capture,
                  ignoreValue: Bool = false) throws -> Line
Revisions.watch(_ target: AppTarget) throws
Revisions.reset()
Revisions.last: Capture? // public read-only

AppSession.init(agent: AgentSession, target: AppTarget)

Prune.run(_ root: Node, _ context: Context) -> Node
Render.header(_ title: String, _ appName: String) -> String
Render.lines(_ root: Node, _ context: Context, depth: Int = 0) -> [Line]
Render.shortenURLs(_ lines: [Line])
Render.footer(_ capture: Capture, _ numbered: Bool) -> String

RichText.Run = (text: String, style: [String: Any])
RichText.markdown(_ runs: [RichText.Run]) throws -> (String, [Int])
RichText.find(_ text: String, _ offsets: [Int]?, _ target: String,
              prefix: String = "", suffix: String = "") -> (Int, Int)?
RichText.isDocsHost(_ host: String) -> Bool

Diff.pair<Key: Equatable>(_ old: [Line], _ new: [Line],
                         key: (Line) -> Key) -> [Change]
Diff.text(_ changes: [Change], _ title: String, _ footer: String,
          _ budget: Int) -> String?
Diff.line(_ node: Line) -> String
Diff.ranges<S: Sequence>(_ ids: S) -> String where S.Element == Int
```

Targets passed to tree reading/switching/watching must represent running apps.
Install `AX.backend` before use. Session mutation/presentation/resolution belongs
under the helper's per-app/session lock, as in Python; only notification storage
and the global accessibility switches have their own internal locks.

`AppSession` has `agent`, `target`, `active`, `needsSettle`, `revisions: Revisions?`,
`shot: Shot?`, `pageUnchecked`, `cancel: () -> Bool`, and `watching: AppTarget?`.

`Node` and `Context`, individual prune passes, and render/tree conversion helpers
are public for mechanical integration and focused tests. Ordered actions use the
shared contract's `[(label: String, action: String)]`, not a Swift Dictionary.
Rich-text offsets and cuts use Unicode scalar indices (Python code points), not
Swift grapheme counts or NSString UTF-16 offsets. `find` returns `(start, end)`,
not `(location, length)`; convert that pair before passing an AX range.

## Shared contract change

The only base-file edit is additive in `AX.swift`:

```swift
func subtree(_ element: UIElementRef, _ names: [String],
             maxChildren: Int) -> [(UIElementRef, [Any?])]?
```

A public protocol extension returns `nil` by default, so existing backends keep
working. This ports the optional hierarchy-copy optimization and its fallback;
backends must preserve the requested attribute order. No private API is enabled
by Core. In particular, the system backend can retain upstream's disabled-copy
policy and simply inherit the default.

`AXAttributedStringForRange` is called with `NSRange` at the seam. Wrapping it as
an AXValue belongs to the system backend, not Core. `askOnce` injects its clock,
sleeper and visit limit instead of requiring test monkeypatching of globals.
Intermediate title-node links are cleared after pruning inside `Tree.read` to
avoid Swift retain cycles; this doesn't affect captures or printed output.

## Verification and test adaptations

- Five `Fixtures/trees/*.json` goldens are compared as UTF-8 Data, through the
  same read/number/render/footer path as `tests/fakes_b.py` / `test_tree.py`.
- All eleven `Fixtures/diffs/*.txt` chains (39 reads) replay through Revisions.
- Logic from `test_tree.py`, `test_prune.py`, `test_render.py`, `test_diff.py`,
  `test_elements.py`, and `test_richtext.py` is grouped into Swift XCTest methods;
  parameterized cases are loops rather than separately counted tests.
- Extra regressions cover scalar cuts/offsets, non-normalizing text/key equality,
  Python whitespace and regex behavior, Bool/Int/Double distinctions, ordered
  action replacement, release order, and failure suppression boundaries.
- No live-app tests from these six files were skipped. The file-reference test
  uses a temporary file and Foundation/CFURL, without Accessibility permissions.
- Python-only dynamic shape checks (`hasattr` for absent module functions/fields)
  are represented by Swift's typed API and applicable reflection checks. The
  Python-only diff-budget branch that assigns `depth=None` and expects TypeError
  cannot be represented by the shared contract's nonoptional `Int` depth. The
  early budget-return assertion is covered with exact cost boundaries and
  unnumbered removed lines (whose IDs must not be required before the budget
  check). Negative depths retain Python's zero-tab repetition behavior.
- The attributed-range test asserts `NSRange` at the AX seam, rather than a
  PyObjC `AXValueRef`; the system wrapper must test its own AXValue conversion.

Run `cd ComputerUseKit && swift build && swift test`. At completion: 109 Core
XCTest cases (106 new), one System and one Helper case: 111 total, zero failures
or skips. These are fixture/unit results, not verification against a live app.
