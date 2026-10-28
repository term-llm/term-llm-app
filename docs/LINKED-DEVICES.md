# Linked devices native client

Linked devices adds this app’s private client for term-llm's frozen pairing protocol v2. A host creates a one-use `termllm://pair` link in its own **Settings → Linked devices** tab. On iPhone, Camera can hand a QR pairing link to this app; no in-app scanner is required. Other clients can open the same client-agnostic pairing link.

## Security and lifecycle

- The QR link is strictly bounded and parsed. Pairing and invitation secrets stay in the URL fragment and transient app memory; they are never copied into the connection catalog, defaults, logs, or a browser URL.
- Each host gets a separate Ed25519 device identity. Its seed, device ID and raw reconnect capability are stored in Keychain with `AfterFirstUnlockThisDeviceOnly`; there is no production in-memory fallback.
- The review sheet shows the link's host label, a host-key fingerprint and rendezvous host. After the signed/MACed request is sent, it shows the six-digit transcript-derived confirmation code for the owner to type in the host's web tab.
- Pairing v2 carries identity only. Core publishes the new device capability hash through a successful lease renewal before revealing the raw capability in `pair_answer` (and rolls the grant back if renewal fails). After persisting that authenticated answer, the app closes the one-use invitation socket and immediately opens the device-authenticated broker path for the signed WebRTC handshake; only transient transport/offline failures receive a bounded retry.
- Broker `unauthorized` for an already-paired device is terminal **access revoked or target reset**. `not_found` and `peer_offline` are offline evidence and retry with backoff. Unsigned broker advice can never replace the pinned host key; only signed host messages are identity authority. Pairing messages are capped at 256 KiB, complete broker frames at 256 KiB + 512 bytes, and SDP at 64 KiB.
- HTTP runs over one reliable ordered `term-llm-http-v1` DataChannel. Requests, responses, SSE chunks, cancellation, concurrency, buffering and frame/body sizes are bounded. A failed request is never automatically replayed on a replacement connection.
- Saved source identity is the pinned host key, not the local browser URL. A source retains a dedicated loopback port and persistent `WKWebsiteDataStore`, so its browser origin survives restart/reconnect. One exclusive dual-stack `NWListener`, restricted to the loopback interface with local-only acceptance, reserves the port for both loopback families; separate IPv4/IPv6 listeners conflict in iOS's NECP port reservation even when simulator binding succeeds. The simulator lacks NECP local-only acceptance and instead uses explicit `127.0.0.1`/`::1` binds with the same exclusive-port and remote-endpoint checks. The bridge additionally checks remote loopback endpoints and requires an exact host/origin and a random HttpOnly capability cookie; it never accepts network clients.
- Native Agents, Sessions, search and Attention use the source's injected `HubTransport`. Chat uses the isolated loopback streaming bridge. Its browser entry URL is resolved against the selected validated host-keyed source, not reparsed as an ordinary user-entered HTTP server; general physical-device input still requires HTTPS. Direct sources without a nonblank health agent name display the saved connection name, and conversation counts are labelled rather than shown as bare numbers. Browser Live voice uses the host's advertised transport: finite PCM microphone posts and streamed HTTP/SSE output for HTTP PCM, or its existing WebRTC signaling path. Only the exact bridge origin's in-mount main frame may request microphone permission; pairing does not bypass WebKit's per-origin prompt or iOS authorization. Camera capture, dictation uploads, native push, native voice shortcut targeting and WebMCP device tools remain unavailable. Linked Live calls use server-owned execution, cannot register device/page tools, are scoped to their paired device, and end when that peer connection is revoked or disconnected. Both the host/frontend and native app must include this support; an app-only update cannot override an older host's disabled capability.
- Restart, foreground and network recovery reconnect with the Keychain grant. While the app runs in the background (for example while audio plays), a connection closes after 20 s unless its chat page is using the microphone for a Live call, so a call on a locked phone keeps working. It reconnects as soon as the app returns, and the source's native polling resumes once it has. Removing a source tears down its requests, listener, WebKit store and Keychain credential. A paired-device broker `unauthorized` or a core HTTP 401 marks the source as access revoked/target reset; source metadata remains until the owner removes it.

The server trust boundary remains the one described by term-llm's Linked devices screen: a linked client receives the allowlisted `web-v1` view of that server, and messages can drive the server's configured agent/tool authority. Revocation stops future network access; it does not undo prior agent actions.

## WebRTC SDK provenance

The project pins `https://github.com/stasel/WebRTC` at revision `44f36788497f701bc8c0306de3a1c2511d56019d` (tag 155.0.0 / M155) in both the Xcode project and `Package.resolved`. The pinned package declares binary archive checksum:

`cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe`

The wrapper’s exact `LICENSE.md` is:

`https://github.com/stasel/WebRTC/blob/44f36788497f701bc8c0306de3a1c2511d56019d/LICENSE.md`

The M155 release identifies upstream WebRTC commit `5bd86a2f17a35dfc986b87d058f511e45805bd1d` on `branch-heads/8059`. The authoritative source-side notice generator for that exact commit is:

`https://webrtc.googlesource.com/src/+/5bd86a2f17a35dfc986b87d058f511e45805bd1d/tools_webrtc/libs/generate_licenses.py`

That generator derives the actual linked target’s dependencies with `gn desc` and collects their pinned license files. The binary archive does **not** contain its generated complete inventory. Therefore this private PR is **not distribution-ready**: before any legal/App Store distribution, reproduce the M155 `framework_objc` build dependency graph using the release’s build arguments, run that exact generator for every shipped slice/target, review the output, and bundle the resulting notices. The source references above are traceability, not a substitute for the generated inventory. This PR does not change signing, provisioning, entitlements, deployment, or service configuration.

## Validation

Portable validation:

```bash
python3 -m unittest discover -s scripts/linked-devices -p 'test_*.py' -v
python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
```

The first command independently recomputes the frozen core v2 transcripts, HMACs, hashes and SAS, and signatures when the already-installed Python `cryptography` module is available. Native XCTest repeats the vectors using CryptoKit and covers strict links/messages, per-host identity persistence, catalog identity, reconnect state and DataChannel/loopback bounds.

After the private PR is pushed, the parent can dispatch **Linked devices native validation**. It uses only `[self-hosted, macOS, ARM64, term-llm-local]`, the established bootstrap and an already-installed iPhone simulator. It resolves the checksum-pinned SDK, performs a real unsigned linked simulator build and runs the focused new plus source/browser regression tests. There is no GitHub-hosted fallback, signing/profile change or artifact upload.

Passing portable tests is not an iOS runtime claim. Until that workflow or a local Mac run succeeds, SDK linkage, XCTest execution, Keychain OSStatus behavior and simulator WebKit/WebRTC behavior remain unverified. A physical iPhone plus an approved reachable broker/TURN is still required for cellular NAT, background/foreground and production relay evidence.
