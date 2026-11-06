# Native macOS companion (development)

The **TermLLMMac** target is a native macOS companion for a local term-llm
service. It is a real Mac app: a menu-bar item, onboarding, the server's own
authenticated web UI in a retained `WKWebView`, and diagnostics. It is **not** the
iOS app running as "Designed for iPad", and it is not a parity claim for the iOS
shell.

> **Delivery status: development/manual only.** Builds are ad-hoc signed on the
> test VM. There is **no Developer ID signing, notarization, stapling, Sparkle
> feed, automatic app update, or release pipeline implemented or verified here.**
> Do not ship or describe these builds as notarized or auto-updating.

## What exists

| Piece | Status |
|---|---|
| Native app target `TermLLMMac` | Implemented; builds with Xcode 26.2 on macOS 15 x86_64 |
| Menu-bar item | Implemented: status, open chat, start/stop/restart, two independent login toggles, diagnostics, quit variants |
| Onboarding/Setup | Implemented: CLI provisioning, owned service creation, authenticated chat, app login item |
| CLI installation | Implemented: bundled darwin payload → stable per-user runtime, manifest, checksum, backups, transactional replacement |
| Authenticated local chat | Implemented: real service, real bearer session, server web UI in WebKit |
| Diagnostics | Implemented: redacted copyable checks; no tokens |
| Computer use / macOS Harness integration | **Out of scope and deferred.** No bundled Python/PyObjC runtime or permission host ships in this app |
| Production signing/notarization/auto-update | **Not implemented** |

## Release architecture (v1 target, not implemented as a pipeline)

The intended first production shape is **one Mac release artifact**:

1. Pin a core commit/SHA (and its version) for the release.
2. Build the `term-llm` CLI from that pinned core, Developer ID-sign it, and
   notarize the payload as part of the release.
3. Build the app against that payload, embed it, and sign the app (and any
   nested code) with the same release identity.
4. Notarize and staple/package the completed app; publish the single artifact.

Do not release a managed CLI that updates itself independently. The app owns the
managed installation, verifies its checksum, keeps a manifest and can roll back;
the core refuses self-upgrade for those installations (see below). Core changes
between releases do not imply a Mac app release.

Current development delivery is manual: build the payload with
`scripts/macos/build-cli-payload.sh`, build the scheme with `xcodebuild`, and
install the `.app` locally. Payloads are not committed (they are large and tied
to a core revision), and CI does not produce or sign a Mac artifact.

## CLI provisioning

Layout under the user's home, deliberately outside the `.app` so Terminal use
survives moving or deleting the GUI:

```text
~/Library/Application Support/TermLLM/
  install.json                    selection + SHA-256 manifest
  bin/term-llm                    managed executable
  bin/term-llm.managed.json       ownership marker consumed by `term-llm upgrade`
  backups/<stamp>/term-llm        previous executable for rollback
~/.local/bin/term-llm             symlink, only when free or already ours
```

Behaviour:

- A bundled install is staged in the destination directory, hashed, and
  **renamed over** the live name with POSIX `rename(2)`. The previous executable
  is **copied** to `backups/` first, so the `term-llm` name never disappears
  between versions. The promotion holds an advisory cross-process lock and a
  digest cache avoids re-hashing the payload on every status poll.
- Marker and manifest are written after the replace. If either fails, the
  previous binary, manifest, and ownership marker are restored (or removed for
  a first install). This is covered by failure-injection tests.
- The app passes the payload's `sha256` sidecar as the expected digest; a
  mismatch aborts before touching the installed binary. A missing sidecar is
  reported as a development-provenance warning.
- An existing Homebrew/standalone installation can be adopted by reference. The
  app never copies, links, updates, or deletes it. Its package manager remains
  the owner.
- `~/.local/bin/term-llm` is created only when that path is free or already
  points at the managed binary. A foreign file or symlink is left untouched and
  reported as a collision. `~/.local/bin` is not automatically added to `PATH`;
  the app shows the path and does not edit shell startup files.
- Removing the app does not remove the CLI, service, config, or conversations.

### Managed-install guard and upgrades

The managed binary sits next to `term-llm.managed.json`:

