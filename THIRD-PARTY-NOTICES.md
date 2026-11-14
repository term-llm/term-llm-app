# Third-party notices

term-llm is MIT licensed: see [`LICENSE`](LICENSE), which also ships inside
every app bundle. Builds additionally contain the third-party components below.

**The complete, verbatim notices ship inside every app bundle** as
`THIRD-PARTY-NOTICES.txt`, next to `LICENSE`:

- iOS: `term-llm.app/THIRD-PARTY-NOTICES.txt`
- macOS: `term-llm.app/Contents/Resources/THIRD-PARTY-NOTICES.txt`
- Computer Use helper: `term-llm Computer Use.app/Contents/Resources/THIRD-PARTY-NOTICES.txt`
  (also inside the macOS app at `Contents/Helpers`)

The same document and the license texts it reproduces live in
[`Licenses/`](Licenses/):

| Component | Included in | License | Text |
| --- | --- | --- | --- |
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.1, revision `ab7d712` | macOS app updates | MIT, including Sparkle's bundled notices for bsdiff, sais-lite, ed25519 and SUSignatureVerifier | [`Licenses/Sparkle-LICENSE.txt`](Licenses/Sparkle-LICENSE.txt) |
| [WebRTC](https://github.com/stasel/WebRTC) M155, revision `44f3678`, binary artifact `WebRTC-M155.xcframework.zip` | iOS and macOS apps | BSD 3-Clause, Copyright (c) 2011, The WebRTC project authors | [`Licenses/WebRTC-LICENSE.txt`](Licenses/WebRTC-LICENSE.txt), verbatim `WebRTC.xcframework/LICENSE` from that download |
| [browser-use macOS harness](https://github.com/browser-use/macos-harness), revision `43d9edf`, ported to Swift in `ComputerUseKit/` | Computer Use helper, `term-llm-computer` | MIT, Copyright (c) 2026 Browser Use | [`ComputerUseKit/LICENSE-macos-harness`](ComputerUseKit/LICENSE-macos-harness) |

See [`Licenses/THIRD-PARTY-NOTICES.txt`](Licenses/THIRD-PARTY-NOTICES.txt) for
the full shipped text, [`Licenses/SOURCES.json`](Licenses/SOURCES.json) for
provenance (pinned revisions, artifact SHA-256, text digests) and
[`Licenses/README.md`](Licenses/README.md) for how the files are shipped and
how to refresh them.

This summary is not a claim of exhaustive transitive licensing: Apple SDKs and
system frameworks are out of scope, and `push-relay/` is server software that is
operated, not bundled with any app. Adding a Swift package to the app or helper
targets requires adding its notice before shipping.

Check with `python3 scripts/check-license-notices.py`.
