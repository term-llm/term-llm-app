# Development guide

## Project map
- Native iOS app: Swift/SwiftUI + WKWebView in `TermLLM/`; open `TermLLM.xcodeproj`, scheme `TermLLM`.
- Native Mac app: `TermLLMMac/`, scheme `TermLLMMac`; compiles the shared `TermLLM/` sources plus the Mac-only code.
- Mac Swift packages: `TermLLMMacKit/` (local CLI/service management) and `ComputerUseKit/` (Computer Use). Computer Use helper app: `TermLLMComputerUse/`; its `term-llm-computer` CLI: `TermLLMComputerCLI/`.
- Notification extension: `TermLLMNotificationService/`; shared notification code: `Shared/`.
- Tests: `TermLLMTests/`, `TermLLMUITests/` and `TermLLMMacTests/`. Go push relay: `push-relay/`.
- Read `README.md` for current behavior; consult the relevant `docs/` guide before changing a subsystem. Notification changes must respect `NOTIFICATION-OWNERSHIP.md`.

## Working rules
- Follow existing patterns; keep changes scoped and add regression coverage for fixes.
- Preserve per-connection credential, cookie and WebKit isolation. Never put secrets in URLs, defaults or logs.
- Keep native navigation responsive independently of remote requests; preserve the retained Chat document across tab switches.
- Do not edit generated `DerivedData/` or capture output. Generated mocks and screenshots go in the ignored `output/`; copy only what a doc cites into `docs/`. Do not reset developer simulators.

## Verification
- Build iOS app changes: `xcodebuild build -project TermLLM.xcodeproj -scheme TermLLM -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`.
- Run relevant XCTest suites with `xcodebuild test`, an explicit simulator destination, and `-only-testing:TermLLMTests/<Suite>`, or `-testPlan <name>` (`TestPlans/`: `TermLLM-Notifications`, `TermLLM-LinkedDevices`, `TermLLM-UnitTests`). See `.github/workflows/native-simulator-tests.yml` for the unsigned test setup.
- Build Mac app changes: `xcodebuild build -project TermLLM.xcodeproj -scheme TermLLMMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` (compile check only: unsigned builds cannot use the Keychain).
- Mac tests: `xcodebuild test -project TermLLM.xcodeproj -scheme TermLLMMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:TermLLMMacTests`.
- Mac packages: `(cd TermLLMMacKit && swift test)`; `(cd ComputerUseKit && swift build && swift test)`.
- Notification contract: `python3 scripts/check-notification-contract.py`.
- Relay changes: `(cd push-relay && go build ./... && go test ./...)`.
- Python helpers: `python3 -m unittest discover -s <changed-script-directory> -p 'test_*.py' -v`.
- Review `git diff`; report checks actually run and any unverified behavior. Fixtures are not proof of live server/device behavior.

## Real UI testing: term-llm-computer
- Use `term-llm-computer` to exercise the running app through Simulator's UI when validating user-facing changes; builds and unit tests alone do not prove the flow works.
- It serves only agents started by term-llm and needs Computer Use turned on in the term-llm Mac app. `term-llm-computer doctor` reports missing macOS permissions.
- **Read the `computer-use` skill first** (`term-llm-computer skill` prints it) for commands, approval rules and recovery steps. Start with `term-llm-computer get_app_state --app Simulator`.
- Read → act → read. Use `element_index` values from the newest read only; chain known actions with `&&` and finish with a state read. If accessibility lacks the needed control, open the image on the `Screenshot` line and click with `--x`/`--y` pixels.
- Capture proof with `term-llm-computer get_app_state --app Simulator --keep`; report its `Screenshot` path and the observed result. Do not claim success from a click alone.
- Do not substitute AppleScript/`osascript` for UI control. Respect approval boundaries and never operate Computer Use's own permission or settings controls; stop and report permission blockers rather than bypassing them.
- Use a physical phone for device-only behavior (push delivery, audio interruptions/background playback, etc.); label simulator-only verification honestly.

## CI constraints
- CI is self-hosted only: `[self-hosted, macOS, ARM64, term-llm-local]`. No paid hosted fallback or artifact uploads; see `docs/SELF-HOSTED-CI.md`.
