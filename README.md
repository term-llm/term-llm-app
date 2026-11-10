# term-llm for iPhone, iPad and Mac

**One codebase, two app targets.** Open `TermLLM.xcodeproj` and select a scheme:

- **TermLLM** for iPhone and iPad. Choose an iPhone simulator, or a signing team and device, then run.
- **TermLLMMac** for the native macOS app. Mac-only code lives in `TermLLMMac/`.

Both compile the shared `TermLLM/` sources. The [desktop/iPad visual concepts](docs/design/DESKTOP-IPAD.md) remain design references, not screenshots of the app.

The Mac app is the full client, not a separate chat-only companion: Agents, Chat (including voice: it uses AppKit WebKit, which has the microphone capture Mac Catalyst's WebKit lacks), Music, Podcasts, saved connections and desktop navigation, plus optional local-service management and optional [Computer Use](docs/design/COMPUTER-USE.md) for term-llm agents. Remote connections do not require a local CLI or service. See [Mac support](docs/MAC-SUPPORT.md) for controls and build commands.

Once its signing secrets and profiles are configured, the self-hosted [notarized Mac build](docs/SELF-HOSTED-CI.md#notarized-mac-builds) Developer ID signs, notarizes and publishes every app change pushed to `main` as a GitHub release and as a signed [Sparkle update](docs/MACOS-COMPANION.md#updating-the-app-not-the-cli).

**Local service on Mac (optional).** **Set Up term-llm** downloads and verifies the official signed core GitHub release (minimum 0.9.94); the app never builds or bundles the CLI. A running local service that passes verification appears in the app as **This Mac** on its own, already signed in. [Local service on Mac](docs/MACOS-COMPANION.md) covers CLI provisioning and service ownership in detail.

- The app owns the per-user copy, Terminal link, service executable paths and CLI updates. Homebrew/PATH copies require explicit migration, not adoption. Developer Mode uses an explicit executable without managing it. Remove and Stop Managing are separate confirmed operations.
- **Local Service…** shows one status line and next step by default; details and these controls are under **Advanced**.
- Rebind/reload need a newer published core release than v0.9.94 and are detected at runtime; live launchd migration/reload are not yet verified.
- CLI updates and app updates are separate: the app updates itself through Sparkle (**Check for Updates…**, automatic daily checks, user-confirmed installation), which never replaces or restarts the managed CLI.

**App layout.** The app opens on **Agents**, an online-only list of the agents reachable through your saved connections (**Show offline agents** in Settings → Connections adds offline ones, greyed out).

- **iPhone:** four persistent bottom tabs: **Agents · Chat · Music · Podcasts**.
- **iPad:** the same destinations in an adaptive sidebar, persistent in wide windows and an overlay in narrow ones, with Settings at the bottom and quiet native root headers.
- **Mac:** a compact, labelled window-toolbar selector, leaving Chat's embedded conversation sidebar as its only sidebar. Settings is in the app menu (Command–comma).

The single **Settings** gear on Agents holds **Connections** (adding, editing, signing in, and remote administration), the **Voice shortcut**, **Device tools**, notification preferences, and other app-wide settings. Add an existing **Hub** or **Direct Node** by HTTPS URL (with an optional name); the server type is detected automatically. **Try demo** works without your own server; its replies are scripted and its chats reset on reload.

Chat uses the existing term-llm web UI and its own header; there is no duplicate app header over it.

**What Chat returns to:** the exact retained browser page, not an arbitrary agent or server root.

- The tab uses a single stable **Chat** label; the agent’s own page identifies the conversation.
- Before opening a conversation it offers **Choose an agent**. After an app restart, or after that connection is removed/replaced, no live browser workspace is assumed.
- Switching tabs keeps the existing document, draft, and scroll position. Authentication revocation still closes the protected document.

**Playback.** Music and Podcasts are native destinations; their players feed a shared playback shelf above the tabs. Browsing never starts or stops audio. Both playback panels have an **×** that hides the panel without stopping audio; selecting a new item or resuming playback can restore it. Tabs use the system appearance (Liquid Glass on iOS 26), with native playback accessories on iOS 26.1+ and an above-tab shelf on earlier systems. Agent rows use adaptive primary/secondary text instead of tint-colored content.

## Phone-owned Hub: two HTTP-only slices

1. **Saved connections:** add, edit, remove and select automatically detected Hub/Direct Node connections, including path-prefixed URLs. The catalog stores names, kinds, URLs and stable identities—not credentials. Existing `serverURL` becomes the first saved connection; a bounded role check verifies its kind, or leaves it unresolved for retry rather than treating a timeout as evidence. The selected URL remains mirrored for existing Listen, push, voice and device-tool settings.
2. **Unified views:** Agents, Attention and Sessions include source provenance and source-qualified identities, so two Hubs may both contain a node called `dev` without collisions. Each connection reuses its own native `HubStore`, with its own retry and authentication state; slow, offline or unauthorized sources do not hold up healthy sources or sign them out. Hub-specific Manage/Security remains available per Hub; a Direct Node is not presented as having Hub administration APIs.

**Existing HTTPS sources keep their existing APIs.**

- A remote Hub remains responsible for reaching and authenticating its nodes: the app follows that Hub’s validated proxy routes, never its private node addresses.
- A Direct Node uses its own health, session-status and durable-attention APIs.
- Linked devices is a separate, host-keyed source type. After protocol-v2 QR or pairing-link approval, a linked client carries the same native Direct Node reads, streamed browser chat and host-advertised Live voice over an authenticated WebRTC DataChannel. It does not alter, proxy or replace normal Hub/Direct Node HTTP behavior; see [Linked devices native client](docs/LINKED-DEVICES.md).

**Credentials and isolation.**

- Each saved source owns isolated WebKit website data.
- Direct-node bearer credentials are held in connection-scoped Keychain storage. Native mutations send the Authorization header, and a narrowly scoped document-start script supplies the existing frontend’s token storage before chat starts.
- No credentials are placed in connection URLs, catalog defaults or logs.
- Changing a connection’s endpoint or kind creates a new trust identity rather than sending the old credential to a new server.
- Moving an existing connection into its isolated website-data store can require signing in again; legacy URL migration does not imply that ambient browser credentials are copied.

The original single-Hub simulator protocol fixture remains available for its existing regression journey. A separate, visibly labelled **DEMO FIXTURE · LOCAL** multi-source fixture exercises two Hubs with colliding remote identifiers, a Direct Node, saved-catalog relaunch, and slow/unauthorized source isolation. These are HTTP protocol fixtures with static chat HTML—not real remote agents, passkey ceremonies or model execution. See [phone Hub capture and verification](docs/PHONE-HUB.md).

## Native Hub

The remote Hub protocol is pinned to core **2496b5fd**. The phone home is native even without a server.

- New connections detect their type automatically using a bounded, credential-free health check; failed discovery offers retry rather than guessing.
- **Agents**, **Chat**, **Music**, and **Podcasts** are native tabs outside WebKit. Returning to the phone Hub does not wait for a stalled chat request or evaluate JavaScript.
- Chat, native push, device tools, and live voice keep their HTTP/browser paths; the app does not implement a Hub’s reverse-node tunnel machinery.

Native screens cover:

- **Agents:** online/offline filtering, health/connection diagnostics, active and recent sessions, resume and new chat, and session details. Server-provided routes already include the Hub mount and are validated rather than prefixed a second time.
  - iPhone shows a list; on Mac and iPad the Agents panel is a page.
  - With one agent, the page shows that agent's status and counts, **New conversation** and **All conversations**, then what needs you, what is running, its pins and recent conversations (the agent's first history page).
  - With several agents, each gets a card with its health, activity and three most urgent conversations.
- **Agent page:** tapping an agent opens its page on the Agents stack; the ✎ on its row still starts a new chat in one tap.
  - The page leads with **New conversation** (it moves into the toolbar once scrolled away), then the agent's pinned conversations in their saved order, then its whole history grouped by date and fetched 30 at a time as you scroll (`GET /v1/sessions?scope=all&limit=30&cursor=…`; Hubs through `/node/<id>/v1/…`).
  - It opens at once from the dashboard's cached rows, keeps its place across Chat round-trips, and drops its history when the connection signs out.
  - Swipe or long-press a conversation to pin or unpin, rename, mark seen, copy its link or archive (with Undo); drag pins to reorder. Pins and titles are the node's own (`PATCH /v1/sessions/{id}`, `PATCH /v1/sessions/pinned-order`), so they match the web sidebar.
  - Search asks the agent's `/v1/sessions/search`.
  - Linked devices are read-only here: their host does not accept metadata edits from the phone.
- **Attention:** input-required items, unseen results, exact per-item seen acknowledgements, clear-all with partial-failure reporting, and larger aggregate result windows up to the server’s **500-item** maximum. The Hub exposes `limit`/`has_more`, not a cursor; the app does not invent cursor pagination. Opening a row alone does not mark it seen.
- **Delegations:** cross-node status, prompt/result/error, agent/model/directory, chain/parent, and job/run identifiers. These are the browser’s read-only delegation summaries—not a new job scheduler or create/cancel API. Responses are native selectable text; embedded Markdown artifact images are not rendered inline.
- **Manage:** test/add a node, remove local-store nodes, reorder dashboard slots, and inspect registration availability. Registration tokens require explicit reveal. Resolver-owned nodes are not falsely presented as editable/deletable local nodes. There is no server node-edit endpoint.
- **Security:** native passkey metadata/rename, session count, revoke-other-sessions, sign-out, and explicit browser ceremony guidance. Token-authenticated Hubs use a native secure token field; tokens are validated through an Authorization header and retained only in a scoped WebKit cookie, not in pairing URLs or defaults.

**Passkey limitation:** arbitrary self-hosted domains cannot be assumed to authorize this app’s native passkey RP through Associated Domains/AASA. Existing system-browser native sign-in remains supported.

- Additional-passkey creation and recent-authenticated removal require the browser Hub’s **Security** panel in this server version. The native app opens the actual configured Hub root and tells you to choose Security; it does not invent `/auth/security` or a deep-link query.
- Browser reauthentication does **not** grant recent authentication to the separate native session issued by the login handoff, so native credential removal is not advertised as a working ceremony. Complete protected add/remove operations in the browser, then refresh the native list.
- A scoped server-owned security-operation callback bridge is follow-up work, not implemented parity.

**Request isolation.** Each HTTP request uses an ephemeral URLSession, manual exact-host/mount-scoped WebKit cookies, blocked redirects, no ambient credential/cookie cache, bounded timeouts, and the real Origin requirement on mutations.

- Authorization failure purges native private state and closes the retained protected WebView instead of letting Chat reveal its old DOM.
- Hidden chat cannot renew native notification attendance or acknowledge attention.
- No private dashboard cache is persisted.

**SDK response-exposure limit:** revocation happens **as soon as iOS exposes the 401/403 response, before body completion**, not instantly when headers reach the socket.

- Real Xcode 26.2 simulator controls showed the same behavior for **200, 403, and 401**: headers with zero body bytes produced no response callback during the observation window. Sending the first body byte exposed the response, and 401/403 revocation ran exactly once while the rest of the advertised body remained stalled. Complete-body responses and an independent Python server control also worked.
- A bare-header stall may therefore remain unreported until the 30-second network timeout. A timeout alone does not establish an authentication failure, so previously displayed data is not automatically revoked on that inference. Native Hub navigation remains reachable independently of the stalled request.
- The zero-byte case remains in the diagnostic matrix; the privacy regressions assert revocation before **body completion** after the SDK exposes a response. These simulator results are not physical-device or universal SDK guarantees.

### Connection handoff

A credential-free `termllm://connect?server=<percent-encoded-HTTPS-Hub-root>` link opens a native confirmation/review form.

- It never automatically connects or signs in, and rejects embedded credentials, query tokens, duplicate fields, and localhost pairing addresses.
- Custom links work only after the app is installed; this is **not** an install/deferred-link service, and no redirector, public service or tunnel is provided.
- Universal links need an owned HTTPS landing domain, Associated Domains entitlement, its AASA file, and a genuinely phone-reachable Hub route. A cheap redirect cannot make a contain workspace’s localhost URL reachable. See [contain-to-app onboarding prerequisites](docs/CONTAIN-APP-ONBOARDING.md).

Local simulator captures use a real loopback HTTP **protocol fixture**, not production Hub state; see [capture documentation](docs/NATIVE-HUB-CAPTURE.md).

- Only Debug simulator builds accept `TERMLLM_NATIVE_HUB_FIXTURE_URL=http://localhost:8766/`.
- Onboarding still runs; defaults and WebKit cookies are isolated, push/device-tool enrollment is disabled, and every captured screen says **DEMO FIXTURE · LOCAL**.
- The fixture does not prove real passkey ceremonies, node reachability, push delivery, or voice.

## CI budget policy

All CI jobs target the repository-scoped MacBook runner labelled `[self-hosted, macOS, ARM64, term-llm-local]`. **There is no GitHub-hosted fallback.** If the Mac is asleep, offline, or its runner is stopped, checks queue rather than consume hosted runner minutes. Workflows use installed tools and do not use Actions caches or upload artifacts.

Automatic trusted, same-repository pull-request checks run in one path-filtered job (`Lightweight checks / checks`): Python fixture/helper tests, notification contract/JavaScript checks, and Go push-relay build/tests. Superseded runs are cancelled; the job has a 10-minute limit. No simulator user journeys or video captures run in CI.

**Native notification checks (manual local Mac)** remains available through **Actions → Run workflow** for unsigned app/extension compilation and focused simulator XCTest coverage, also on this Mac. Portable checks alone do **not** compile the iOS app. Hub capture scripts remain local-only.

See [MacBook runner setup and daily workflow](docs/SELF-HOSTED-CI.md). Changes must be pushed before GitHub uses this configuration; registering a runner alone does not reroute old hosted workflows. Existing GitHub artifact/cache storage is not deleted by this change. Review repository Actions billing/budgets separately for a hard spending limit.

If branch protection requires retired `capture`, `test`, or `simulator` checks, update those requirements. Avoid requiring a path-filtered workflow without accounting for docs-only PRs: GitHub may otherwise wait indefinitely for a skipped workflow.

## Guided demo

The public demo uses scripted replies, not AI. Its chats reset on reload. Native device actions are real and their saved data is **not** cleared by reloading the demo.

To try the native playlist integration:

1. Return to **Agents** and open **Settings**.
2. Under **Device tools**, enable **Share device tools** and tap **Done**. The switch covers every saved connection and is never enabled automatically by **Try demo**.
3. In the chat, tap **+ → MCP servers**, enable the **iPhone/iPad** entry labelled **WebMCP from this page**, and close the dialog.
4. Send **create playlist**. The scripted demo calls `playlist_create_demo` through the ordinary WebMCP flow. It creates a real local playlist with five fictional sample songs, without Apple Music authorization or playback. Repeating the command reuses the sample playlist without overwriting edits.
5. Open the **Music** tab to inspect, rename, reorder, or delete the playlist. Sample songs are explicitly non-playable; use Apple Music search to add real songs.

The demo also supports **list playlists**, **ping**, and **device info** when their tools are enabled. It does not automatically request location, microphone, or Music permissions, and it does not simulate voice or Apple Music playback.

For the opt-in simulator integration check, build/serve the sibling repository's demo and run:

```sh
# In ../term-llm: node demo/build.mjs && python3 -m http.server 8765 --directory demo/dist
TEST_RUNNER_TERMLLM_DEMO_E2E_URL=http://localhost:8765/ xcodebuild test \
  -project TermLLM.xcodeproj -scheme TermLLM \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TermLLMTests/WebMCPLiveServerTests/testDemoCreatesNativeSamplePlaylistOnlyAfterMCPOptIn
```

This exercises the real frontend MCP switch and native playlist store with Apple Music denied, using an isolated test library rather than modifying the user's playlists.

**HTTPS is required on devices**, including for self-hosted servers.

- For local testing in the **iOS simulator only**, enter `http://localhost:8080/ui/` while term-llm is running on your Mac; the simulator shares the Mac's localhost. HTTP is restricted to `localhost` in simulator builds, not remote hosts or physical devices.
- On Mac, entered addresses also require HTTPS. The managed **This Mac** connection and the Linked devices bridge are separate, validated loopback exceptions.
- Configure a trusted certificate or an HTTPS reverse proxy for device testing; microphone/WebRTC and other browser features may require a secure context.
- External links open outside the app. The camera and microphone permissions are requested by WebKit when the site needs them.

## Notifications and roadmap

**App icon badge.** The native red badge shows the last synchronized **Attention** total: needs-input plus unseen across verified saved connections, using server totals rather than the loaded page of items.

- It clears at zero and when app notifications are turned off, and respects iOS notification/Badges permission.
- Ordinary refresh failures retain previously verified totals; authorization failures remove that source’s count.
- The badge adds no background polling and does not infer counts from incoming push messages, so it updates when the app synchronizes Attention.
- Connections are polled only while Agents is on screen. Leaving it keeps polling for 10 seconds, so quick tab switches cost nothing; coming back after that refreshes at once.

**Turning notifications on.** Native notifications use one switch: turn on **Settings → Notifications** (or tap Enable in a site's own notification settings, which does the same). iOS asks for permission once.

- Each server or hub agent enrolls through its authenticated page.
- Per-site off and the app-wide switch persist local opt-out shared with native delivery handling.
- Server cleanup handles survive failure and retry when the corresponding authenticated pages reconnect; unopened/offline nodes can remain pending. Settings shows pending cleanup and shared-storage problems.
- The app switch is not iOS permission revocation and cannot guarantee cancellation of an already in-flight remote alert.

**Alert text.** Alerts identify the sending agent: generic messages show its name (for example **Dev** above **hello**), and completion alerts name the chat (for example **Dev: Fix flaky CI** above **Response ready**) without repeating an existing prefix. Neither line repeats the app name, which iOS already shows and Siri says first; `CFBundleSpokenName` (`Term L L M`) asks text-to-speech to spell it out (unverified for Siri's announcements).

**Tapping a notification.**

- Multi-scene creation remains disabled while singleton action behavior is unproven, so a v2 completion tap opens its page in the app's only window: that window is the owner, or replaces one iOS discarded. The app does not ask iOS to activate a scene for it; iOS rejects every such request in single-scene mode, even for the existing window.
- With multiple scenes, a completion tap targets its owning native scene, or requests a fresh scene if that owner is gone; it never selects the first arbitrary sibling. If iOS cannot show either, the app offers **Open Here** for the current window instead of dropping the tap.
- A plain `term-llm notify app` message opens that agent's page in the current key scene, without creating a new scene.
- Hub-local chat paths are rebased onto the agent's public hub mount. Pushes from another configured origin do not navigate.

**Delivery state.**

- Each enrollment uses a distinct Web Push authentication secret, so agents sharing a VAPID key cannot overwrite one another's destination.
- Already-delivered notifications retain their original route and v2 event/read metadata. Grouping includes source scope and chat.
- Foreground completion suppression uses the owning scene's fresh policy-derived attendance lease—not merely matching the visible URL.
- Exact successful server attention ACKs clear only that source/store/session through the acknowledged sequence; opening a page alone does not clear newer/unseen work.

**Shared state.** The app and extension require the **Application Group `group.com.termllm.app.shared`** in both signing profiles. See [native notification contract and verification limits](NOTIFICATION-OWNERSHIP.md) before rollout.

- Optional v2 completion capability fails closed if shared state, consent resources or a live committed document binding is unavailable.
- A shared-keychain consent journal preserves off through app-group write failure/restart; failed persistence is reported, not acknowledged as success.
- Recognized manual/legacy messages retain compatibility when no consent state is established (including missing app-group storage); explicit off remains respected, and unreadable state that may hide off is not guessed.
- Replay handling is bounded and persistent, but an NSE cannot cancel every alert remote push: quiet/empty cards or expiry placeholders are still possible.

**How it works.** WKWebView has no service workers or Web Push, so the app injects `window.__termLLMNativePush` for the configured server.

1. term-llm's web UI uses it instead of a service worker and registers the returned subscription with its own node through the normal `/v1/push/subscribe` API.
2. The subscription's endpoint is the [push relay](push-relay/README.md), which forwards the still-encrypted message through APNs.
3. A Notification Service Extension decrypts it on the phone with keys kept in the keychain (shared with the extension).

Relay and APNs configuration:

- The relay URL comes from the `TERMLLM_PUSH_RELAY_URL` build setting; for local development launch with `-push.relayURL http://localhost:8080`.
- Builds run from Xcode use the APNs sandbox; TestFlight and App Store builds use production. APNs key scope is determined by Apple, not the relay: do not assume one key covers both environments.
- The relay must be configured with a key that covers the environment being used, and development registration is rejected while `RELAY_APNS_ENVIRONMENTS` omits it.
- The relay's registration API is unauthenticated and its process-wide budgets limit abuse; they are not device attestation (App Attest is not implemented). See the [push relay documentation](push-relay/README.md) for the sandbox-capable key requirement and the full trust model.

This needs a term-llm server whose web UI supports the native bridge and sends Web Push with a 2048-byte record size. Sites that a device has never opened in the app do not receive scheduled `term-llm notify` messages until they have been opened once.

The app-owned Linked devices bridge is a separate, validated localhost origin—not permission to enter arbitrary HTTP server URLs on a physical device. Its browser Live support requires matching host and client updates, and retains WebKit's microphone permission prompt.

For live voice, the app declares iOS background audio so an active WebKit microphone/WebRTC call can continue after locking the phone on supported iOS versions. Start the call before locking; this does not start voice in the background or guarantee recovery from network changes, system interruptions, or an app force-quit. Verify capture and playback on a physical phone (the simulator is not a reliable lock-screen audio test).

**Chat controls.** Chat and its live voice controls remain web-based; a native voice transport remains future work. The agent’s own header is the only header in Chat, and the persistent bottom tabs remain available. **Chat** reveals the same retained page without a reload; its tab label stays simply **Chat**.

- **Agents** holds the only primary app Settings gear; **Connections** is inside Settings.
- On iPhone and iPad, pull down from the top of the web page for floating **Back** and **Reload** controls; Music and Podcasts already have their own tabs. On Mac, Back and Reload are menu and keyboard commands instead.
- A compact first-use coachmark explains the gesture: **Try it** reveals the controls and **Got it** dismisses the hint. Learning/dismissing it is remembered across launches.
- Each control target is at least 44 points. The overlay does not reload the web page, and when hidden it intercepts no touches. VoiceOver's **App controls** action and browser back-swipe remain available.
- Server errors offer Retry; manage connections in **Settings → Connections**. Authentication-required responses offer passkey sign-in.

## Voice shortcut and Action button

Open **Settings → Voice shortcut** and choose the **Agent** to call. The picker lists the agents of every saved connection, grouped by connection (linked devices cannot be targeted), and one choice applies app-wide. Choosing an agent does not switch the chat. **Start live conversation** runs the same launch flow as the shortcut.

On an iPhone with an Action button, open **iOS Settings → Action Button → Shortcut** and choose **term-llm → Start Live Conversation**. The action is also available in Shortcuts and Siri, including on Mac. The app cannot assign the physical button itself.

The shortcut opens the app in the foreground, navigates to a fresh conversation (`?new=1`), waits for the web composer, and activates **Start live voice** once.

- It leaves an existing active call alone, including when a different agent is selected for the shortcut.
- Live must be enabled on the destination server. If sign-in is required, complete the passkey flow; if the agent's connection is signed out or unavailable, sign in through **Settings → Connections** or choose another agent.
- Failed or unavailable Live startup shows a native explanation rather than repeatedly clicking or toggling voice.

The integration uses the web UI's accessible Live controls, not a native voice transport or background call. Automatic microphone/audio activation, first-time permission prompts, and Action-button launch from a locked phone still require physical-iPhone verification; iOS may require unlocking or tapping Live on the page. Simulator tests cover routing, discovery/authentication boundaries, and one-shot button activation, not a real microphone call.

## Browser lifecycle

Returning from the background keeps the existing web view and does not force a page reload, preserving the live workspace while WebKit remains alive. If iOS terminates the web content process:

- The app reopens the current same-server route with a fresh GET when active (or falls back to the configured server URL).
- Recovery waits while the app is inactive or signing in, and does not override sign-in or server/network error screens.
- A second termination within 30 seconds stops automatic recovery and offers Retry instead. Retry, a server change, or successful native sign-in resets the retry budget.

This does not persist conversation snapshots or restore JavaScript memory after process loss. Unsent text and live-session reconnection after a reload depend on the server's web UI. Physical-device memory-pressure and background voice testing are still necessary.

### Web page health

To explain a phone that runs hot, the app watches the chat page and the device. **Settings → Web page health** shows:

- the thermal state, this app's CPU, device-wide CPU (which includes WebKit's separate page, GPU and network processes), and the chat page's own activity;
- findings, a one-hour CPU chart and a history kept across launches, with a report to share or copy.

The page activity comes from a small script injected into the configured server's main frame. It covers main-thread blocking (a 1 s heartbeat), animation frames, running CSS animations (by name and element class, and whether they repaint every frame), DOM changes, requests, and open Web Audio, WebRTC, WebSocket and media. Reports carry only counts and code names, never page text, form values or addresses.

Background/foreground transitions and long native sampling gaps reset the page activity window without replacing Chat. A native-issued window token rejects queued pre-reset reports; only fresh acknowledged reports re-arm stall detection. The probe also resets heartbeat timing on page visibility/lifecycle changes, so suspension time is not reported as a long JavaScript task.

Shared reports (schema 2) preserve native CPU evidence even after recovery or relaunch:

- At app CPU ≥30%, at most every 30 seconds, the journal records the busiest native threads (names, process-local thread IDs and decaying scheduler CPU estimates), app/page state, page-report age, wakeups and memory. Recovery records the observed episode span and peak. These are bounded by the 300-event journal; clearing history also resets episode tracking.
- **Copy for diagnosis** puts a compact, self-contained report on the clipboard for pasting into an agent chat: current state, selected CPU/critical events with repeat counts, peak/boundary minutes, and peak/latest raw samples. Selection and omissions are explicit; it is not an automated diagnosis.
- **Share full report** exports a UTF-8 attachment with all retained events, minute peaks and memory, raw-sample intervals and state, and measurement limitations. Temporary export files are removed when the share sheet closes.

Thread counters cannot identify hot functions; capture a physical-device Instruments Time Profiler trace for stacks. No chat text, request addresses, credentials or cross-thread stack memory is collected.

**Stop runaway pages** (on by default) closes the chat page's web view in these cases:

- it misses its heartbeat for 45 s on screen while at least half a core stays busy outside the app;
- off screen for about two minutes, it keeps drawing or animating as if visible, keeps its main thread busy, polls (30+ requests a minute) or runs Web Audio without a call;
- the phone is hot (serious or critical) and the page is still running off screen.

A page that is still shown counts as on screen when its scene is merely inactive: a Mac window without focus, iPad multitasking, Control Center. **Hidden page runs at full speed** is reported only after two visible reports sent at least 10 s after Chat was hidden; the reports it sent while on screen don't count.

The page is never stopped during a live call, a voice launch, a device-tool reply, sign-in, or while the page plays media.

- Closing first runs the page's beforeunload listeners and navigates it to `about:blank`, so its pagehide/unload handlers run and the web UI saves an unsent draft. The view is then released, ending its web process.
- A page stopped off screen reopens at the same route when Chat is shown again; a hung page, or one closed with **Pause chat page**, offers Reload.
- About 40 s after a close, the history records device and app CPU before and after, which shows whether WebKit was the cause.

Watching is cheap and reports its own cost on the same screen. In simulator measurements, one native sample took about 0.3 ms every 5 s (0.006% of a core). The page script used 0.06–0.1% of a core when reporting every second; at its real rates (every 5 s on screen, every 15 s hidden) that is about a fifth. In the background (playing audio), samples drop to every 30 s.

WebKit behavior measured while building this: setting `isHidden` on a web view does not throttle its page (it stays "visible" at 60 frames/s); only leaving the window does, which the tab view does for inactive tabs. WKWebView never fires `beforeunload`, so the web UI's beforeunload draft save does not run on ordinary reloads in the app. The simulator reports the Mac's CPU as device CPU; heat itself needs a physical phone.

## Music

The **Music** tab shows what's playing and the playlists saved on this phone.

- Create, rename, reorder and delete playlists, and add songs by searching Apple Music. Tap Play or Shuffle, or tap any song to start from there.
- Playback goes through the system Music player, so the lock screen, Control Center and CarPlay controls work, and music keeps playing when the app is in the background. On Mac, Apple Music plays in the app instead; see [Mac support](docs/MAC-SUPPORT.md).
- Playlists live in the app (Application Support), and work without Apple Music. Searching and playing need Apple Music access and an active subscription.

The agent can do all of this too, through device tools (below): `music_search`, `playlist_list/get/create/add_songs/remove_songs/reorder/rename/delete`, `music_play`, `music_now_playing` and `music_control`. Playlists can be referred to by name or id, and the Music screen shows the agent's changes immediately.

Before shipping, enable the **MusicKit** App Service for the bundle ID in the Apple Developer portal, then refresh the provisioning profile. Playback can't be tested in the simulator; use a device signed in to Apple Music. If playback fails although the subscription is valid, play a song once in the Music app, then retry.

## Listen

Listen plays audio and video files that aren't in Apple Music: podcast episodes, audio term-llm generated, songs, sound effects, and videos played for their sound. The player is native, so playback continues when the web page navigates or reloads, and when the phone is locked. The lock screen, Control Center, AirPods and CarPlay controls work (play/pause, back 15 s, forward 30 s, scrubbing, next/previous, speed).

While something is loaded, a mini player sits in the shared playback shelf. Tap it (or swipe it up) for the full player: scrubbing, speed (0.75×–3×) and a sleep timer (minutes or end of episode). Tap ✕ or swipe it down to hide it while playback carries on; it comes back when an item starts playing, or when the agent calls `media_control` with `show_player`. The **Podcasts** tab shows **Up Next** in play order (tap to play, Edit to reorder, swipe to mark played, remove or download) and **History** (played and archived items).

- Each item resumes where it was left. When one finishes it is marked played and the next in Up Next starts.
- The library and positions are saved on this phone (Application Support); the item that was playing comes back paused after the app restarts. While something plays, its position is saved every 15 seconds to a small file of its own, and at once when it pauses, stops, seeks or the app leaves the foreground; the library file itself is only rewritten when the library changes.
- Buffering notifications are coalesced before main-thread delivery (at most one pending refresh, 250 ms cadence); playhead/progress changes update small player subviews rather than the artwork, menus or library root. Controls, interruptions, errors and completed seeks keep their immediate paths.
- Starting Listen pauses Apple Music and starting Apple Music pauses Listen.

**Sources.**

- Media from the connected server (`/media/…`, including hub node paths) is fetched with the web view's sign-in cookie and downloaded by default, so it plays offline and seeks instantly. Any other http(s) URL is streamed without cookies.
- Videos and plain-http media stream straight from their URL (plain http through the `NSAllowsArbitraryLoadsForMedia` exception) without saving while they play; plain-http downloads are retried over https.
- Artwork is fetched once, saved on the phone at lock-screen size and read from that file afterwards, also across launches.

**Streaming and downloads.**

- An https episode that isn't downloaded yet plays through one shared byte-range transfer into a file on the phone.
- Playback-only caching prefetches up to 3 MiB ahead of the latest playback read instead of immediately filling the entire episode; seeking fetches the requested region without automatically filling the skipped gap. AVPlayer's own requested bytes are always served, so this is a bound on speculative prefetch, not a hard cap on download volume.
- Servers that ignore ranges, or omit the total length needed by the player, can fall back to a single whole-file response rather than repeatedly downloading prefixes.
- **Download for offline** promotes the existing transfer to a complete download, filling any gaps without replacing it. A download that is interrupted (or playing when the app quits) carries on from where it stopped next time; `If-Range` makes a file that changed on the server start over.
- The player shows whether it's connecting, buffering or how much is loaded ahead (a lighter track on the scrubber and the mini player's progress line), and how far the save has got. Stop keeps playback going but fetches only what it reads.
- The saved file is deleted when the episode is played or archived; explicit downloads (swipe right, or `download` now) are kept, and playing while one runs reads from it rather than fetching again. Downloads show their percentage in Up Next and are kept out of backups.

**Data use.** **Web page health** also shows **Podcast downloads**: delivered media bytes in the last 60 seconds, today, this calendar week/month, and since tracking began.

- Totals persist across launches and include retries/re-downloads, not cached file reads; URLSession HTTP cache hits may count. Tracking is not retroactive.
- Both health report formats include these counters, and high native-CPU events capture the recent byte count for correlation.
- It covers managed Listen downloads/HTTPS audio playback, not direct AVPlayer HTTP/video streams, artwork, Apple Music, or protocol overhead; it is not a carrier data meter.

**Agent tools.** The agent uses the same library through six device tools:

- `media_add`: one or more URLs with title, artist, album, description, artwork, kind, duration and published date; `position` now/next/end; `download` auto/now/never.
- `media_list`, `media_play` and `media_now_playing`.
- `media_control`: pause, resume, stop, seek, skip, next, previous, rate, sleep, sleep_at_end, cancel_sleep, hide_player, show_player.
- `media_manage`: remove, mark played/unplayed, archive, move, clear history, download, cancel or delete a download.

Items can be referred to by id or exact title. `term-llm-media://` references from `show_media` can't be resolved on the phone yet; the agent needs the published `/media/…` URL or another direct URL.

Starting music or a podcast (from the app or through a device tool) ends any live voice call in the app's web pages by pressing the page's own Stop control. When the agent started it with a tool, the initiating call's native reply is delivered first, then the page waits for a live tool-result upload (with a four-second fallback). Unrelated in-flight tools do not delay that handover, and deferred handovers are discarded when the document or device-tool bridge is replaced. Starting playback switches the app's audio session to playback.

For the playback CPU investigation, Apple efficiency guidance, reproduction checks and device-profiling limits, see [Listen playback performance](docs/LISTEN-PERFORMANCE.md).

Test lock-screen controls, interruptions (calls, Siri), headphone removal and background playback on a physical phone.

## Navigation

`location_current` gives the agent the phone's current position (latitude, longitude, accuracy, age, speed when known and an Apple Maps link) and, unless `include_address` is false, the street address or place there. A failed address lookup still returns the coordinates.

The agent can give walking or driving directions through four device tools:

- `navigation_preview` finds a place near the phone with Apple Maps and plans a route from the current location without starting anything.
- `navigation_start` begins tracking a preview; `navigation_stop` ends it.
- `navigation_status` reports the distance and time left, the next instruction, whether the user is off route or has arrived, and the upcoming maneuvers with their coordinates. It also returns a trail of where the user was, so the agent can explain a wrong turn: local time, coordinates, state and distance off route, about once a minute plus whenever they went off route, came back, were rerouted or arrived (only the last 30 minutes and at most 40 points).

While navigating, the phone matches GPS fixes to the route, reports off route only after several accurate fixes, reroutes automatically and stops using GPS on arrival.

- Tracking is foreground-only (when-in-use permission) and has no on-screen controls yet.
- It stops by itself once the app has been open for 20 minutes (30 when driving) without the user getting at least 50 m closer; `navigation_status` then says so.
- Nothing is pushed into a live voice call, so the agent learns progress only by calling `navigation_status`.

## Device tools (WebMCP)

The app can share tools that run on the phone (`ping`, `device_info` and the music, navigation and Listen tools) with your term-llm agent. In **Settings → Device tools**, turn on **Share device tools**; **What's shared** lists the tool groups. One switch covers every saved connection except Linked devices, and each conversation can still turn the tools off in its **MCP servers** list.

When sharing is on:

- The app injects a small script into each connection's own pages (main frame, matching origin only). The script registers the tools through [WebMCP](https://github.com/webmachinelearning/webmcp) (`document.modelContext`), providing a minimal implementation because WebKit has none.
- The term-llm web UI lists them in its **MCP servers** dialog as one more entry (for example "iPhone · 2 tools · WebMCP from this page"), switched on or off per conversation like configured servers.
- When the model calls one, the web page runs it through a native message handler and returns the result to the model. A native handler rejects calls from any other origin or frame.
- Nothing listens on the network and there are no tokens to manage: the tools exist only while you chat in the app.

This requires a term-llm web UI with WebMCP client-tool support.

## Passkeys for arbitrary servers

This app signs in through `ASWebAuthenticationSession` (the system browser), **not** WebAuthn inside `WKWebView`. See the [term-llm native app sign-in protocol](https://github.com/samsaffron/term-llm/blob/main/docs-site/content/guides/web-ui-and-api.md#native-app-sign-in).

1. When term-llm requests `/auth/login` or `/auth/setup`, the app opens the system passkey flow.
2. The operator must approve the handoff on the server's page; each handoff requires a fresh passkey assertion (the initial sign-in assertion counts if they just signed in).
3. **Only after approval** does term-llm redirect to the app with a 60-second, single-use code bound to a PKCE verifier held by the app.
4. The app redeems it over the configured connection (HTTPS except for simulator localhost testing) for a **separate** HttpOnly session cookie and installs that cookie in its WebKit store before loading the site.

No Associated Domains entitlement or AASA file is needed for this flow, even when the server URL is entered at runtime.

**Server requirements:** run a term-llm server with the native handoff routes (`/auth/native/…`, `/api/auth/native/authorize`, and `/api/auth/native/redeem`), using `serve web --auth passkey --public-url https://your-host/ui/` or Hub passkey auth. For an older server without these endpoints, upgrade the server or use Safari instead.

- Use the exact public URL, including its base path, in the app.
- Simulator-only localhost HTTP is supported for local testing (`--public-url http://localhost:8080/ui/`); passkey registration and login still depend on the server's WebAuthn configuration supporting the `localhost` origin.
- First-passkey setup still needs the one-time server setup code; the system browser shows the setup page and then returns to approval, which requires a new passkey assertion.
- An existing browser session can skip the initial login page, but still needs an approval click and a fresh passkey assertion.
- Use the connection’s **Sign in** or **Authentication** action in **Settings → Connections** to start a new native login manually.

The short-lived code appears only in the app-specific callback and cannot be reused. Authentication cookies remain separate: signing out of the embedded web view does not automatically sign out of the system-browser session. The server's regular passkey session management can revoke both. On a device, signing/provisioning must still succeed; the system browser's passkey provider needs an available passkey or a configured device passcode to create one.
