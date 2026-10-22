# Actual core-produced synthetic v2 notification fixtures

Public review SHA: `600d7199e30375758fefba7a0e57a4ae72f9a923` (test-only export follow-up to `7f8b8251d0370fe7f475925b50ad7f46a8a697a2`).

These three JSON files are **unmodified bytes emitted by actual public core producers**, not handwritten contract lookalikes. All IDs/data come from isolated synthetic tests. No real session, subscription endpoint, key, token, user configuration or private source was read/exported. The completion event ID includes an opaque registration ID minted only in the disposable test DB.

- `completion.json`: temporary SQLite human-turn admission/finalization/claimed candidate → actual `completionNotificationPayload` marshaler. Synthetic node label/session/window/response. No external send.
- `completion-compact.json`: same actual candidate through `sendCompletionPush` compact retry, with injected first-attempt size error; all event/turn/window/store/session/attention/source/routing fields unchanged. Only display title/transport record sizing differs.
- `manual.json`: real `RunWeb` CLI producer → WebPush encryption → owned localhost HTTP test endpoint → independent receiver decryption. No push provider/APNs endpoint contacted. One synthetic invocation event identity is retained across test fanout.

Both paths were accepted by the actual public service-worker push handler in an offline Node VM and replay-tested. Generation command (destination supplied explicitly, no repository-specific path is embedded in public tests):

```sh
TERM_LLM_NOTIFICATION_FIXTURE_DIR=/absolute/path/to/producer-fixtures \
make test PKG='./internal/app/notify ./internal/app/serve' \
  RUN='^(TestManualPushProducerToWorkerContract|TestCompletionProducerToActualWorkerContract)$' \
  ARGS='-count=1 -race -timeout=120s'
```

## Clock-sensitive consumer tests

Use each `manifest.json` entry's **injected_test_now**, between its actual `created_at` and `expires_at`, for expiry/read/replay policy tests. The manual producer's real TTL is60seconds; the completion's absolute horizon is24hours. Do not rewrite the JSON timestamps just to make a test pass. Decoder-only tests may parse the timestamp metadata without consulting wall clock. Regeneration intentionally creates fresh synthetic IDs/timestamps; SHA256 hashes pin this export batch.

Companion decoder/XCTest integration is owned separately. These exports prove actual public producer→worker acceptance, not native compilation or physical OS notification behavior.
