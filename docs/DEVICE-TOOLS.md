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
choices are preserved. The app-wide switch covers saved Hub/Direct Node
connections, not Linked devices, and **Try demo** does not change it.

Tool calls are accepted only from the owning connection's main-frame origin.
Nothing exposes all saved connections' credentials to a conversation.

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
