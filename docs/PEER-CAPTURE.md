# Peer connect: actual simulator capture harness

This **new**, opt-in harness is separate from the older localhost Hub protocol-fixture capture. It is intended to install the actual simulator app, open a real pairing link through the OS URL handler, require native approval plus actual host terminal approval, navigate native Hub, send a unique prompt through the **real upstream chat frontend**, receive the real service's scripted/debug provider SSE response over WebRTC, and return to native Hub. It runs direct and forced **self-hosted TURN** trials.

**Implementation is not proof of execution.** Native/project/remote adapters listed below must be integrated before this can pass. No actual Mac capture, remote deployment, Cloudflare relay proof, App Store installation, or remote DB audit is claimed by these source changes.

## First, the independent SDK typecheck gate

The new workflow's **`sdk-typecheck` job runs unconditionally on matching PR updates**, without `peer-demo-approved`, secrets, remote staging, simulator runtime, pairing UI, or baseline UITests. The gated capture job depends on it. Parent can stage the stabilized peer sources and this workflow on the existing private PR to get this cheap gate before remote integration.

`scripts/peer-connect/typecheck_sdk.sh` downloads the exact `stasel/WebRTC` **155.0.0** XCFramework zip:

- Package revision: `44f36788497f701bc8c0306de3a1c2511d56019d`
- URL: `https://github.com/stasel/WebRTC/releases/download/155.0.0/WebRTC-M155.xcframework.zip`
- SHA256: `cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe`

It verifies SHA256 before extraction, selects the actual **arm64 / iOS / simulator** slice from the XCFramework plist, forces an actual `import WebRTC` probe so conditional SDK code cannot silently disappear, then runs `xcrun swiftc -typecheck -parse-as-library -swift-version 5 -DDEBUG -sdk <iphonesimulator SDK> -target arm64-apple-ios17.0-simulator -F <real framework directory> -module-name TermLLM` against **all actual `TermLLM/*.swift` and `Shared/*.swift`**, including new peers and actual HubTransport definitions. No extension/test sources or fake application/transport stubs. Existing `#if canImport(WebRTC)` signatures remain untouched.

Private artifact `peer-sdk-RUN_ID-RUN_ATTEMPT` contains compiler logs/versions, source-file hashes, source commit/dirty state, verified archive checksum, actual slice/modulemap metadata, pinned upstream Package.swift, and archive license/third-party notices (BSD-3/upstream notices preserved). This is **SDK/API typechecking only**, not linking, a full app build, installation, ATS/cookie/SSE behavior, or runtime interoperability proof. Actual macOS execution is still required; Linux only checks script syntax.

## Boundaries and approvals

The parent exclusively owns the approved isolated VPS demo resources, actual Alpine contain workspace, existing coturn use, dedicated task user, short-lived key, secrets, host approvals, cleanup, and publication. This harness does not install a service, change DNS/nginx/sshd/shared coturn, run a remote command, deploy, SCP files, or use a root/sudo credential.

SSH carries **broker signalling only**. Parent's dedicated-user key must be:

```text
restrict,command="/usr/bin/python3 -I /opt/<task-owned-path>/broker-stdio.py" <temporary-public-key>
```

The root-owned/read-only forced stdio script connects **only `127.0.0.1:8769`**, the task broker. It must not interpret client bytes as commands or destinations. The key has no TCP forwarding permission; the Mac does not request a command, `-L`, `-R`, `-D`, or `-N`. `forward_broker.py` binds only `127.0.0.1:<local_port>`, starts `ssh -T` per accepted connection with pinned host verification and all forwarding/agent/proxy/local-command options disabled, and pumps opaque bytes. Limits: **16 connections**, **8 MiB combined in both directions per connection**, **30 minutes per connection and total process**. Shutdown cancels connections and terminates/waits/kills owned SSH children. It does not log request bodies, headers, URLs or subprocess errors.

The local WebKit bridge may listen on another ephemeral loopback port, but its upstream is the authenticated **WebRTC DataChannel**, not SSH. ICE selected-pair and DataChannel counters must show real traffic. A successful UI backed by an SSH HTTP/chat proxy cannot satisfy the evidence contract.

## Triggering safely before default-branch merge

`.github/workflows/peer-connect.yml` supports:

