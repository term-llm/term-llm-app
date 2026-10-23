# Phone-owned Hub (HTTP-only)

This change adds **two slices in one app PR**, reusing the existing native Hub work.
It does not depend on the deferred WebRTC branch, SDK or remote demo services.

## Slice 1: saved connections

- Native home exists with an empty catalog; no reachable server is required to open it.
- Add an explicit **Hub** or **Direct Node**, a display name, and its HTTPS root URL, including its mount prefix.
- Connection metadata is saved locally. Credentials are not serialized into defaults or connection links.
- Existing `serverURL` migrates into the catalog once. A positive public health-role result can classify the legacy endpoint; unknown/failed discovery requires review instead of a guessed type.
- The selected source URL remains mirrored to the existing single-active-browser setting. Source-specific device-tool and shortcut opt-ins do not become app-wide grants.
- Each source owns its WebKit website data and authentication. A changed endpoint/kind is a new trust identity; a name change is not.
- Isolated storage may require a fresh sign-in after migrating the old URL. URL migration does not imply automatic copying of ambient browser credentials.
- Listen items capture their originating source UUID when queued; later selection changes cannot substitute a different connection's cookies. Missing/corrupt catalogs, removed sources and media with unknown ownership fail closed for credentials. Previously queued unowned protected media may need to be added again from its signed-in source; public URLs do not gain credentials through URL matching alone.
- Download/artwork sessions disable automatic cookies and ambient cookie/credential storage. Public redirects remain supported but drop Cookie/Authorization headers, including same-host redirects that could leave the owning mount. Protected media endpoints must not rely on forwarding authentication through a redirect.

## Slice 2: unified native views

Nodes, Attention and Sessions retain their connection provenance and use source-qualified identities. Two Hubs can expose the same remote node, session and attention identifiers without overwriting each other.

The aggregate reuses one existing `HubStore` per source. Its independent panel tasks, auth epochs and stale-result guards remain responsible for refresh. One stalled/offline source does not prevent another source from publishing; a 401 clears only that source’s protected state. Connection removal/editing invalidates the old runtime rather than accepting its late response.

A Hub connection uses its existing `/api/nodes` and `/api/attention` protocol. Its returned private node address is display-only: opening a node/session must use the validated Hub proxy route under that connection’s mount. Direct Nodes use `/healthz`, `/v1/sessions/status`, and `/v1/attention` through a small adapter; 501 attention support is not mistaken for an authentication failure. Exact-item direct acknowledgement uses the existing `/v1/sessions/{id}/attention/seen` body with `store_instance_id` and `through_seq`.

Direct-node bearer API mutations require the Authorization header; the legacy token cookie authenticates GET only. The existing frontend reads `localStorage.term_llm_token` at startup, so a main-frame, exact-origin/mount document-start script supplies the saved token before its modules run. Tokens are not passed in navigation URLs. Passkey sign-in reuses the existing native browser handoff, with the target connection’s cookie sink. Starting explicit reauthentication closes the old protected chat/cache and clears the old credentials; cancelling does not silently restore the old session.

Hub Manage/Security remains per-Hub. Direct Nodes are not given invented Hub registration or node-management APIs. No recursive server federation protocol is added.

## Reused verification pipeline

The original `scripts/native-hub/capture.sh`, fixture HTML/logging helpers, simulator selector, unit-execution checks and finalized-media checks are reused with explicit parameters. Their default behavior remains the original native Hub journey.

The new workflow `.github/workflows/phone-hub.yml` checks out the exact PR head and runs:

1. Existing Python fixture/provenance regressions plus the new multi-source fixture/gate tests.
2. Actual Xcode app build and all eleven requested XCTest classes: `HubConnectionStoreTests`, `HubAggregateStoreTests`, `HubConnectionSecurityTests`; `DirectNodeClientTests`, `DirectNodeClientModelTests`, `DirectNodeClientMountTests`, `DirectNodeClientCookieFilterTests` (all four Direct Node classes); and `ListenToolsTests`, `ListenPlayerTests`, `ListenStoreTests`, `ListenMediaTransportTests` for media source ownership, provider lifetime and ambient-cookie denial.
3. Actual `PhoneHubUITests` on the same simulator being recorded: user-added Work/Home Hubs plus a Laptop Direct Node, native unified views, correct Hub/direct chat routes, saved-catalog process relaunch, a genuinely pending source HTTP request, and one-source 401 isolation. For pending-source progress, the test waits for an uncached healthy node-title update, then asserts Slow's native `nodesLoading` marker before acknowledging it to the fixture. The gate rejects a slow response completing before that assertion; server-side waiting alone does not establish that the native client remains pending.

The test flag `TERMLLM_PHONE_HUB_FIXTURE_URL=http://localhost:8767/` works only in Debug simulator builds. `TERMLLM_PHONE_HUB_FIXTURE_RESET=1` clears the isolated fixture catalog for the first launch; a relaunch with `0` tests persistence. Fixture storage/auth are isolated from production. Every screen is labelled **DEMO FIXTURE · LOCAL**. The fixture uses synthetic identifiers and static chat HTML; it is not a model, a real remote agent, or a passkey provider.

The test server binds loopback only and is stopped by the capture runner. It deliberately returns identical node/session identifiers from different sources and private, unreachable display-only node URLs. Request logs retain only method/path/status/time, never headers, cookies, queries or bodies. Fixture-only control endpoints can revoke one synthetic source without affecting the others. No CI credentials, public listener or external deployment is needed.

Artifacts remain private: exact-source/CI manifest, xcresults, unit/UI summaries and trees, API route log, screenshots, and the continuous simulator recording. A successful build or a video file alone is insufficient: the gate requires actually executed non-skipped tests, each requested suite, both UI journeys, expected HTTP routes, a healthy refresh after another source’s 401, screenshots and a finalized MP4.

Local fixture tests are not an iOS runtime claim. Physical-device secure storage, real passkey ceremonies, APNs delivery, background playback and live voice still require their respective device/integration verification.
