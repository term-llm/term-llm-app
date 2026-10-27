# Development guide

## Project map
- Native iOS app: Swift/SwiftUI + WKWebView in `TermLLM/`; open `TermLLM.xcodeproj`, scheme `TermLLM`.
- Notification extension: `TermLLMNotificationService/`; shared notification code: `Shared/`.
- Tests: `TermLLMTests/` and `TermLLMUITests/`. Go push relay: `push-relay/`.
- Read `README.md` for current behavior; consult the relevant `docs/` guide before changing a subsystem. Notification changes must respect `NOTIFICATION-OWNERSHIP.md`.

## Working rules
- Follow existing patterns; keep changes scoped and add regression coverage for fixes.
- Preserve per-connection credential, cookie and WebKit isolation. Never put secrets in URLs, defaults or logs.
- Keep native navigation responsive independently of remote requests; preserve the retained Chat document across tab switches.
- Do not edit generated `DerivedData/` or capture output. Do not reset developer simulators.

## Verification
- Build app changes: `xcodebuild build -project TermLLM.xcodeproj -scheme TermLLM -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`.
- Run relevant XCTest suites with `xcodebuild test`, an explicit simulator destination, and `-only-testing:TermLLMTests/<Suite>`. See `.github/workflows/native-notification-tests.yml` for the unsigned test setup.
- Notification contract: `python3 scripts/check-notification-contract.py`.
- Relay changes: `(cd push-relay && go build ./... && go test ./...)`.
- Python helpers: `python3 -m unittest discover -s <changed-script-directory> -p 'test_*.py' -v`.
- Review `git diff`; report checks actually run and any unverified behavior. Fixtures are not proof of live server/device behavior.

## Real UI testing: macos-harness
- Use `macos-harness` to exercise the running app through Simulator's UI when validating user-facing changes; builds and unit tests alone do not prove the flow works.
- **Read `macos-harness skill` first** for commands, permission rules and recovery steps. Start with `macos-harness get_app_state --app Simulator`.
- Read → act → read. Use fresh `element_index` values; chain known actions with `&&` and finish with a state read. If accessibility lacks the needed control, inspect the latest screenshot and use pixel coordinates.
- Capture proof with `macos-harness get_app_state --app Simulator --keep`; report its `Screenshot` path and the observed result. Do not claim success from a click alone.
- Do not substitute AppleScript/`osascript` for UI control. Respect harness approval boundaries; stop and report permission blockers rather than bypassing them.
- Use a physical phone for device-only behavior (push delivery, audio interruptions/background playback, etc.); label simulator-only verification honestly.

## CI constraints
- CI is self-hosted only: `[self-hosted, macOS, ARM64, term-llm-local]`. No paid hosted fallback or artifact uploads; see `docs/SELF-HOSTED-CI.md`.
