# Selected concept 05 — Agents + agent-owned chat header

This is a focused refinement of the mock, not a production app change.

```sh
open output/playwright/header-concepts/media/selected/index.html
```

## Decisions reflected here

- User-facing navigation says **Agents**, not Nodes.
- The Agents browser is the default destination.
- Agents, Music, and Podcasts have the contextual app header.
- Chat has **no app-level header at all**, and no blank spacer where it was. The agent's own web header is the only header on that screen.
- Bottom navigation stays available: Agents / Chat / Music / Podcasts.
- An active mini player remains above the bottom tabs, including in Chat. No item means no mini player.
- Chat draft and playback remain independent of destination changes.

The mocked agent-owned header is illustrative, not an assertion about the exact appearance of a live term-llm web frontend.

## Deliverables

- `agents-vs-chat.png` / `comparison.html`: side-by-side browsing and chat states.
- `agents-podcast.png` / `chat-podcast.png`: active playback states.
- `agents-idle.png` / `chat-idle.png`: no active audio item.
- `interactive-refinement.png`: the focused prototype and design notes.
- `verification.json`: browser checks for header ownership, terminology, pinned bottom tabs, draft retention, and playback independence.

With the parent prototype directory served at port 8789, open `/media/selected/`. The local HTML also works directly without a server.
