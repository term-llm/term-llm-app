# term-llm for iOS

A minimal SwiftUI shell for a self-hosted [term-llm](../term-llm) web server. Open `TermLLM.xcodeproj` in Xcode, choose an iPhone simulator or signing team/device, then run. On first launch, tap **Try demo** to connect to `https://demo.term-llm.com/` without a server or sign-in, or enter your own server URL (including any path prefix, e.g. `https://example.com/term-llm/`). The URL is saved on device; browser cookies and site storage persist in WKWebView. Change servers from Settings.

## Guided demo

The public demo uses scripted replies, not AI. Its chats reset on reload. Native device actions are real and their saved data is **not** cleared by reloading the demo.

To try the native playlist integration:

1. Pull down from the top of the visible page, then tap **Settings**. On first use, **Try it** in the coachmark also reveals these floating controls.
2. Under **Device tools**, enable **Share device tools with this server** and tap **Done**. Sharing is per server and is never enabled automatically by **Try demo**.
3. In the chat, tap **+ → MCP servers**, enable the **iPhone/iPad** entry labelled **WebMCP from this page**, and close the dialog.
4. Send **create playlist**. The scripted demo calls `playlist_create_demo` through the ordinary WebMCP flow. It creates a real local playlist with five fictional sample songs, without Apple Music authorization or playback. Repeating the command reuses the sample playlist without overwriting edits.
5. Pull down for app controls and tap **♪ Music** to inspect, rename, reorder, or delete the playlist. Sample songs are explicitly non-playable; use Apple Music search to add real songs.

The demo also supports **list playlists**, **ping**, and **device info** when their tools are enabled. It does not automatically request location, microphone, or Music permissions, and it does not simulate voice or Apple Music playback. An older app without `playlist_create_demo` needs updating for the sample-playlist walkthrough.

For the opt-in simulator integration check, build/serve the sibling repository's demo and run:

```sh
# In ../term-llm: node demo/build.mjs && python3 -m http.server 8765 --directory demo/dist
TEST_RUNNER_TERMLLM_DEMO_E2E_URL=http://localhost:8765/ xcodebuild test \
  -project TermLLM.xcodeproj -scheme TermLLM \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TermLLMTests/WebMCPLiveServerTests/testDemoCreatesNativeSamplePlaylistOnlyAfterMCPOptIn
```

This exercises the real frontend MCP switch and native playlist store with Apple Music denied, using an isolated test library rather than modifying the user's playlists.

HTTPS is required on devices, including for self-hosted servers. For local testing in the **iOS simulator only**, enter `http://localhost:8080/ui/` while term-llm is running on your Mac; the simulator shares the Mac's localhost. HTTP is restricted to `localhost` in simulator builds, not remote hosts or physical devices. Configure a trusted certificate or an HTTPS reverse proxy for device testing; microphone/WebRTC and other browser features may require a secure context. External links open outside the app. The camera and microphone permissions are requested by WebKit when the site needs them.

## Notifications and roadmap

