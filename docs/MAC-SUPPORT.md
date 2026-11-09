# Mac support and tailnet connections

## Build the Mac app

Open `TermLLM.xcodeproj`, choose the **TermLLMMac** scheme and Run. It builds `term-llm.app`, a native macOS (AppKit + SwiftUI, macOS 14+) client compiled from the same `TermLLM/` sources as the iPhone/iPad app, plus the Mac-only code in `TermLLMMac/`. The **TermLLM** scheme is iPhone/iPad only; there is no Mac Catalyst or Designed-for-iPad build.

```sh
xcodebuild build -project TermLLM.xcodeproj -scheme TermLLMMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

That unsigned build is a compile check only. Without its Keychain entitlements every credential read and write fails (`-34018`), so no connection, This Mac included, can sign in. To actually use the app, run it from Xcode or build without `CODE_SIGNING_ALLOWED=NO` so it is team-signed. It keeps the iPhone app's bundle ID (`com.termllm.app`), app group and shared Keychain group, so settings, saved connections and credentials from an earlier Mac Catalyst build carry over. Credentials use the data-protection Keychain, as on iPhone, not the legacy login keychain.

Native AppKit is the point of this target: Mac Catalyst's WebKit has no `navigator.mediaDevices`, `MediaRecorder` or WebRTC (WebKit [bug 234953](https://bugs.webkit.org/show_bug.cgi?id=234953)), and no entitlement can enable them. AppKit's WebKit provides them, so Chat's voice recording and Live voice work as in a browser, and so does the native voice shortcut. The app is signed with the hardened runtime and the microphone/camera entitlements; macOS asks for microphone access the first time a page uses it.

The Mac app uses the desktop workspace, native window controls, a minimum 820 × 560 window, a menu bar and keyboard navigation. It opens on Agents and supports existing remote Hub/Direct Node connections without installing a local service. The client retains the same per-connection credential and WebKit isolation and the same retained Chat document across destination switches. Multiple client windows remain disabled pending the ownership work below; a separate local-service settings window is not a second client scene.

Chat hides macOS 27's floating **Write with Siri** button beside its composer and other multi-line fields (`ChatWebView` declines WebKit's affordance; `writingToolsBehavior = .none` does not hide it on macOS 27.0, [WebKit bug 327446](https://bugs.webkit.org/show_bug.cgi?id=327446)). Siri's writing help stays in the right-click menu.

**Local Service…** in the sidebar, File menu or Settings is optional. It opens a short native Mac window: one status line with the next step (Set Up, Start, or Open Chat), at most one notice, and the two login preferences. Versions, paths, other copies of term-llm, service details and the remaining controls are under **Advanced**. The app’s menu-bar icon exists from startup, even without a local service; opening Local Service adds its service controls to that menu. The menu-bar item, Local Service window and AppKit window lifecycle are compiled into the app (`TermLLMMac/`); there is no plug-in bundle or second process. A running local service that passes verification appears as **This Mac** in the app's connections on its own, already signed in, so nobody has to type a loopback address. **Open Local Chat** does the same and then opens This Mac in the full client's normal Chat workspace. It does not open an independent companion chat. Removing This Mac stops it from being added again until Open Local Chat is used. See [Local service on Mac](MACOS-COMPANION.md) for installation, authentication and lifecycle details.

### Local CLI ownership

**Set Up term-llm** installs the official signed/notarized core GitHub release
(minimum 0.9.94) into `~/.config/term-llm/app`, next to term-llm's own settings; the app never builds or
bundles a CLI. The app owns that copy, its `~/.local/bin` link, service binary
paths and CLI updates. Homebrew/install.sh/PATH copies and legacy external
selections are reported as migration required, never adopted automatically.
Explicit migration journals rebind and PATH changes; Homebrew removal is a
separate confirmed step with a dependents check. `service rebind` and graceful
`service reload` require a newer core release than v0.9.94 and are probed at runtime.

CLI checks run at launch/24-hour intervals and manually. Without reload support,
updates require an explicit service restart, not an automatic hard restart.
**Remove…** preserves core data; **Stop Managing…** leaves the binary/link/services
for `term-llm upgrade`. **Developer Mode…** (under Advanced) uses an explicit executable
and disables installation, updates, migration and PATH/marker management.
These CLI updates do not implement Mac app auto-update/Sparkle or app notarization.
Live launchd migration and graceful reload remain unverified; fixture tests are
not proof of live service behavior. See [the ownership guide](MACOS-COMPANION.md).

### Closing, reopening and quitting

- The red **×** and **Command–W** on the main client window **hide it**, keeping the app and its menu-bar icon running. The same window, native navigation and retained Chat document/draft remain in memory.
- Choose **Open term-llm** from the menu-bar icon or File menu (**Command–Shift–O**), or click the Dock icon, to restore that window. No new client window or companion app is created.
- **Quit term-llm** in the menu-bar menu, the app’s ordinary Quit command, and **Command–Q** actually exit. The independent local service is not stopped or reconfigured by quitting.
- Local Service has its own ordinary close behavior: closing that settings window stops its status polling, not the app or local service.
- A hidden/minimized main window is treated as background for client polling, linked-device foreground state, WebKit visibility and notification attendance. Keeping the tray alive does not opt into perpetual background polling. Playback is not stopped by window closure.
- **Open term-llm at login** remains a separate opt-in preference. Closing a window does not enable it.

**Platform differences:** Apple Music plays in-app through `ApplicationMusicPlayer` (macOS has no system Music player for apps). Podcasts need no audio-session setup on Mac. Notifications use a sandboxed Mac notification service extension (`TermLLMMacNotificationService`) sharing the iPhone extension's code, app group and Keychain group; the APNs environment comes from the app's signed `aps-environment` entitlement.

The build is not yet a signed/notarized distribution. Compiling the shared media, notification, voice and linked-device paths does not prove live Apple Music authorization/playback, APNs delivery, microphone/camera permissions or remote peer connectivity on Mac. Those require separate live checks; do not infer device-only parity from a build or fixtures.

The iPhone/iPad target no longer runs on Mac: Mac Catalyst and Designed for iPad/iPhone are both turned off.

Mac-only controls:

- **Navigate:** Command–1 through Command–4 select Agents, Chat, Music, and Podcasts.
- **Settings:** Command–comma.
- **Refresh:** Command–R refreshes Agents, or reloads the visible Chat. It does not reload a retained chat while another tab is selected. Music and Podcasts have no root refresh command.
- **Chat back:** Command–[ when the visible Chat has a back item.
- **Chat zoom:** View ▸ Zoom In / Zoom Out (Command–plus/minus) and Actual Size (Command–0, 100%); also in Settings → Chat appearance. This is WebKit page zoom, like Safari's: the page reflows at the window's width, from 75% to 200%, without navigating or reloading. iPhone/iPad are unaffected.
- **Listen:** secondary-click queue/history rows for the same actions as their swipe controls.

Commands act only while the client window is key, with no sheet or alert in front of it; plain text and system editing keys are not overridden. iPhone/iPad have no desktop menu commands.

Multiple windows remain disabled. `NOTIFICATION-OWNERSHIP.md` gates them on proving scene-specific notification routing and the current voice/listen singleton ownership. Enabling another scene without that work is not a safe UI-only fix.

## Adaptive workspace

The approved [desktop/iPad concepts](design/DESKTOP-IPAD.md) now inform the native larger-screen shell:

- Device selection, not window width, chooses the shell: iPhone keeps its original TabView; iPad and Mac use the workspace at all widths.
- The sidebar is 200pt on iPad / 220pt on Mac and persistent at 900pt and wider. Narrow windows use a dismissible overlay. A narrow Chat uses a 44pt leading navigation rail, not a floating button over the web header or composer.
- Agents, Music and Podcasts have quiet 52pt minimum native root headers. Pushed agent/playlist screens retain native Back navigation. Agents, Attention and Sessions remain available. Wide Agents lists use a readable bounded measure.
- Chat gets **no second native header**. Its frontend still owns the real header, typography, content width and composer. The concept's fictional chat and exact 760px/17px web design are not injected into remote pages.
- Resizing and destination selection use one stable content hierarchy. Retained Chat leaves the native window when inactive without being discarded; native destinations stay mounted and hidden. Authorization revocation still tears down a hidden protected document.
- A Mac window has a single title bar and toolbar, but every destination keeps its own navigation stack, so Mac destinations never put chrome there (a hidden page's back button or search field would otherwise stay over Chat). Pushed Mac pages (an agent, a playlist) draw their own header with Back, title, actions and search. Mac lists reorder by dragging; songs are removed from a playlist with its context menu.
- The shared playback shelf stays outside the scrolling destinations. Selecting a destination does not start or stop playback.

The HTML concepts remain design references, not screenshots of the app.

## Tailscale HTTPS

Ordinary saved connections continue to require trusted HTTPS. A Tailscale-looking hostname or `100.64.0.0/10` IP is not permission to bypass TLS or allow plain HTTP.

1. Connect Tailscale on the client device and the server host. Ensure both can access the intended tailnet and its access rules allow the service.
2. Use the **full HTTPS hostname covered by the certificate**, for example `https://desk.example-tailnet.ts.net/`, including any configured path prefix and port. A certificate for a hostname does not validate a URL using the host's IP address.
3. The server must actually serve HTTPS, for example via an appropriately configured Tailscale Serve endpoint. Enabling Tailscale alone does not turn a plain HTTP listener into an HTTPS service.
4. The configured mount's `/healthz` must identify a term-llm Hub or Direct Node without borrowing an existing connection's credentials. Discovery does not follow redirects or sign the user in. Tailnet network access rules still apply to this probe.
5. If this device is subject to Local Network privacy permission, allow the app access to the server network. The app includes a purpose string; it does not change OS permissions automatically.

