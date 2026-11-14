# License distribution

`term-llm` itself is MIT licensed (root [`LICENSE`](../LICENSE)). Builds also
contain third-party code, so every user-facing bundle ships that component's
notice as well:

| Distributed product | Bundle | Files shipped |
| --- | --- | --- |
| term-llm for iOS | `term-llm.app` | `LICENSE`, `THIRD-PARTY-NOTICES.txt` (bundle root) |
| term-llm for macOS | `term-llm.app` | `LICENSE`, `THIRD-PARTY-NOTICES.txt` (`Contents/Resources`) |
| Computer Use helper | `term-llm Computer Use.app` (inside `term-llm.app/Contents/Helpers` on macOS) | `LICENSE`, `THIRD-PARTY-NOTICES.txt` (`Contents/Resources`) |

Both the iOS and the macOS notification service extensions are nested inside
the app bundle above them and link no third-party code of their own, so the
app-level copy covers them. `term-llm-computer` is a command-line tool target,
which has no bundle to carry resources at all (`ComputerUseKit/Package.swift`
notes this); it is distributed as `term-llm.app/Contents/Helpers/term-llm-computer`
and symlinked to `~/.local/bin/term-llm-computer`, so the notices travel with
the enclosing app bundle. Anyone redistributing the bare binary or any other
artifact should copy `LICENSE` and `THIRD-PARTY-NOTICES.txt` next to it.

The `LICENSE` resource is the repository's own root file, referenced from the
Xcode project rather than duplicated, so the shipped text cannot drift from the
MIT grant in git.

## Contents

| File | Purpose |
| --- | --- |
| `THIRD-PARTY-NOTICES.txt` | The shipped notice document: term-llm's MIT text followed by each third-party license, verbatim. Generated; do not edit by hand. |
| `SOURCES.json` | Provenance for every license text: source URL, pinned revision or release, artifact checksum and SHA-256 of the exact text. Drives generation. |
| `Sparkle-LICENSE.txt` | Verbatim `LICENSE` from Sparkle 2.10.1, including Sparkle's own notices for bsdiff, sais-lite, ed25519 and `SUSignatureVerifier`. |
| `WebRTC-LICENSE.txt` | Verbatim `WebRTC.xcframework/LICENSE` from the WebRTC M155 binary artifact that is linked into both apps. |

The browser-use macOS harness text is not copied here: the canonical file stays
at [`ComputerUseKit/LICENSE-macos-harness`](../ComputerUseKit/LICENSE-macos-harness)
and `SOURCES.json` points at it.

## Refreshing

```sh
python3 scripts/check-license-notices.py --write   # regenerate the shipped text
python3 scripts/check-license-notices.py           # verify (default; offline)
```

To refresh after a dependency bump: copy the new license text over the file in
this directory (or point `SOURCES.json` at the canonical file), update its
`sha256` (`shasum -a 256 <file>`), version and revision in `SOURCES.json`, then
rerun `--write` and review the diff. The script fails when a recorded text's
digest changes, when a Swift package pin no longer matches the recorded
revision, when a request appears for a package with no notice, or when a file
in this directory is not referenced by `SOURCES.json`.

Pass `--bundle <path>` after a build to assert a produced `.app` really carries
the two files, byte-identical to this checkout:

```sh
python3 scripts/check-license-notices.py --bundle /path/to/term-llm.app
```

## Scope

The notice document covers code that is linked into, or embedded as a binary in,
the products users receive: Sparkle, WebRTC, and the browser-use macOS harness
that `ComputerUseKit` ports. It is not a claim to be exhaustive about transitive
licensing: Apple SDKs and system frameworks, Sparkle's vendored components
(whose notices Sparkle's own `LICENSE` reproduces, and which are therefore
included), and non-shipped tooling are out of scope. In particular the Go push
relay in `push-relay/` is server software operated by the maintainer, not part
of any app bundle, so its Go module licenses are not distributed here. Adding a
Swift package dependency to the app or helper targets requires adding its notice
to `SOURCES.json`; the check fails until then.
