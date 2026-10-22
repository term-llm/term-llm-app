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
  persistent `window_id` and an injected per-load `document_id`. It requires an
  attached scene, current authenticated-origin main frame, live document nonce,
  and readable/writable shared app-group state. Navigation invalidates prior
  local attendance. Missing app-group entitlement/container or corrupt state
  withholds v2 instead of falling back to URL/visibility-based eligibility.
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
- Taps activate the exact owner scene session, including restorable sessions.
  If gone, UIKit is asked to create a new scene with a single-use navigation
  activity. An arbitrary currently rendered sibling cannot consume an unclaimed
  navigation. Multiple native scenes and the activity type are declared in the
  app manifest. Scene creation/restoration on supported devices needs device
  verification; there is no arbitrary-sibling fallback if activation fails.

## Durable opt-out and cleanup

The app and NSE share `group.com.termllm.app.shared`. Both app IDs/provisioning
profiles must enable this Application Group in addition to the existing shared
keychain group. No production signing/profile changes were made here.

A separately locked file and atomic replacement serialize app/NSE state. It
contains preference, cleanup handles, read watermarks and replay identity—not
notification text or credentials. Successful shared preference writes precede
legacy app preference updates. The app-wide and per-scope off state gates native
presentation independently of the web page; explicit enable alone changes off.
An enrollment-generation check rejects relay responses from a prior consent
state. Already returned endpoints are retained if server enrollment/disable race.

`notificationEnrollment({source,subscription_id})` records successful/verified
server enrollment. `notificationPendingCleanup({source})` exposes retained IDs;
`notificationCleanupAcknowledged({source,subscription_id})` consumes only that
exact handle after authenticated server DELETE success. Frontend drains these
on authenticated reconnect. Old endpoint-only handles and unopened/offline nodes
remain pending rather than being discarded or treated as remotely revoked.
The native toggle cannot authenticate an arbitrary unloaded node and does **not**
revoke iOS permission. Settings shows pending cleanup/storage limitations.

If shared storage cannot persist a preference, background/in-flight delivery
cannot be guaranteed off; use iOS Settings for an OS-level block. This condition
withholds automatic capability and is surfaced, not reported as successful remote
cleanup. No relay revocation database or new service is introduced.

## Replay and unavoidable platform limits

The persistent arrival ledger retains at most 4096 scoped event IDs for 24h.
At saturation it quiets additional events rather than evicting unexpired replay
protection. Read watermarks and cleanup handles are separately bounded at 4096.
Failed/corrupt reads do not reset the ledger or consent state silently. Independent
store instances use `flock` on a stable lock inode; data replacement never replaces
the lock file. XCTest exercises independent concurrent instances and restart state;
a real app/NSE multi-process/device run remains necessary.

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
no Swift, Xcode, XCTest, signing or iOS device is available. Actual core-producer
JSON fixture export to native tests is pending coordination; current native
fixtures are synthetic v2 contract payloads. The public workstream owns its actual
producer-to-worker contract tests.

Before release, run the focused suites on a disposable simulator (not the opt-in
live E2E suite): `PushCenterTests`, `PushMessageTests`, `PushDeliveryStoreTests`,
`NotificationMetadataTests`, `NativeNotificationLifecycleTests`, `WebPushCryptoTests`,
and affected browser lifecycle tests. Then explicitly authorize device acceptance
for two scenes/nodes sharing VAPID, owner-closed taps, app/NSE concurrent arrival,
background off/expiry, and authenticated offline cleanup retry. No live enrollment,
APNs send, service/config/state change, deployment, push or PR was performed here.
