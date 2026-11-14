# Local service on Mac

Local CLI/service management is an **optional part of the native term-llm Mac app**. Build the `TermLLMMac` Xcode scheme; it produces `term-llm.app`, the full client (see [Mac support](MAC-SUPPORT.md)). The old chat-only companion and the Mac Catalyst build are gone.

The client has the same Agents, Chat, Music, Podcasts and remote connections as the iPhone app. **Local Service…** opens an AppKit settings window in the same process; its controller and `CompanionModel` (in `TermLLMMac/`) use `TermLLMMacKit` for provisioning and service management. It is not another app, service daemon, or app users must configure separately. Remote connections work without using it.

> **Delivery status:** once its signing secrets and profiles are configured, CI Developer ID signs, notarizes, staples and publishes every app change pushed to `main` as a GitHub release ([Notarized Mac builds](SELF-HOSTED-CI.md#notarized-mac-builds)). Sparkle 2 checks for signed app updates daily from `https://term-llm.com/mac/appcast.xml`; installation is user-confirmed. Public download publication requires the separate [Sparkle setup](SELF-HOSTED-CI.md#sparkle-updates). Builds run from Xcode stay development-signed; only CI release builds are notarized.

## What exists

| Piece | Status |
|---|---|
| Full Mac client | Native macOS target `TermLLMMac`, sharing the iPhone/iPad sources; window-toolbar destination selector, native menus and keyboard controls |
| Optional local setup | Native AppKit window in the app: one status line with the next step, details under Advanced |
| App menu-bar item | Present from startup; Open term-llm, optional Local Service and Computer Use, the App Updates submenu and explicit Quit. Service status/chat/start/stop/restart appear from launch for existing managed or Developer Mode installs, or after opening local setup |
| CLI installation | Official signed GitHub release → stable per-user runtime, signature/checksum verification, transactional replacement and backups |
| Authenticated local chat | Verified managed loopback service handed to the full client's isolated Direct Node source |
| Computer use | **Implemented, off by default.** Bundled native helper and `term-llm-computer` CLI running all eleven tools, per-app approvals, Stop/Pause, menu/settings lifecycle, and the term-llm-only `computer-use` skill; no Python runtime. See [shell integration](design/COMPUTER-USE-SHELL.md) for verification limits |
| Developer ID signing and notarization | CI on push to `main`, published as GitHub releases ([setup](SELF-HOSTED-CI.md#notarized-mac-builds)) |
| App updates | Sparkle 2.10.1; automatic daily checks and user-confirmed install/relaunch, separately signed appcast and archives |

## The Local Service window

The window opens in a short form:

- **One status line with the next step**, for example *term-llm isn't set up on
  this Mac* with **Set Up term-llm**, *term-llm 0.9.94 is installed* with
  **Start Local Service**, or *Running* with **Open Chat** and **Stop**.
- **At most one notice**, such as a service still running another copy of
  term-llm, an installed update that needs a restart, or Developer Mode being on.
  A notice has one button, or says why that button isn't available yet.
- A service running **another copy** (a checkout build or Homebrew) is reported by
  its real state, for example *Running · Using ~/Source/term-llm/term-llm* with
  **Open Chat** and **Stop**. Start, stop, restart and start-at-login act on any
  service the core manages, whichever copy it runs (the app's copy issues the
  core commands). Reinstalling is withheld because it would replace the binary;
  a quiet note says the app doesn't update that copy and offers the switch once
  the core supports it. Chat failures from the menu-bar item show an alert.
- **Start the local service when you log in** (shown only for a service
  the app controls) and **Open term-llm when you log in**.

**Advanced** is collapsed when the window first opens. It lists the version,
location, Terminal link, update checks, other copies of term-llm and the
service's status, address, sign-in, program and logs command, with Check for
Updates, Repair, Developer Mode…, Stop Managing…, Remove…, Restart, Reinstall
Service and Copy Diagnostics. Controls that can't apply in the current state are
hidden rather than disabled. The window sizes itself to its content. The status
line comes from `LocalServiceSummary` in `TermLLMMacKit`, a pure function with
unit tests for each state.

## Ownership: the app owns its copy of term-llm

**One source:** the official `term-llm/term-llm` GitHub release, the same files
used by Homebrew, install.sh and `term-llm upgrade`. The CLI has been Developer ID
signed and notarized since **0.9.94**, the minimum supported version. The app
never builds or bundles a CLI. The app itself is notarized separately, by CI
([Notarized Mac builds](SELF-HOSTED-CI.md#notarized-mac-builds)); app updates use Sparkle and do not replace or restart the managed CLI.

Choose **Set Up term-llm** in **Local Service…**. The app resolves
`https://github.com/term-llm/term-llm/releases/latest`, selects native hardware
arm64/amd64 (including under Rosetta), and downloads the versioned Darwin archive
and `checksums.txt` with an ephemeral, cookie/cache-free session. Before executing
a candidate it checks the exact archive checksum, extracts only `term-llm`,
rejects symlinks/special/empty files, and verifies all architectures with strict
Security-framework validation against identifier `term-llm`, the Developer ID
Application certificate OIDs and team `B6BAJ46A72`. It checks the semantic version
and schema-1 service-status smoke test. Failed downloads/validation never promote.

### Managed files and transactions

```text
~/.config/term-llm/app/
  install.json                     schema 2: source release, version, binary path,
                                   SHA-256, installedAt and release provenance URL
  bin/term-llm                     app-owned stable executable
  bin/term-llm.managed.json        ownership guard consumed by term-llm upgrade
  backups/<stamp>/                 previous binary + matching manifest/marker
  staging/<private-id>/            temporary downloads, always cleaned
  update-state.json                check time/error, skipped versions, last installed,
                                   services awaiting explicit restart or with an
                                   unconfirmed reload
  migration.json                   write-ahead migration/recovery journal
  migrated/<stamp>/term-llm        displaced Terminal regular file (never deleted)
  developer-mode.json              present only during explicit Developer Mode
~/.local/bin/term-llm              symlink to the managed executable
```

The folder sits with term-llm's own settings in `~/.config/term-llm`, so it is in
the same place on every OS. It is fixed under the home folder rather than following
`$XDG_CONFIG_HOME`, which GUI apps don't see. Earlier builds used
`~/Library/Application Support/TermLLM`. At launch the app moves that folder here
once, rewriting the paths recorded inside it and a Terminal link that pointed at
the old copy. A service whose definition still names the old binary keeps running
through a link left at the old location. That link is removed once no launchd or
term-llm service definition names it; switching the service moves it.

Promotion holds an advisory install lock, copies the previous binary and its
metadata to a backup, then renames a staged candidate over the live pathname.
The executable name never disappears during replacement. Marker/manifest write
failures restore the previous binary and metadata; rollback uses the same
transaction path and the newest backup. The three newest backups are retained.

The marker is schema 1, owner `the term-llm app`, app bundle ID `com.termllm.app`, and
instructs the user to update from the term-llm app. Its `update_hint` includes the
absolute marker path to delete if the app is gone and `term-llm upgrade` should
resume managing this copy. The app does not recreate a removed marker by merely
polling; it only rewords an existing marker of its own that an older build wrote. **Repair** explicitly reinstalls the latest verified release.

### Conflicts and explicit migration

Homebrew copies, other commands in common PATH directories, services running a
different binary and legacy external selections are **migration required**.
They are reported, never automatically executed, adopted, updated or silently
repaired. A schema-1 `bundled` manifest is an old managed installation requiring
an update (its version is not trusted); schema-1 `external` is a legacy selection,
not permission to execute that binary. Setup leaves a record of that selection
for migration. An occupied `~/.local/bin/term-llm` is left alone until confirmed
migration; the app never edits shell startup files or adds directories to PATH.

**Switch to the App's Copy…** (migration) requires a healthy signature/checksum-verified managed release,
Developer Mode off, an actionable conflict, and runtime support for
`service rebind`. Support is probed with `term-llm service rebind --help` and
requires that subcommand's own `Usage:` line: a CLI without the subcommand,
including 0.9.94, prints the parent `service` help and exits 0 (it does the same
for `service reload web`), so the exit status alone proves nothing. Probe results
and managed-binary verification are cached until the executable is replaced, so
status polling does not re-hash the binary. **v0.9.94 lacks rebind and reload**;
the commands are implemented in core but require a newer published release.
Unsupported migration is disabled with "Available after the next term-llm
release.", not emulated by reinstall.

After an NSAlert sheet lists the actions, migration:

1. Verifies the managed binary again and journals previous service paths.
2. Calls `service rebind web --binary <managed>` / `service rebind hub --binary
   <managed>` only for differing service binaries, then verifies the reported
   binary and readiness of services that were running. Core preserves auth,
   port, environment, secrets, autostart and running/stopped state. On failure
   the app rebinds recorded services back to previous binaries that still exist.
3. Records the Terminal occupant; moves a regular file to `migrated/<stamp>/`
   or records/removes a foreign symlink, then creates the managed link. It never
   modifies/deletes a checkout or the target of a foreign symlink.
4. Marks the journal complete. An incomplete journal exposes **Finish Switching…**
   and **Undo Switch…**, with a Finish Switching / Undo Switch / Later sheet at
   launch. Automatic CLI checks pause until recovery is resolved (explicit
   Repair remains available for a damaged managed binary). Failed recovery
   stays incomplete rather than claiming success.

**Remove Homebrew's Copy…** is a separate, explicitly confirmed action. Removal
needs a completed migration, so if none exists it runs the switch first and stops
there if that fails. It locates brew in the standard prefixes, runs
`brew uses --installed term-llm` and refuses if dependents exist or checking fails.
Only then does it run `brew uninstall term-llm`, without sudo/`--force`, with
`HOMEBREW_NO_AUTO_UPDATE=1`, and re-scan. Migration alone never removes Homebrew.
Other foreign commands remain reported until explicitly resolved by their owner.

### CLI updates (not app updates)

For an existing managed manifest with Developer Mode off, the app initializes
the model at launch and checks in the background, then every 24 hours while
running. Remote-only installations keep the local-service model lazy.
**Check for Updates** is also available manually. Equal/older and skipped/bad
versions are not installed automatically.

After installing a newer signed release, only running services whose binary is
the managed pathname are considered. Runtime support is probed with
`service reload --help` (same usage-line rule as rebind). With support, the app
calls `service reload web` or `service reload hub`. This **only requests**
SIGUSR2 via the core service manager: the previous process keeps serving until
its active work finishes, then re-execs, and the successor has no listener until
it starts. The app then polls status off the main actor:

- **Web with bearer auth:** authenticated `GET <base>/healthz` must report the
  installed version (redirects refused; the credential stays in the
  Authorization header). This is the only case where the new version is
  confirmed.
- **Passkey web and Hub:** no token is available, so a service that stays ready
  for 20 seconds is reported as **reload requested, version unconfirmed**.
- Unhealthy or stopped states are expected briefly during the start-up gap;
  only a failure lasting 30 seconds counts as a broken release.
- A bearer service still serving the old version after two minutes is also
  reported as unconfirmed (its re-exec waits for active work), not rolled back.

Without reload support, **no hard restart happens automatically**. The window
shows “An update is installed. Restart the local service to finish.” with a
confirmed **Restart Service…** button using `service restart <kind> --no-enable`. On a persistent failure the app restores
the previous binary/manifest/marker, restarts affected owned services, records
the failed version in `skippedVersions` and reports the problem. A busy service
that re-execs into a broken release after the app stopped watching is not
detected automatically; its status shows the failure. Services using other
binaries are never automatically restarted or reloaded.

### Remove / Stop Managing / Developer Mode

- **Remove…**, after confirmation, uninstalls only services whose binary is the
  managed path, then deletes the managed binary, marker, manifest, backups,
  staging, update state and only our own symlink. Core keeps configuration,
  conversations and credentials. Displaced migration files are not deleted.
- **Stop Managing…** (hand-over), after confirmation, deletes marker, manifest and
  update state only. The binary, link and services remain. The window then says
  “term-llm updates itself”; the copy updates with `term-llm upgrade`. Setup
  later installs a newly verified official release over the same pathname.
- **Developer Mode…** is visible and uses NSOpenPanel to choose an absolute
  executable path. It is an explicit opt-out of ownership: no install/update,
  migration, Homebrew removal, PATH or marker management. Service inspection,
  start/stop/restart, start-at-login and token access use that exact path; a fresh service's `--binary`
  also names the selected path. Leave Developer Mode to restore ownership
  controls. The setting is not an external-install adoption manifest.

Deleting/moving the GUI alone does not remove the CLI, services or core data.

## Local service and authentication

The app treats the core CLI as the service owner and only invokes documented
commands. It reads the versioned contract:

```bash
term-llm service status web --json    # schema_version 1
```

Local setup creates a fresh owned loopback service with **explicit bearer auth** (`service install web -- --auth bearer`). It does not downgrade an existing service's authentication or depend on a default that could change. The token remains in the core's login Keychain and is read on demand. Before handing a local connection to the client, the manager proves it against the protected `/v1/capabilities` endpoint, requiring non-redirecting 2xx JSON with the expected shape and no cookies/caches.

The in-process callback (`MacLocalServiceController.onConnection`) passes only the validated loopback base URL and bearer credential in memory. The client revalidates that URL (`MacLocalServiceBridge.request`), creates/reuses the explicitly flagged **This Mac** Direct Node source and authenticates it through the normal per-source authorization lifecycle. Credentials stay in that source's protected storage and isolated WebKit store. They never enter URLs, defaults, diagnostics or logs. An existing remote/linked source cannot be silently adopted as the local-service identity.

Reopening **This Mac** with the same saved credential reuses its identity and website preferences, including enabled and explicitly disabled WebMCP selections. An already-ready background attachment is left alone. Transient connection failures do not erase those preferences or credentials; a rejected credential, credential change, or explicit sign-in still uses the normal authorization reset. This preserves the frontend's own saved choices rather than forcing tools on.

**This Mac joins the app on its own.** Nobody should have to type a loopback address. When the app manages the local install (or Developer Mode is on), the manager checks the service at launch, then every minute until it is connected and every five minutes after that. The Local Service window and menu poll faster while they are open. Once the service is ready and its token passes the probe above, the same handoff runs without opening Chat: the host adds **This Mac** and signs it in, without switching tabs, stealing focus or showing an alert. It is offered again only when the address or token changes. A This Mac left on an old port is replaced rather than duplicated, and stays selected if it was. Removing This Mac stops automatic inclusion until **Open Local Chat** is used again. The unit-test host never starts this integration, because it shares the app's defaults and Keychain.

Only an explicitly flagged managed source can use its exact HTTP loopback origin/base path on Mac. Ordinary connection entry and imported links still require HTTPS; the local exception does not authorize arbitrary HTTP servers. WebKit navigation remains scoped to the connection mount and external links open in the browser.

Start/stop/restart and the two login preferences are independent:

- **Local service running** — process state.
- **Start local service at login** — core autostart (`service autostart`).
- **Open term-llm at login** — the system Open at Login registration
  (`SMAppService.mainApp`), listed as term-llm under System Settings › General ›
  Login Items › Open at Login. A build that can't register (for example an
  unsigned development build) falls back to the older app-owned LaunchAgent,
  which System Settings lists under Allow in the Background; when registration
  works, that agent is moved to Open at Login at app start.

In System Settings the local service itself appears under Allow in the
Background. Core releases newer than 0.9.94 attribute a service running the app's
copy to the app (from `app_bundle_id` in the ownership marker), so it is
listed as term-llm and asks for Local Network permission as term-llm. Older cores,
and services on other copies, use `com.term-llm.cli`; macOS shows whatever name
the app carrying that identifier has, normally **term-llm**. Attribution needs the app and the CLI signed by the same team.

Starting/stopping the service never rewrites autostart; the manager uses `start --no-enable` and `stop --keep-enabled`. The app login item targets the full Mac app and is written for the next login, not bootstrapped while the app is running. The two preferences live in Local Service. Closing the Local Service window stops its status polling without stopping the service. Closing the main client window hides and retains it; the app-wide menu-bar icon stays available to reopen it. Only explicit Quit exits the app, and even Quit leaves the service running; Stop Service is an explicit operation.

### Passkey limitation in test environments

Core-owned passkey services remain supported by the core and its browser flow.
This app does **not** fake passkey success and does not downgrade an existing
service's authentication. On a Mac with a platform authenticator, enroll at
`/auth/setup` in a browser. Earlier companion validation used an x86_64 VM where
Safari reported that saving a passkey requires iCloud Keychain and no platform
authenticator or security key is available, so enrollment cannot complete. The
earlier development demo therefore used the explicit bearer-loopback mode above
for a freshly created service. This does not establish passkey enrollment on the
current Mac build.

## Build and test

```bash
# Kit unit tests (Foundation + Security, no GUI)
(cd TermLLMMacKit && swift test)

# Mac app tests: the shared TermLLMTests suites plus TermLLMMacTests (window
# lifecycle, menu-bar item, Local Service view, authenticated handoff with a
# temporary home, synthetic CLI and loopback HTTP fixture; no real service)
xcodebuild test -project TermLLM.xcodeproj -scheme TermLLMMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:TermLLMMacTests

# Full Mac app (unsigned development compilation)
xcodebuild build -project TermLLM.xcodeproj -scheme TermLLMMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The Mac app links `TermLLMMacKit` directly; there is no plug-in bundle or CLI
payload copy phase. The kit links Security for signature verification. The
unit-test host is the app itself, so in a test run it shows a placeholder window
and starts no push registration, health monitoring or local-service integration.

Normal tests use temporary homes, signed `/usr/bin/true` copies, local tar/checksum
fixtures and FakeCommandRunner; no real services, Homebrew, Keychain, login items
or simulator state are changed. To verify the real latest CLI signature/version
in a temporary support directory without promotion or service queries, opt in:

```bash
(cd TermLLMMacKit && TERM_LLM_RELEASE_E2E=1 swift test --filter ReleaseInstallerTests/testOptInLiveLatestVerificationWithoutPromotion)
```

This live download check is skipped by default and is not relied on by normal tests.
Fixture migration/reload coverage does **not** verify live launchd migration,
SIGUSR2 delivery, graceful replacement after active work, or production health polling.

## Known limits and non-claims

- App updates check automatically but never install unattended: each installation needs confirmation. The [Sparkle test record](testing/MAC-SPARKLE-20261111.md) lists what the update flow has and has not been verified on. Gatekeeper acceptance of a CI release on another Mac, and production APNs delivery to it, are not yet verified. The official CLI release has its own signed/notarized distribution.
- Native setup and the shared client must be exercised together on Mac; kit fixtures alone do not prove the UI handoff or a live service.
- Login-item firing after reboot/login is not established by registering it, and Open at Login registration from an unsigned development build is not verified.
- Non-GUI SSH sessions may not be able to read the core's login-Keychain token. A logged-in GUI session is required when Keychain interaction is needed.
- The Mac service integration is not sandboxed: it must execute the CLI and manage the user's service. It is not a computer-use permission host.
- `TermLLMMacKit` and the local-service UI use Swift 6 with normal imports (no `@preconcurrency` compatibility import). `CLIProvisioner` is a checked-Sendable value retaining its home URL, Sendable runner and value-only test hook. It resolves Foundation's documented thread-safe `FileManager.default` per operation rather than retaining an arbitrary manager/delegate; custom `FileManager` injection is no longer part of its initializer. Configure value copies before sending them to workers. Construct non-Sendable orchestration helpers, such as `MigrationManager`, inside the worker rather than capturing them from the main actor.
- Live push delivery, media authorization/playback, camera permissions and linked-device connectivity require platform-specific verification. Shared source/build coverage is not a parity claim for those external capabilities.


## Updating the app (not the CLI)

**term-llm → Check for Updates…** and the menu-bar **App Updates** submenu
open Sparkle's standard update UI. Automatic checks default to once a day;
the app menu and submenu let you turn them off. Downloads/installations are
user-confirmed, not unattended. The Local Service window's update controls
continue to manage the CLI independently.

**Rollout:** 1.0.5 and earlier contain no updater. Install the first
updater-enabled release manually once; Sparkle can then update that installed
copy. This does not retrofit an updater into an already-running old app.

The production feed and versioned archives live under `https://term-llm.com/mac/`,
outside the docs site's deployment root. **These are public downloads**, despite
the source repository and GitHub releases being private. CI must be configured
before releasing an updater-enabled build; see [one-time setup](SELF-HOSTED-CI.md#sparkle-updates).
Sparkle's public key is injected into the built app, never the private key.
Missing/invalid key configuration disables the updater with a development
configuration diagnostic; it does not fall back to an unsigned updater.
Signed feeds (with no signature-failure expiration) and verification before
ZIP extraction are mandatory. Sparkle itself retains its upstream Developer ID
signed-DMG key-rotation fallback; this pipeline publishes ZIPs, not DMGs. Do not
change archive formats or rotate keys without reviewing that policy.

Replacing the GUI is separate from CLI installation and launchd ownership.
An app update must not stop the managed service or change its autostart/Open at
Login preference. The app's menu-bar item runs in the app process, not a
second watchdog. Computer Use is a separate bundled helper; update preparation
must drain it before the old bundle is replaced. The new GUI starts its own
helper normally, retaining the user's enabled/paused preference and owned CLI
link. The host app is **not sandboxed**; do not enable Sparkle's sandbox-only
installer/downloader XPC configuration or disable library validation. Xcode
embeds the complete Sparkle framework, including its installation machinery;
CI verifies/signs the resulting nested bundle before notarization.

For a local development demo only, a Debug build or an explicitly compiled
`SPARKLE_LOCAL_FEED_TEST` build can use `SPARKLE_FEED_URL=http://127.0.0.1:PORT/appcast.xml`
and a throwaway `SPARKLE_PUBLIC_ED_KEY`. Menus label the local test feed. No
runtime preference/environment switch can redirect production builds to that
feed. Never use a throwaway key or that build condition for a distributed build.
A normal Release accepts only the production HTTPS feed.