Discovery now has a **15-second bounded request/resource budget** instead of three seconds, allowing more time for cold VPN/DNS paths. Cancellation still abandons the save. DNS, reachability, timeout, TLS, and HTTP failures surface sanitized, actionable guidance rather than all becoming “could not identify server.” Failed discovery cannot replace the current saved connection or its credentials. Migration still leaves failed role checks unresolved instead of guessing.

### Evidence boundaries

Protocol fixtures cover URL acceptance, request isolation/timeouts, response classification, sanitized errors, and catalog preservation. They do not prove real MagicDNS resolution, TLS handshakes, tailnet permissions, APNs delivery, MusicKit, capture, or device audio. Diagnose an individual report with its failure stage and error text; do not collect tokens, cookies, or pairing URLs.

### Native Mac validation

Built with Xcode 27.1 on macOS 27.0.1, team-signed with the local Mac development profiles (hardened runtime, microphone/camera entitlements, sandboxed notification extension).

- **XCTest:** `TermLLMMacTests` (the shared `TermLLMTests` suites plus Mac-only tests) ran 880 tests unsigned with 0 failures; the iPhone `TermLLMTests` suites ran 897 tests on an iOS 18.6 simulator with 0 failures. The opt-in live E2E/live-server suites were excluded from both.
- **Microphone capability:** a Mac test loads a `localhost` page in the app's own `BrowserView` and finds `getUserMedia`, `MediaRecorder`, `RTCPeerConnection` and `AudioWorkletNode`. That proves the APIs exist; it requests no capture and is not proof of a live voice session.
- **Mac-only fixtures:** close-to-hide with the retained document, delegate forwarding and attached sheets; menu commands refused unless the client window is key; Chat zoom range; the remote-only menu-bar item; the Local Service window's simple/Advanced states; the authenticated local-service handoff against a temporary home, synthetic CLI and loopback HTTP fixture. No real service, login item or Keychain item was used.
- **UI harness:** an isolated copy (separate bundle ID, demo fixture, no Keychain or push) showed the sidebar destinations, the Agents list, a pushed agent page with its own Back/search header, and Chat loading the fixture page with its draft kept across a switch to Music.

Not yet established: a live voice session (macOS permission prompt and capture) in a real chat, the hidden window title, Settings and other sheets, menu and close-to-hide behavior in the real window, push delivery, Apple Music playback, and handoff from a real local service.
