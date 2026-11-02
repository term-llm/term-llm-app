# Native logical-turn notification companion

This private companion implements the v2 notification wire/optional bridge
contract. The core server, not this app or relay, decides whether a logical
human turn is complete and eligible. Legacy bridge enrollment remains version 1;
missing or rejected optional capabilities must leave chat/manual enrollment
working but automatic completion targeting disabled.

## Native boundaries

- Web Push authentication selects the enrollment's origin, scope and source ID.
  Shared VAPID keys do not select the last page visited. v2 completion envelopes
  require a scoped authentication secret, matching public source and an in-scope
  URL. Legacy plain title/body remains manual; malformed/unknown versioned
  envelopes cannot become manual notifications.
- Event/turn/response/window/store/session/attention/run/source/expiry metadata
  survives NSE decryption in delivered userInfo. Grouping includes the enrolled
  scope. Manual messages do not acquire completion/read authority.
- `notificationCapabilities()` returns version 2 plus an actual native scene's
  persistent `window_id` and an injected per-load `document_id`. The window ID is
  `native_` + unpadded base64url(SHA256(UTF8(scene persistent identifier))), exactly
  50 core-safe ASCII characters; registration and tap routing use that same
  encoder. Shared `native-identity-contract.json` vectors pin the public boundary.
  Capability requires an attached scene, configured-origin main frame, live nonce,
  and readable/writable shared state/consent resources. Only document **commit**
  invalidates prior binding; failed/cancelled/download provisional navigation
  leaves the still-live document functional. Missing app-group entitlement,
  unknown consent or corrupt state withholds v2 instead of falling back to
  URL/visibility-based eligibility.
- `notificationPresence(payload)` accepts the frontend's existing policy-derived
  presence with exact window/document, monotone sequence and at most 65s lease.
  Both wall-clock and uptime bounds apply. Only the owning foreground scene's
  fresh active lease suppresses foreground completion presentation, including
  when that scene is viewing a different conversation. This never marks read.
- `notificationRead(payload)` is called only **after** a durable authenticated
  server attention ACK (or observed authenticated Hub clear). The main-frame
  bridge validates scope against the actual document and known enrollment
  routes. Native persists the exact origin/scope/store/session sequence before
  removing matching delivered/pending completion requests through that sequence.
  Newer sequences, replacement stores, sibling nodes and manual messages remain.
  A tap/open alone is not an ACK. Pending APNs remote queues are not exposed by
  UserNotifications; the watermark also gates subsequent NSE admission.
- With multiple scenes, taps activate the exact owner scene session, including
  restorable sessions. If gone, UIKit is asked to create a new scene with a
  single-use navigation activity. An arbitrary currently rendered sibling cannot
  consume an unclaimed navigation. Ownerless manual/legacy taps instead use the
  current key scene, waiting for that scene on cold launch, without requesting
  another scene. An activation error (or iOS reusing an existing window) clears the
  exact pending completion and offers **Open Here** for the current key scene; it
  is never substituted there without that explicit choice. Multi-scene creation
  remains **disabled** while voice/listen singleton behavior is unproven. The
  global voice request can be claimed once by its intended key scene.