- Initial capture on a **private internal PR** (`opened`, `synchronize`, or applying `peer-demo-approved`). Job requires head repo exactly `SamSaffron/term-llm-app` **and** the explicit maintainer-applied `peer-demo-approved` label. Unrelated label events do not rerun capture. Parent applies approval only after reviewing exact source and staging the scoped demo secrets.
- Future `workflow_dispatch` with a public run nonce. GitHub may require the workflow to exist on the default branch first; this harness does **not** require merging just to film, because the guarded PR path exists.

No `pull_request_target`, no fork secrets, `contents: read` only, SHA-pinned actions, checkout without persisted credentials, serialized remote-demo runs. An unapproved/skipped job is **not** passing capture or transport proof. Checkout uses the exact internal PR head; runtime's approved `app_commit` must match it.

## Parent-supplied inputs (never put capabilities in public workflow inputs)

Repository variable `PEER_CI_CONFIG_JSON`:

```json
{
  "schema_version": 1,
  "app_commit": "<exact 40 lowercase hex app SHA>",
  "core_commit": "<exact 40 lowercase hex deployed core SHA>",
  "binary_sha256": "<actual deployed core binary 64 hex SHA256>",
  "container_image_digest": "sha256:<actual 64 hex image digest>",
  "contain_id": "<owned task contain identity>",
  "node_id": "<actual discovered Hub node ID>",
  "ssh": {
    "host": "<approved host>", "user": "<dedicated task user>", "port": 22,
    "local_port": 8769, "broker_port": 8769,
    "known_host": "<exact host or [host]:port> ssh-ed25519 <verified host public key>"
  }
}
```

Private secrets:

- `PEER_CI_SSH_KEY`: short-lived dedicated forced-stdio key, no root/general SSH key.
- `PEER_CI_SESSION_JSON`: `{schema_version:1,run_nonce,expires_at,direct:{pairing_link,ice_servers},relay:{pairing_link,ice_servers}}`. Actual v1 links have broker `http://localhost:<local_port>/`, independent capability + PSK in the fragment, real host identity, and finite expiry. ICE servers are `{urls:[...],username?,credential?}`; relay must include real short-lived self-hosted TURN credentials, not a Cloudflare master key.

For PR runs set public variable `PEER_CI_RUN_NONCE`; for dispatch use `run_nonce`. Nonce must match private runtime and be a fresh 16–80 character alphanumeric/underscore/hyphen identifier. Both links must still be live **after Xcode build and the first trial**. Default five-minute links may be too short; parent must arrange fresh or explicitly approved longer-lived links/staged builds. This harness fails on expiry instead of silently replaying a mutation or pretending pairing succeeded.

The harness removes credential variables from the inherited environment before spawning Xcode/tools. Runtime JSON lives in a mode-0600 file in a mode-0700 private `RUNNER_TEMP` directory **outside artifacts**. Only its path reaches the test runner. The UI test passes JSON through `XCUIApplication.launchEnvironment["TERMLLM_PEER_CAPTURE_JSON"]`; it never prints it. A DEBUG simulator-only native button opens the supplied link via `UIApplication.shared.open`, using the actual OS URL handler. Neither `simctl openurl <secret>` argv nor XCTest `app.open(secretURL)` activity logging is used.

## Required native/project adapter — integration blockers until implemented

Canonical coordination: `/home/agent/work/term-llm-native-hub/peer-ci-interface.md`. Parent/native owner must register `PeerConnectionUITests.swift` in the existing UI test target, register the pairing URL scheme, pin/register the actual WebRTC package, and integrate real peer Hub/chat routing after baseline ownership handoff. The harness does not edit project files or existing app/UI-test/capture files.

Required capture-only native identifiers/actions:

| ID | Actual required behavior |
| --- | --- |
| `peer.captureLabel` | Always visibly **SCRIPTED PROVIDER · REAL TRANSPORT · SIMULATOR INSTALL** |
| `peer.capture.openPairLink` | Open private supplied actual link through UIApplication; **not** connector bypass or autoapproval |
| `peer.approval`, `peer.approve` | Actual native pairing approval view/button |
| `peer.connected` | Actual authorized, open DataChannel connection state |
| `peer.relayLabel` | Relay visibly **SELF-HOSTED TURN · NOT CLOUDFLARE** |
| `hub.open`, `hub.node.<node_id>` | Existing real native Hub and actual discovered node |
| `peer.capture.beforeChat` | Sample actual selected-pair/DataChannel stats immediately before this chat |
| `peer.diagnostics.export`, `peer.diagnostics.exported` | Flush actual response/stats evidence to Documents/peer-capture-evidence.json; exported state only after persistence succeeds |

