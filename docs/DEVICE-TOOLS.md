# Device tools

Device tools let a term-llm agent act on the device running the app. They are
available through the connected chat page's WebMCP bridge, not a network listener
or a separate token-based service. The server's web UI must support WebMCP
client tools.

## Enable tools

1. Turn on **Settings → Device tools → Share device tools**.
2. In the conversation's **MCP servers** dialog, enable the device entry labelled
   **WebMCP from this page**.
3. Use **What's shared** in Settings to inspect the available tool groups.

Both the app switch and the per-conversation entry are required. With no saved
preference, sharing defaults **off on iPhone/iPad** and **on on Mac**. Existing
choices are preserved. The app-wide switch covers saved Hub and Direct Node
connections and Linked devices, and **Try demo** does not change it.

Tool calls are accepted only from the owning connection's main-frame origin.
Nothing exposes all saved connections' credentials to a conversation.

## Linked devices

A linked device's page gets the tools only when all of these hold:

1. **Share device tools** is on (the same app-wide switch as every connection).
2. The host, verified by the pairing's pinned key, advertises device tools. After
   each connection the app asks `GET /v1/capabilities` (relative to the host's
   advertised mount) over that source's own authenticated peer channel and
   requires `{"linked_devices":{"device_tools":true,…}}`. Only the literal JSON
   `true` counts; a missing, older-host (404), malformed, oversized or
   non-boolean answer means no tools. Other fields, including `active`, are not
   consulted. The request carries no cookie or credential. Transient failures
   (offline, timeout, 5xx) are retried a few times; they are not a new answer.
3. The conversation's **MCP servers** dialog has **WebMCP from this page** on.
   That entry is the page's own consent; the app cannot set it.

The app keeps the last definitive answer in memory for that source's pinned
host key and endpoint. A same-host reconnect checks again without clearing the
answer first, so it doesn't reload Chat if support hasn't changed. A definitive
no (including an older host's 404 or route denial) disables the tools immediately.
Revocation, a changed host identity or endpoint, and source removal also discard
the answer. Replies from retired connections are ignored. Without a previous
answer, a failed check never enables tools.

A linked page receives only its own source's registry, never the shared one,
and no credential for another connection. The bridge requires the page to be
inside the source's validated `http://localhost:<port>` mount and answers only
the exact main-frame origin. When sharing is enabled, a new linked Chat can wait
up to one second for its first pending capability check, so a quick answer can
install tools before the page loads. A later positive answer can still reload
Chat to register the tools. When tools are disabled, the app removes the native
handler without reloading; any tool entries left in the open page cannot make
calls and disappear on the next navigation.

Live calls on a linked host run in the page like any other chat. Whether the
host delegates a Live call's tools to this app is the host's and the page's
decision, not the app's; the app only provides the tools above.

The app sends no tool calls to a host that does not advertise support, and an
app-only update cannot enable it: both the host and this app must include it.
Media tools resolve a `/media/…` path on a linked source under its mount (for
example `/chat/media/a.mp3`); a path that already starts with the mount is kept,
and one that escapes it (`..`, encoded slashes) is rejected. Only URLs inside that
source's mount carry its source ID, so playback and downloads read only that
source's own credentials; direct http(s) URLs carry none. Hub and Direct Node
sources keep resolving server paths against their origin. Playback through the
loopback bridge still needs a real-device check.

## Available tools

| Group | Tools and behavior |
| --- | --- |
| Device | `ping`, `device_info` |
| Music and playlists | `music_search`, `music_play`, `music_now_playing`, `music_control`, and `playlist_*` tools; edits appear in the native Music library |
| Podcasts and audio | `media_add`, `media_list`, `media_play`, `media_now_playing`, `media_control`, `media_manage`; use direct media URLs, not `term-llm-media://` references |
| Location | `location_current`; iPhone/iPad only, with location permission |
| Directions | `navigation_preview`, `navigation_start`, `navigation_stop`, `navigation_status`; iPhone/iPad only |

Mac Music tools control term-llm's in-app player, not the system Music app.
Media playback and queue controls use the same libraries as the native screens;
starting playback ends a live voice call. See [the app guide](APP-GUIDE.md) for
playback permissions and download behavior.

## Location and directions

`location_current` returns coordinates and available accuracy/age/movement
information. Address lookup is optional; a lookup failure still returns the
coordinates.

Navigation can preview a walking/driving route, start tracking, report progress,
and stop. Tracking is foreground-only, reroutes after confirmed off-route fixes,
and stops after extended lack of progress. There are no native on-screen route
controls yet. Progress is returned when the agent calls `navigation_status`;
it is not pushed into a live voice call. Recent position history can be included
in that response, so enable these tools only for conversations that should have
that location access.

## Computer Use on Mac

Computer Use is a separate, optional bundled helper and `term-llm-computer` CLI,
off by default. It has its own permissions, per-app approvals and Stop/Pause
controls. See [Mac support](MAC-SUPPORT.md) for setup and the
[Computer Use architecture](design/COMPUTER-USE.md) for implementation details.