- In single-scene mode (every current build) UIKit rejects every activation
  request, even for the existing foreground scene (`UISceneErrorDomain` 0, "does
  not support multiple scenes"; observed in the iOS 26.5 simulator). No scene is
  requested there: iOS already brings the only scene forward for the tap, and it
  is the owner or replaces an owner whose session was discarded. Completion taps
  route like manual taps to that scene, binding to it while it is still in the
  background, or waiting for it to attach on cold launch. There is no sibling to
  exclude. Scene activation/restoration remains a simulator/device release gate.

## Durable opt-out and cleanup

The app and NSE share `group.com.termllm.app.shared`. Both app IDs/provisioning
profiles must enable this Application Group in addition to the existing shared
keychain group. No production signing/profile changes were made here.

A stable-inode locked file and atomic replacement serialize replay/read/cleanup
state. An independent **authoritative consent journal** uses a separate account
in the existing shared keychain (no private default-group fallback). The app saves
an explicit pending preference request locally, commits the shared journal first,
then mirrors it into the app-group file. A failed mirror cannot overwrite off on
restart; a failed keychain write rejects the operation and retains the local retry
marker. Startup reconciles that request before importing any old enabled state.
Before an enable clears previous off, that off is mirrored so its cleanup handles
cannot disappear; failure leaves enable pending/rejected. Cached enrollments
recovered from off remain retired until authenticated cleanup instead of silently
reactivating on enable. Legacy explicit off is conservatively imported when
establishing the journal.
These records contain consent/cleanup/read identity, not notification text or
credentials. Bridge disable/unsubscribe rejects persistence failure rather than
resolving true. If both persistence paths are unavailable, durable local off cannot
be promised: the failure is surfaced and iOS Settings remains the OS-level block.
Explicit enable alone clears off. Consent-generation fencing still rejects stale
relay responses; returned endpoints survive enrollment/disable races.

`notificationEnrollment({source,subscription_id})` records successful/verified
server enrollment. `notificationPendingCleanup({source})` exposes retained IDs;
`notificationCleanupAcknowledged({source,subscription_id})` consumes only that
exact handle after authenticated server DELETE success. Frontend drains these
on authenticated reconnect. Old endpoint-only handles and unopened/offline nodes
remain pending rather than being discarded or treated as remotely revoked.
The native toggle cannot authenticate an arbitrary unloaded node and does **not**
revoke iOS permission. Settings shows pending cleanup/storage limitations.

Missing or unknown consent is **not** automatic permission: completion delivery
and v2 capability remain fail-closed. Recognized manual/legacy content preserves
compatibility before first post-upgrade launch or with a missing app-group
container when there is no established off; a readable explicit journal off is
always respected even without that container. A readable journal can authorize
manual presentation during mirror/lock failure, without claiming replay durability.
A locked/corrupt existing file with no readable journal, or an unreadable shared
keychain that might hide off, is quieted rather than guessed. Unsupported or
unclassified envelopes never use manual compatibility. Old UserDefaults-only
intent becomes shared on the first upgraded app launch; an NSE cannot read that
private legacy store beforehand. OS Settings is the only universal pre-launch
block. No relay revocation database or new service is introduced.

## Replay and unavoidable platform limits

The persistent arrival ledger retains at most 4096 scoped event IDs for 24h.
At saturation it quiets additional events rather than evicting unexpired replay
protection. Read watermarks and cleanup handles are separately bounded at 4096.
Failed/corrupt reads do not reset the ledger or consent state silently. Independent
store instances use `LOCK_EX | LOCK_NB` on a stable inode, at most 40 attempts with
5ms backoff (under 200ms deliberate waiting, not an OS-I/O deadline). A suspended
app cannot make the NSE wait on a blocking flock until extension expiry. Lock
exhaustion is explicit unavailable state; it never fails open for completion.
Data replacement never replaces the lock file. Fault-injection XCTest covers
shared writes, journal writes, restart/recovery and a held lock; those tests remain
unexecuted here. Real app/NSE multi-process/device proof remains necessary.

Enrollment cleanup is bounded at 4096 retained generations. Nonpending old
endpoint generations may still consume that capacity; only authenticated cleanup
ACK is proof they can be discarded. No speculative age-pruning or pending-handle
eviction was added. Saturation surfaces a storage/capability error and may require
authenticated node cleanup; it is not successful remote retirement.

The NSE **cannot cancel an alert remote push**. Suppressed/replayed/read/disabled
arrivals are quieted and redacted while preserving metadata; iOS can still leave
a quiet/empty card, and extension expiry/non-execution may show the relay's
placeholder. NSE expiry callbacks complete at most once under a process lock.
Server-side unsubscribe/outbox suppression and iOS permission remain important.
Do not describe this as exactly-once or silent suppression of all remote pushes.
Pre-upgrade delivered cards lacking exact store/sequence/scope metadata are not
cleared by URL guessing. NSE admission and the OS inbox snapshot are not one
atomic transaction: already-admitted/background content can race a later read
ACK/removal. Subsequent foreground presentation, exact read clearing and future
NSE admission honor the persisted watermark; immediate device-wide removal is
not promised.
Legacy envelopes without an event ID lack replay identity.

Relay `apns-id` is a deterministic UUID for verified destination/environment/
VAPID key + nonempty event-scoped Topic. Newly encrypted retries keep that ID;
different events or destinations do not share it. Without Topic the legacy/manual
request still gets a fresh UUID. This is diagnostic correlation, not an APNs
idempotency promise. Topic/collapse, replay state, and read clearing do different
jobs; a lost provider acceptance ACK can still cause multiple deliveries.

## Verification in this workstream

Run from the repository root:

```sh
python3 scripts/check-notification-contract.py
# With disposable HOME/XDG/TMPDIR/GOCACHE and existing read-only module cache:
(cd push-relay && go test -count=1 ./...)
(cd push-relay && go test -race -count=1 ./...)
(cd push-relay && go build ./...)
(cd push-relay && go vet ./...)
git diff --check
```

The structural script parses entitlement plists/Xcode source memberships and runs
actual injected bridge JavaScript in an offline Node VM with fake message handlers.
It is **not** Swift compilation, native XCTest, a browser/device run, or proof of
signing. Relay tests use recording fakes and loopback fake HTTP/2 APNs only,
including actual webpush-go encryption, newly encrypted retry IDs, v2 completion
and manual transport, existing routing/source-tag vectors, limits and error paths.

Added/updated native tests use temporary files/UserDefaults, in-memory identity
storage, fake inbox/authorizer/relay/scene activation. They cover metadata retention,
shared-VAPID routes, expiry/replay/capacity/concurrency, exact read races, durable
off/unloaded-node cleanup, late consent/enrollment responses, stale presence and
owner-gone activity claims. They were **written but not executed** on Linux:
no Swift, Xcode, XCTest, signing or iOS device is available. The test-only
`TermLLMTests/ProducerFixtures` bundle now pins exact actual-core-producer exports
(primary/compact completion and manual), manifest hashes/clocks and original
provenance README from public review `600d7199e30375758fefba7a0e57a4ae72f9a923`
(production implementation `7f8b8251d0370fe7f475925b50ad7f46a8a697a2`).
`ActualProducerFixtureTests` encrypts those unmodified bytes for the native
receiver, checks delivered metadata and primary/compact agreement, and explicitly
injects the manifest clock into read/replay/expiry tests. The actual manual
producer lifetime remains **60 seconds**; no timestamp is rewritten. These native
tests are still unexecuted here. The offline script verifies bytes/provenance,
clock windows, Unicode body and test-only resource membership. The relay's
`TestActualProducerFixturesThroughRelay` additionally verifies byte-for-byte
export preservation through actual WebPush encryption, the real relay and fake
APNs; it is not native execution. The public workstream owns producer-to-worker
execution evidence.

Before release, run the focused suites on a disposable simulator (not the opt-in
live E2E suite): `PushCenterTests`, `PushMessageTests`, `PushDeliveryStoreTests`,
`NotificationMetadataTests`, `NativeNotificationLifecycleTests`, `ActualProducerFixtureTests`,
`NotificationReviewRegressionTests`, `WebPushCryptoTests`,
and affected browser lifecycle tests. Then explicitly authorize device acceptance
for two scenes/nodes sharing VAPID, owner-closed taps, app/NSE concurrent arrival,
background off/expiry, and authenticated offline cleanup retry. No live enrollment,
APNs send, service/config/state change, deployment, push or PR was performed here.


## Pending macOS CI verification (not invoked)

The shared TermLLM scheme builds the app plus embedded extension and the XCTest
bundle. `.github/workflows/native-notification-tests.yml` adds a narrowly scoped
manual-only workflow-dispatch self-hosted MacBook simulator job (no PR trigger),
read-only contents permission, pinned
checkout without persisted credentials, no secrets or signing, and a 30-minute
job bound. It chooses an already available iPhone/iOS >=17 deterministically from
`xcrun simctl` JSON; it never provisions a runtime/device. `xcodebuild test` uses
`CODE_SIGNING_ALLOWED=NO`, focuses the notification/browser/voice unit suites and
excludes opt-in live E2E tests. Logs stream to the job output; temporary build
results are cleaned locally, with no GitHub artifact upload or Actions cache.
The selector has executable offline Python tests. Workflow policy/YAML was checked
offline, but **the workflow, Xcode build and native tests have not run**. Parent
must inspect actual CI after review clearance/PR publication before treating this
as native compile or XCTest evidence. No dispatch/publication was performed.

Timestamp review clarification: the floating-point 24h rejection allegation was
retracted after counter-checking; no +1-second tolerance was introduced. Fraction
parsing is defensively normalized for 1/2/3/9 digits at millisecond precision.
Actual producer fixtures and derived strict 24h/+1ms/zero-lifetime XCTest cases
are included; variable-fraction Foundation behavior is unverified until native CI.