No capture hook may borrow existing production cookies/identity or render/log the link/PSK/capability/TURN config. Host terminal approval must actually occur; an automated PTY approval must be labelled automated, not human. Parent handles it; the CI key cannot approve a host or mint pairing links.

### Actual frontend, not presentation mock

Read-only discovery of pinned core frontend found `#promptInput` textarea with aria-label **Message**, `#sendBtn` with idle aria-label **Send message**, and completed assistant **Copy response** button when **Stop** disappears. The test uses these actual WebKit accessibility labels. It creates a new conversation, sends:

```text
PEER-CAPTURE <run_nonce> <direct|relay>: describe this test.
```

`debug:fast` may output fixed Lorem text. **No nonce echo or invented response_nonce is required.** Native instrumentation must observe the actual response's session/response IDs, request/content hashes, completion, timestamps and SSE events. JavaScript may inspect the actual DOM; it must not fabricate responses or replace the real frontend.

## Evidence and acceptance

`contract.py:evidence()` defines the exact required v1 export. It requires:

- Real `webrtc-datachannel`, scripted-provider disclosure and native Hub return.
- Actual `chat.session_id`, `response_id`, `sse_response_id` matching that response; actual sent prompt SHA256; completed assistant content SHA256; Unix request/completion times.
- At least two **SSE events for that response** and one actual text delta. HTTP chunks, aggregate Hub poll frames, and DataChannel message counts are not substitute SSE proof.
- `before_chat`/`after_chat` with actual selected pair ID, local/remote candidate type, protocol, selected-pair sent/received bytes and DataChannel sent/received bytes/messages. All six counters increase and pair stays the same. Direct permits no relay candidate; relay requires local candidate `relay` plus actual requested relay policy. Unreported nominated/state/relayProtocol values are never invented.

Parent **independently audits the actual owned remote node DB/API after CI**, matching run marker/prompt hash, session/response IDs, completed assistant content hash and timestamps to actual container/source/binary provenance. Artifacts explicitly say `remote_audit_status: pending-parent-audit`. Local capture success is not a claim that this independent remote audit already passed.

Xcode must report an executed passing non-skipped UI test on the **same UDID** being recorded. Each trial must export at least six real PNGs and finalized MP4 boxes (`ftyp`, `mdat`, `moov`). Source includes placeholder structural bytes only in isolated validator unit tests, never media artifacts.

Outputs in private artifact `peer-connect-RUN_ID-RUN_ATTEMPT`, retained three days:

- `simulator-install.mp4`: actual `simctl install` recording, explicitly **not App Store installation**;
- `direct.mp4`, `relay.mp4`: continuous actual simulator UI journeys;
- per-mode screenshot attachments, xcresult, sanitized evidence and summary, redacted logs;
- `manifest.json`: source/run/app Mach-O hash, parent-supplied expected remote binary/source/container identity, per-mode outcomes, public nonce, audit-pending status, file hashes/sizes.

Raw input, raw diagnostic files, unsafe xcresults and failure media remain quarantined outside the upload tree and are deleted. Evidence is allowlist-rebuilt; xcresults/attachments are scanned for known secret values before copying. This scanner is defense-in-depth, **not OCR or proof against arbitrary secret transformations**; native capture UI/logging must itself never expose credentials. Failure to satisfy that interface blocks uploading raw diagnostics.

```sh
gh run download RUN_ID --repo SamSaffron/term-llm-app \
  --name peer-connect-RUN_ID-RUN_ATTEMPT --dir peer-connect-capture
```

Use actual downloaded PNG/MP4 paths for `show_media`. No footage is generated on Linux.

## Local verification and remaining gates

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/peer-connect -p 'test_*.py' -v
```

Tests exercise adapter rejection, nonce/hash/SSE/ICE/counter correlation, secret quarantine, video-finalization checks, real local pipe subprocess pumping, shared byte budget, connection/age limits, child cleanup and SSH argument restrictions—**without any SSH secret or remote network call**.

Remaining actual integration gates: native capture/URL/UI/telemetry adapter and target/package registration; parent actual remote contain/broker/forced-stdio key/self-hosted TURN staging and live approval/expiry; first successful macOS compile/run; independent remote DB audit. Cloudflare TURN and production distribution remain explicitly unverified.