```json
{"schema_version":1,"owner":"term-llm macOS companion","update_hint":"Update it from the term-llm macOS app, which verifies the payload and can roll back."}
```

`term-llm upgrade` resolves symlinks, finds that marker, and refuses before any
download, naming the owner. A corrupt marker still blocks. The intended app
update path is the transactional promotion described above; **no app
auto-update mechanism exists yet.** External/package-managed installs have no
marker and keep their existing upgrade behaviour.

## Local service and authentication

The app treats the core CLI as the service owner and only invokes documented
commands. It reads the versioned contract:

```bash
term-llm service status web --json    # schema_version 1
```

The app creates a fresh owned loopback service with an **explicit bearer auth
mode** (`service install web -- --auth bearer`). It does not rely on a default
that could change. The token stays in the core's login Keychain; the app reads it
on demand and proves it against the protected `/v1/capabilities` JSON endpoint
(not `/api/auth/session`, which bearer-mode web serves as a 200 text/html SPA
shell). The probe requires a non-redirecting 2xx `application/json` response with
the expected capabilities shape, with cookies and caches disabled, then injects
the token into the embedded web UI with a document-start script for that exact
loopback origin. The
web UI then keeps it in that origin's WebKit local storage (the same place its
normal token form would). The token never appears in a URL, a log, or
diagnostics.

The app's navigation policy allows plain HTTP only for the loopback origin
reported for the installed, managed service. The Info.plist ATS exceptions are
limited to loopback hosts, and ordinary remote HTTPS validation is unchanged. The
embedded view refuses to navigate outside the managed origin (external links open
in the default browser).

Start/stop/restart and the two login preferences are independent:

- **Local service running** — process state.
- **Start local service at login** — core autostart (`service autostart`).
- **Open menu-bar app at login** — an app-owned LaunchAgent.

Starting/stopping the service never rewrites autostart; the app uses
`start --no-enable` and `stop --keep-enabled`. The app login item is written for
the next login and is never bootstrapped while the app is running (that would
start a duplicate process). Quitting the menu bar leaves the service running;
"Quit and stop local service…" stops it and preserves the autostart preference.

### Passkey limitation in test environments

Core-owned passkey services remain supported by the core and its browser flow.
This app does **not** fake passkey success and does not downgrade an existing
service's authentication. On a Mac with a platform authenticator, enroll at
`/auth/setup` in a browser. On the x86_64 VM used for this development work,
Safari reports that saving a passkey requires iCloud Keychain and no platform
authenticator or security key is available, so enrollment cannot complete. The
development demo therefore uses the explicit bearer-loopback mode above for a
freshly created service.

## Build and test

```bash
# From a term-llm core checkout with frontend assets built:
TERM_LLM_CORE_DIR=/path/to/term-llm scripts/macos/build-cli-payload.sh

# Kit unit tests (Foundation only, no GUI)
cd TermLLMMacKit && swift test

# App build (unsigned/ad-hoc on this VM)
xcodebuild -project TermLLM.xcodeproj -scheme TermLLMMac \
  -configuration Debug -destination 'platform=macOS,arch=x86_64' build
```

The app build's "Copy CLI payload" phase copies `build/cli` into
`Contents/Resources/cli` when present. Without a payload the app still builds and
the Setup screen offers to adopt an existing installation.

## Known limits and non-claims

- Development builds are ad-hoc signed; no signing identity, notarization,
  Gatekeeper acceptance, or distribution packaging is verified.
- Only x86_64 macOS 15 in a VM was exercised. Apple Silicon, physical-Mac TCC
  persistence, and reboot/login autostart firing are unverified.
- Non-GUI SSH sessions cannot read the login-Keychain service token
  (`security` returns interaction-not-allowed); a Terminal in the logged-in GUI
  session works. This is a session property, not an app requirement.
- The menu-bar app is not sandboxed. It must run the CLI and manage the user's
  service; there is no computer-use permission host in this phase.
- The Mac target and kit currently build in Swift 5 language mode (the iOS
  target remains Swift 6); raising it is separate work.
- Multi-window, notifications, voice, music, and the iOS app's full feature set
  are not claimed for this target.