Native notifications use one switch. Turn on **Settings → Notifications** (or tap Enable in a site's own notification settings, which does the same). iOS asks for permission once. Each server or hub agent enrolls through its authenticated page. Per-site off and the app-wide switch persist local opt-out shared with native delivery handling. Server cleanup handles survive failure and retry when the corresponding authenticated pages reconnect; unopened/offline nodes can remain pending. The app switch is not iOS permission revocation and cannot guarantee cancellation of an already in-flight remote alert. Settings shows pending cleanup and shared-storage problems.

Alerts identify the sending agent: generic messages show its name (for example **Dev** above **hello**), and completion alerts use **Dev: Response complete** without repeating an existing prefix. A v2 completion tap targets its owning native scene, or requests a fresh scene if that owner is gone; it never selects the first arbitrary sibling. A plain `term-llm notify app` message opens that agent's page. Hub-local chat paths are rebased onto the agent's public hub mount. Each enrollment uses a distinct Web Push authentication secret, so agents sharing a VAPID key cannot overwrite one another's destination. Already-delivered notifications retain their original route and v2 event/read metadata. Grouping includes source scope and chat. Foreground completion suppression uses the owning scene's fresh policy-derived attendance lease—not merely matching the visible URL. Exact successful server attention ACKs clear only that source/store/session through the acknowledged sequence; opening a page alone does not clear newer/unseen work. Pushes from another configured origin do not navigate.

The app and extension now require the **Application Group `group.com.termllm.app.shared`** in both signing profiles. Optional v2 completion capability fails closed if shared state or a live scene/document binding is unavailable; legacy bridge enrollment/manual compatibility remains separate. Replay handling is bounded and persistent, but an NSE cannot cancel every alert remote push: quiet/empty cards or expiry placeholders are still possible. See [native notification contract and verification limits](NOTIFICATION-OWNERSHIP.md) before rollout.

How it works: WKWebView has no service workers or Web Push, so the app injects `window.__termLLMNativePush` for the configured server. term-llm's web UI uses it instead of a service worker and registers the returned subscription with its own node through the normal `/v1/push/subscribe` API. The subscription's endpoint is the [push relay](push-relay/README.md), which forwards the still-encrypted message through APNs. A Notification Service Extension decrypts it on the phone with keys kept in the keychain (shared with the extension). The relay URL comes from the `TERMLLM_PUSH_RELAY_URL` build setting; for local development launch with `-push.relayURL http://localhost:8080`. Builds run from Xcode use the APNs sandbox; TestFlight and App Store builds use production. APNs key scope is determined by Apple, not the relay: do not assume one key covers both environments. The relay must be configured with a key that covers the environment being used, and development registration is rejected while `RELAY_APNS_ENVIRONMENTS` omits it. The relay's registration API is unauthenticated and its process-wide budgets limit abuse; they are not device attestation (App Attest is not implemented). See the [push relay documentation](push-relay/README.md) for the sandbox-capable key requirement and the full trust model.

This needs a term-llm server whose web UI supports the native bridge and sends Web Push with a 2048-byte record size. Sites that a device has never opened in the app do not receive scheduled `term-llm notify` messages until they have been opened once.

For live voice, the app declares iOS background audio so an active WebKit microphone/WebRTC call can continue after locking the phone on supported iOS versions. Start the call before locking; this does not start voice in the background or guarantee recovery from network changes, system interruptions, or an app force-quit. Verify capture and playback on a physical phone (the simulator is not a reliable lock-screen audio test).

The web UI (including the hub and its live voice controls) is shown as-is, with no permanent native bar or button. Pull down from within the top of the visible web page to reveal floating Back, Reload, Music, Listen, and Settings controls, even when the page is scrolled. A compact first-use coachmark explains the gesture: **Try it** reveals the controls and **Got it** dismisses the hint. Learning/dismissing it is remembered across launches. The controls stay open until used or explicitly closed; each target is at least 44 points. A successful pull gives a light haptic. The overlay does not resize/reload the web page; when hidden it intercepts no page touches. VoiceOver's **App controls** action and browser back-swipe remain available. If the server returns an HTTP error or fails to load, a native recovery screen keeps Retry and Settings visible. An authentication-required response offers passkey sign-in instead. Native hub navigation and a native voice transport are future work.

## Voice shortcut and Action button

Open the app's **Settings → Voice Shortcut**. Discovery uses the existing server sign-in. For a hub, choose the **Agent** to call; for a direct server, no extra selection is needed. The destination is remembered per server. **Test Live Conversation** runs the same launch flow as the shortcut.

On an iPhone with an Action button, open **iOS Settings → Action Button → Shortcut** and choose **term-llm → Start Live Conversation**. The action is also available in Shortcuts and Siri. The app cannot assign the physical button itself.

This first version opens the app in the foreground, navigates to a fresh conversation (`?new=1`), waits for the web composer, and activates **Start live voice** once. It leaves an existing active call alone, including when a different agent is selected for the shortcut. Live must be enabled on the destination server. If sign-in is required, complete the passkey flow; if discovery initially failed, sign in and refresh the agents in Settings. Failed or unavailable Live startup shows a native explanation rather than repeatedly clicking or toggling voice.

The integration uses the web UI's accessible Live controls, not a native voice transport or background call. Automatic microphone/audio activation, first-time permission prompts, and Action-button launch from a locked phone still require physical-iPhone verification; iOS may require unlocking or tapping Live on the page. Simulator tests cover routing, discovery/authentication boundaries, and one-shot button activation, not a real microphone call.

## Browser lifecycle

Returning from the background keeps the existing web view and does not force a page reload, preserving the live workspace while WebKit remains alive. If iOS terminates the web content process, the app reopens the current same-server route with a fresh GET when active (or falls back to the configured server URL). Recovery waits while the app is inactive or signing in, and does not override sign-in or server/network error screens. A second termination within 30 seconds stops automatic recovery and offers the existing Retry/Settings controls; Retry, a server change, or successful native sign-in resets the retry budget.

This does not persist conversation snapshots or restore JavaScript memory after process loss. Unsent text and live-session reconnection after a reload depend on the server's web UI. Physical-device memory-pressure and background voice testing are still necessary.

## Music

Pull down for app controls and tap ♪ to open **Music**. It shows what's playing and the playlists saved on this phone. You can create, rename, reorder and delete playlists, and add songs by searching Apple Music. Tap Play or Shuffle, or tap any song to start from there. Playback goes through the system Music player, so the lock screen, Control Center and CarPlay controls work, and music keeps playing when the app is in the background. Playlists live in the app (Application Support), and work without Apple Music. Searching and playing need Apple Music access and an active subscription.

The agent can do all of this too, through device tools (below): `music_search`, `playlist_list/get/create/add_songs/remove_songs/reorder/rename/delete`, `music_play`, `music_now_playing` and `music_control`. Playlists can be referred to by name or id, and the Music screen shows the agent's changes immediately.

Before shipping, enable the **MusicKit** App Service for the bundle ID in the Apple Developer portal, then refresh the provisioning profile. Playback can't be tested in the simulator; use a device signed in to Apple Music. If playback fails although the subscription is valid, play a song once in the Music app, then retry.

## Listen

Listen plays audio and video files that aren't in Apple Music: podcast episodes, audio term-llm generated, songs, sound effects, and videos played for their sound. The player is native, so playback continues when the web page navigates or reloads, and when the phone is locked. The lock screen, Control Center, AirPods and CarPlay controls work (play/pause, back 15 s, forward 30 s, scrubbing, next/previous, speed).

While something is loaded, a mini player sits under the web page. Tap it (or swipe it up) for the full player: scrubbing, speed (0.75×–3×) and a sleep timer (minutes or end of episode). Tap ✕ to stop and close it (the item keeps its place and position in Up Next). Swipe it down to hide it while playback carries on; it comes back when something new starts or when you open Listen (🎧 in App controls). Listen shows **Up Next** in play order (tap to play, Edit to reorder, swipe to mark played, remove or download) and **History** (played and archived items).

Each item resumes where it was left. When one finishes it is marked played and the next in Up Next starts. The library and positions are saved on this phone (Application Support); the item that was playing comes back paused after the app restarts. Starting Listen pauses Apple Music and starting Apple Music pauses Listen.

Media from the connected server (`/media/…`, including hub node paths) is fetched with the web view's sign-in cookie and downloaded by default, so it plays offline and seeks instantly. Any other http(s) URL is streamed without cookies. While an episode streams it is also saved on the phone at low priority (not videos): the player shows whether it's connecting, buffering or how much is loaded ahead (a lighter track on the scrubber and the mini player's progress line), and how far the save has got (with Stop). Once saved, the next seek, resume, or a dropped connection switches to the file without starting over, and the file is deleted when the episode is played or archived. Explicit downloads (swipe right, or `download` now) are kept. Downloads show their percentage in Up Next and are kept out of backups. Plain-http media streams through the `NSAllowsArbitraryLoadsForMedia` exception; plain-http downloads are retried over https.

The agent uses the same library through six device tools: `media_add` (one or more URLs with title, artist, album, description, artwork, kind, duration and published date; `position` now/next/end; `download` auto/now/never), `media_list`, `media_play`, `media_control` (pause, resume, stop, seek, skip, next, previous, rate, sleep, sleep_at_end, cancel_sleep, hide_player, show_player), `media_now_playing` and `media_manage` (remove, mark played/unplayed, archive, move, clear history, download, cancel or delete a download). Items can be referred to by id or exact title. `term-llm-media://` references from `show_media` can't be resolved on the phone yet; the agent needs the published `/media/…` URL or another direct URL. Starting playback switches the app's audio session to playback; how that affects a live voice call in the web page hasn't been tested.

Test lock-screen controls, interruptions (calls, Siri), headphone removal and background playback on a physical phone.

## Navigation

`location_current` gives the agent the phone's current position (latitude, longitude, accuracy, age, speed when known and an Apple Maps link) and, unless `include_address` is false, the street address or place there. A failed address lookup still returns the coordinates.

The agent can give walking or driving directions through four device tools. `navigation_preview` finds a place near the phone with Apple Maps and plans a route from the current location without starting anything. `navigation_start` begins tracking a preview, `navigation_status` reports the distance and time left, the next instruction, whether the user is off route or has arrived, the upcoming maneuvers with their coordinates, and a trail of where the user was (local time, coordinates, state and distance off route, about once a minute plus whenever they went off route, came back, were rerouted or arrived; only the last 30 minutes and at most 40 points) so the agent can explain a wrong turn, and `navigation_stop` ends it. While navigating, the phone matches GPS fixes to the route, reports off route only after several accurate fixes, reroutes automatically and stops using GPS on arrival. Tracking is foreground-only (when-in-use permission) and has no on-screen controls yet; nothing is pushed into a live voice call, so the agent learns progress only by calling `navigation_status`.

## Device tools (WebMCP)

The app can share tools that run on the phone (`ping`, `device_info` and the music, navigation and Listen tools) with your term-llm agent. In Settings → **Device tools**, turn on **Share device tools with this server**. The choice is remembered per server URL, so you can share with a personal hub but not a development box.

When sharing is on, the app injects a small script into that server's own pages (main frame, matching origin only). The script registers the tools through [WebMCP](https://github.com/webmachinelearning/webmcp) (`document.modelContext`), providing a minimal implementation because WebKit has none. The term-llm web UI lists them in its **MCP servers** dialog as one more entry (for example "iPhone · 2 tools · WebMCP from this page"), switched on or off per conversation like configured servers. When the model calls one, the web page runs it through a native message handler and returns the result to the model. Nothing listens on the network and there are no tokens to manage: the tools exist only while you chat in the app. A native handler rejects calls from any other origin or frame.

This requires a term-llm web UI with WebMCP client-tool support.

## Passkeys for arbitrary servers

This app signs in through `ASWebAuthenticationSession` (the system browser), **not** WebAuthn inside `WKWebView`. When term-llm requests `/auth/login` or `/auth/setup`, the app opens the system passkey flow. The operator must approve the handoff on the server's page; each handoff requires a fresh passkey assertion (the initial sign-in assertion counts if they just signed in). **Only after approval** does term-llm redirect to the app with a 60-second, single-use code bound to a PKCE verifier held by the app. The app redeems it over the configured connection (HTTPS except for simulator localhost testing) for a **separate** HttpOnly session cookie and installs that cookie in its WebKit store before loading the site. No Associated Domains entitlement or AASA file is needed for this flow, even when the server URL is entered at runtime. See the [term-llm native app sign-in protocol](https://github.com/samsaffron/term-llm/blob/main/docs-site/content/guides/web-ui-and-api.md#native-app-sign-in).

**Both sides must be updated:** run a term-llm server with the native handoff routes (`/auth/native/…`, `/api/auth/native/authorize`, and `/api/auth/native/redeem`), using `serve web --auth passkey --public-url https://your-host/ui/` or Hub passkey auth. Use the exact public URL, including its base path, in the app. Simulator-only localhost HTTP is supported for local testing (`--public-url http://localhost:8080/ui/`); passkey registration and login still depend on the server's WebAuthn configuration supporting the `localhost` origin. First-passkey setup still needs the one-time server setup code; the system browser shows the setup page and then returns to approval, which requires a new passkey assertion. An existing browser session can skip the initial login page, but still needs an approval click and a fresh passkey assertion. For an older server without these endpoints, upgrade the server or use Safari instead. The Settings screen also offers **Sign in with passkey** to start a new native login manually.

The short-lived code appears only in the app-specific callback and cannot be reused. Authentication cookies remain separate: signing out of the embedded web view does not automatically sign out of the system-browser session. The server's regular passkey session management can revoke both. On a device, signing/provisioning must still succeed; the system browser's passkey provider needs an available passkey or a configured device passcode to create one.
