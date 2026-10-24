# Native Hub: actual simulator test and capture

This pipeline runs **the real iOS SwiftUI app with XCUITest** on `macos-15` using `/Applications/Xcode_26.2.app`. It records the same existing iPhone simulator selected by `scripts/select-ios-simulator.py` with `simctl recordVideo`, and exports actual XCUITest screenshot attachments as PNGs. It does not render slides or simulate a native UI in HTML.

## What is demo data—and what is not implemented

Every app screen and the local chat HTML display **DEMO FIXTURE · LOCAL**. The Python server is a loopback-only, read-only **Hub protocol fixture**, not an upstream Hub process. Native Hub requests use the real `HubClient`/URLSession transport. Node health, attention, session lists, and security records are synthetic. The chat document is static labelled HTTP HTML, **not** the upstream chat frontend or an LLM response. The stalled chat route really leaves its HTTP request unanswered for 90 seconds; returning to Hub must not depend on that request completing.

The desired end-to-end product journey—`tl contain … → install app → gain access`—is **not** proven here. No actual distribution/install link, contain invocation, hosted redirect service, remote tunnel, pairing ceremony, passkey registration, APNs, or production authentication is exercised. The local capture runner installs the simulator build through Xcode and the user-facing test connects on first run to `http://localhost:8766/`. No service is deployed.

### Protocol provenance

The fixture's public response shapes are transcribed from `SamSaffron/term-llm` commit **2496b5fddebdc9369642d062fa87b98cd649d415** (`upstream/main` at task start):

| Route / shape | Authoritative source under `internal/` |
| --- | --- |
| `/healthz`, `/api/nodes`, node/session views and `/node/<id>/chat/<number>` resume paths | `app/serve/serve_hub_nodes.go` |
| Node health | `hub/probe.go` |
| `/api/attention` totals, node projections, input-required and inbox | `app/serve/serve_hub_attention.go` |
| `/api/delegations` envelope | `app/serve/serve_hub_delegations.go` |
| `/api/registration-info` | `app/serve/serve_hub_registration.go` |
| `/api/auth/session`, `/api/auth/credentials` | `app/serve/serve_hub_passkey.go`, `passkeyauth/session.go` |
| Root `data-hub-config` shell | `app/serve/serve_hub_index.go` |

Nodes: **Demo Dev** (active and completed sessions), **Demo Stalled** (health responds, chat HTTP stalls), **Demo Offline** (reverse connection disconnected). Security presents a clearly fictitious operator/passkey; no cryptographic ceremony is faked. All mutations return 405 and unknown routes return 404. Request logs include only method, path without query, timestamp and status—not cookies, headers, bodies or tokens.

## App/project integration

- Simulator DEBUG launch environment: `TERMLLM_NATIVE_HUB_FIXTURE_URL=http://localhost:8766/`. Only that exact URL is accepted. The app uses an isolated, cleared defaults suite and nonpersistent WebKit data store, does **not** preset the connected URL, and keeps device-tool sharing/push enrollment off. It never borrows production credentials/settings.
- First-run field/button identifiers are `serverAddress` / `serverConnect`; the global disclosure is `hub.fixtureBanner`. Persistent native navigation is `hub.open` / `hub.chat`. Final Hub view identifiers are kept in sync with `TermLLMUITests/NativeHubUITests.swift`.
- Project owner registers `TermLLMUITests/NativeHubUITests.swift` in an **iOS UI Testing Bundle** named `TermLLMUITests` (`com.apple.product-type.bundle.ui-testing`), app target dependency, `TEST_TARGET_NAME = TermLLM`, generated Info.plist, deployment target matching app, Swift 5. Include the test target in shared `TermLLM` scheme build-for-testing and non-skipped TestableReference. CI worker does not edit `project.pbxproj` or schemes.
- Existing `Info.plist` has the `localhost` HTTP ATS exception; address validation restricts HTTP to simulator localhost. No arbitrary network exception is added.

## Running and obtaining media

Simulator capture is local-only: `.github/workflows/native-hub.yml` was removed to reduce GitHub Actions spend. CI runs only portable fixture/helper checks on Linux; it does not run this journey or upload recordings.

On a Mac with the stated Xcode/runtime already installed:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer
export SIMULATOR_UDID="$(python3 scripts/select-ios-simulator.py)"
export RUNNER_TEMP="$(mktemp -d)"
bash scripts/native-hub/capture.sh
```

For an existing completed CI run, authenticated repository readers can download:

```sh
gh run download RUN_ID --repo SamSaffron/term-llm-app \
  --name native-hub-RUN_ID-RUN_ATTEMPT --dir native-hub-capture
```

Historical CI artifacts had a seven-day retention limit. New captures stay in the local `$RUNNER_TEMP/native-hub-artifacts/` directory; no automatic upload occurs. Outputs:

- `native-hub-demo-fixture.mp4`: continuous actual simulator recording during the XCUITest run;
- `screenshots/**/*.png`: first-run, entered connection, native dashboard, inspected screens, chat and stalled-chat recovery attachments; names/attachment associations are in the exported xcresult attachment manifest;
- `NativeHub.xcresult`, `build.log`, `test.log`, `test-summary.json`;
- `NativeHubUnits.xcresult`, `unit-test.log`, `unit-test-summary.json`, `unit-test-tree.json`: focused `HubClientTests`, `HubStoreTests`, and `HubPasskeyTests`, run **before** recording begins;
- `fixture-requests.jsonl`, fixture/recording/export logs, simulator inventory and Xcode version;
- `manifest.json`: checked-out commit, dirty-worktree flag, run/ref/SHA, simulator UDID, timestamps, exit status, fixture limitations, and SHA-256/size inventory. No environment dump.

Use the actual downloaded PNG/MP4 paths with `show_media` to display the capture. Do not present Python unit-test placeholder bytes as captured media.

## Pass/fail and verification limits

`xcodebuild` failures propagate through `pipefail`. All three requested unit suites must appear in xcresult with passing, non-skipped execution. The selected UI suite must execute and pass with zero failures/skips; zero tests is a failure. Artifact validation additionally requires real HTTP coverage of native APIs and canonical normal/stalled chat routes, including a native dashboard refresh **after** the stalled navigation, at least eight PNGs, and a structurally finalized MP4 containing `ftyp`, `mdat`, and `moov` boxes. Screenshots alone **cannot** pass the capture gate. The EXIT trap stops/finalizes video, terminates the fixture, exports available failure attachments and writes provenance even on test failure; outputs remain local.

Linux verification: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/native-hub -p 'test_*.py' -v`, `bash -n scripts/native-hub/capture.sh`, workflow YAML/pin checks and `git diff --check`. Linux cannot compile UIKit/XCUITest or produce simulator evidence. A successful local macOS capture run remains necessary before claiming that this integrated journey passed or that real media exists.
