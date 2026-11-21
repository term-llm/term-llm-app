# Using the app

## Agents and chat

The app opens on **Agents**. Choose an agent to browse its conversations, or
start a new one. The overview shows activity and items needing attention across
your saved connections. Offline agents are hidden unless **Show offline agents**
is enabled in **Settings → Connections**.

Conversations support search, pins, renaming, archiving with Undo, and seen
acknowledgements. Linked-device conversation lists are read-only for metadata
changes. Opening a conversation alone does not mark its results seen.

On iPhone, **Agents · Chat · Music · Podcasts** are persistent bottom tabs.
iPad uses a sidebar, and Mac uses a window-toolbar selector. On iPhone/iPad,
Settings is on Agents; on Mac, use **term-llm → Settings…** or **Command–comma**.

Chat uses the server's web UI. Switching destinations keeps the same page,
draft and scroll position. On iPhone/iPad, pull down from the top of the page
for **Back** and **Reload**; Mac provides menu and keyboard commands. Signing
out closes the protected page. An app restart does not restore a live browser
workspace, and unsent-text recovery after WebKit process loss depends on the
server's web UI.

## Voice and shortcuts

Live voice needs support on the destination server and WebKit microphone
permission. Start a call while the app is in the foreground. On supported iOS
versions an active call can continue with the phone locked; network changes,
system interruptions and force-quitting can still end it.

In **Settings → Voice shortcut**, choose an agent and use **Start live
conversation**. The same action is available in Shortcuts and Siri. On an iPhone
with an Action button, assign **term-llm → Start Live Conversation** in
**iOS Settings → Action Button → Shortcut**. Linked devices cannot be shortcut
targets. The shortcut opens the app and starts voice in a fresh conversation;
it leaves an existing active call alone. First-use permissions or a locked
phone may still require unlocking or tapping Live.

## Notifications

Enable **Settings → Notifications** and allow the system permission. Each
server or Hub agent enrolls through its authenticated page; a site must have
been opened in the app before it can receive scheduled notifications.

The app icon badge reflects the last synchronized Attention total, not a count
inferred from incoming pushes. It updates when Attention synchronizes, without
extra background polling.

Turning notifications off saves the opt-out locally and retries server cleanup
when authenticated pages reconnect. Settings reports pending cleanup and shared
storage problems. This does not revoke system notification permission or
promise cancellation of an already in-flight alert.

For deployment requirements and delivery/routing rules, see the
[notification contract](../NOTIFICATION-OWNERSHIP.md) and
[push relay guide](../push-relay/README.md). Push delivery and locked-phone voice
need physical-device testing; simulator fixtures do not establish either.

## Music

Create, rename and edit local playlists in **Music**. Local playlists work
without Apple Music; searching and playing Apple Music songs require permission
and an active subscription. **Connect Apple Music** requests access; after a
denial, use **Open Settings**. Browsing does not start playback or request
permission automatically.

On iPhone/iPad, Apple Music uses the system Music player. Mac plays inside
term-llm, not the system Music app. term-llm attaches to the player only once
Music is used (the Music screen, music tools or playback), so music started
elsewhere appears in the media shelf after that. If iPhone/iPad playback fails despite a valid
subscription, play a song in Music once and retry. Testing playback requires a
real device; developers also need the MusicKit App Service enabled for their
bundle ID and refreshed provisioning profiles.

## Podcasts and other audio

**Podcasts** holds an **Up Next** queue and playback history for podcast episodes
and other audio/video URLs. Items resume from their saved positions. The shared
mini player on iPhone keeps Play/Pause and **×** beside the episode title. Tap
the title or artwork for the full title, skips, seeking, speed and sleep timer.
Tap **×** to hide the bar without stopping playback. Starting Music pauses the
audio queue and vice versa.
Starting either player also ends a live voice call.

Use **Download for offline** to save an episode. Interrupted downloads can
resume after relaunch. Playback-only caching stays bounded ahead of playback;
servers without usable byte-range support may require a whole-file response.
Explicit downloads remain saved, while temporary playback caches are removed
when their items are played or archived.

Protected server media uses the credentials of the connection it came from;
public URLs do not receive those credentials. Video and plain-HTTP media stream
without being saved during playback. Agents need a direct media URL, not a
`term-llm-media://` reference. See [device tools](DEVICE-TOOLS.md) for agent control
and [Listen performance](LISTEN-PERFORMANCE.md) for implementation diagnostics.

## Guided demo

**Try demo** uses scripted replies and resets its chats on reload. It does not
simulate voice or Apple Music playback. Native device-tool actions are real,
and their saved changes are not cleared by resetting the demo.

To try tools without Apple Music access:

1. Enable **Settings → Device tools → Share device tools**.
2. In Chat, choose **+ → MCP servers** and enable the device entry labelled
   **WebMCP from this page**.
3. Send **create playlist**. The demo creates a local playlist of fictional,
   non-playable sample songs. Repeating it reuses the playlist without replacing
   your edits.
4. Open **Music** to inspect, edit or delete it.

The demo also supports **list playlists**, **ping**, and **device info** when
their tools are enabled. It does not automatically request location, microphone
or Music permissions.

## Troubleshooting

For connection or authentication errors, use **Settings → Connections** and the
[connection guide](CONNECTIONS.md). If the web content process exits, the app
can reopen its route, but cannot preserve JavaScript memory or guarantee an
active call survives. Repeated failures offer **Retry** rather than endlessly
reloading.

**Settings → Web page health** shows thermal state, CPU activity and recent
history. **Copy for diagnosis** provides a compact report; **Share full report**
exports retained samples and events. Reports contain measurements and code
names, not chat text, form values, credentials or request addresses. Podcast
download counters cover managed media traffic, not all device data use.

**Stop runaway pages** is on by default. It can close a stalled or excessively
active page, but not during calls, voice startup, device-tool replies, sign-in
or page media playback. A stopped page can be reopened or reloaded. For hot
native playback paths, see [Listen performance](LISTEN-PERFORMANCE.md); function
stacks and interruption/background behavior need physical-device profiling.
