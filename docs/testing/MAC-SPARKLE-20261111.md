# Sparkle self-update verification — 11 November 2026

Private branch `feat/mac-sparkle-updates`, based on `49679ff`. No production
server, 1Password item, GitHub secret, runner registration, or public repository
was changed. This change is a PR only; do not merge until setup is reviewed.

## Results

- Two **Release** builds on the existing Intel macOS VM: **1.0.90 (9000)** and
  **1.0.91 (9001)**, using an explicitly compiled local-feed test condition.
- Both signed ad-hoc, including nested code, with the same signing setup. No
  Developer ID identity was available; neither build was notarized.
- Guest-generated, explicitly labelled throwaway EdDSA key; private material
  never committed. Local HTTP feed bound to `127.0.0.1:18765`; both XML and ZIP
  signed with Sparkle 2.10.1 tools. Production feed settings were not changed.
- Real app-menu Check → signed notes → download/verification → Install and
  Relaunch → About **1.0.91 (9001)** passed.
- Managed CLI stayed **0.9.99**, authenticated `/ui/healthz` returned OK, and
  the web service retained **PID 65716** throughout GUI replacement. Exactly one
  test GUI process remained. CLI/service autostart stayed enabled during the run.
- A same-length, one-byte-tampered ZIP was rejected with “The update is
  improperly signed…”; Sparkle's log confirms EdDSA mismatch before extraction.
  This earlier negative pass preceded the final bounded login-refresh wait fix;
  verification/key/feed policy was unchanged. The positive run rebuilt both
  apps with the final lifecycle implementation.
- On first cold launch, automatic checking found the update before a manual
  Check action. Captured as an actual still; the 24-hour interval was not waited
  out. Installation remains user-confirmed, not unattended.

## Automated checks

| Check | Result |
| --- | --- |
| `python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v` | 104 passed |
| `swift test -j 2` in `TermLLMMacKit` | 118 tests, 1 skipped, 0 failures |
| Hosted updater/lifecycle/Computer Use/menu XCTest selection | 31 passed |
| TermLLMMac Release builds 9000 and 9001 | Both passed |
| Generic iOS Simulator build, x86_64, unsigned | Passed; Sparkle not linked to iOS |
| Pinned signer + CI-generated XML + CryptoKit public-key consistency | Passed; tampered XML rejected |
| Nginx snippet, local fixture vhost only | Syntax, XML/ZIP types, cache headers and deny routes passed |
| One-time setup script `sh -n` | Passed; script NOT applied |
| `git diff --check` | Passed |

Environment: macOS **15.8.2 (24H232)**, x86_64, Xcode **26.2 (17C52)**,
Swift **6.2.3**. Initial builds exposed existing compiler/concurrency blockers;
the PR contains a separate small compatibility commit: explicit Pointer
numeric type, bounded SwiftUI modifier expressions, Sendable MapKit conversion,
weak-capture promotion, and closure-wrapped Binding callbacks. No behavior from
the phase-1 UX findings was changed. Initial unsigned/background-session test
launches failed; final ad-hoc hosted run passed after the other user’s same-ID
GUI was quit. Stale menu expectations were updated and the selection rerun.

Independent static security review found and then cleared: authenticated
history before re-signing, immutable content-addressed archive retry behavior,
website/GitHub version recovery, and bounded login-refresh drainage. The
reviewer did not independently run the reported tests.

## Evidence

Private Jarvis deliverables:
`/home/agent/Files/term-llm-mac-sparkle-20261111/`

- `term-llm-mac-sparkle-update.mp4`: **129.73 s (2:09.73)**, H.264, yuv420p,
  1920×1080, 15 fps, faststart, silent. Actual QMP framebuffer frames sampled
  about every 0.447 s, repeated at output frame rate. Dead waits are cut;
  title cards and held actual stills are labelled. Negative-test footage was
  recorded earlier and is explicitly presented separately.
- Key stills, sanitized test/service/signature evidence, `REPORT.md`, and
  `SHA256SUMS`. Raw frames/edit timeline remain in the private task workspace.

## Cleanup and limits

All guest mutations/builds/captures used the shared mini runner with the real
parent session owner. Reservations were released; task capture/HTTP/provider,
proof shells, caffeinate, tunnel sleepers and local agents were stopped.
The throwaway Keychain item and exported private key were deleted. Cleantest’s
service was stopped, autostart disabled, original port-8080 configuration
restored, and the test app moved out of Applications into its evidence folder.
Tester’s original **PID 55436**, provider **PID 70550**, configuration and running
service were never stopped or replaced. The VM was left at the locked login
screen with retained OS sessions; temporary fast-switch preference restored.
Mini maintenance compatibility restored, blockers empty. No VM restart/update.

Not verified: real Developer ID + notarized Sparkle replacement, Apple silicon,
production HTTPS/SSH publication, real 1Password reads, first main CI run,
24-hour timer, enabled Computer Use helper/TCC continuity during a real update,
or active chat/voice/draft recovery. Ad-hoc builds do not have production
shared-Keychain entitlements; the inherited client connection displayed an
unavailable-results state, while independently authenticated service health
passed. No real model/provider behavior is claimed.

See [Sparkle setup](../SELF-HOSTED-CI.md#sparkle-updates) for the exact manual
key/server steps and the public-download distribution decision. Existing
1.0.5 installs need the first updater-enabled release installed manually once.
