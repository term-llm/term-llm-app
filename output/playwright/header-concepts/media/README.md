# Media-aware persistent navigation — iteration 02

**Selected refinement:** `selected/index.html` develops concept 05 with **Agents** terminology and no app-level header inside Chat. See `selected/agents-vs-chat.png`.

These are interactive design prototypes only. They do not change the SwiftUI app, start real audio, or make server requests. Media titles and artwork are fictional.

Open locally:

```sh
open output/playwright/header-concepts/media/index.html
```

Or serve the parent directory:

```sh
python3 -m http.server 8789 --bind 127.0.0.1 --directory output/playwright/header-concepts
# http://127.0.0.1:8789/media/
```

## What changed

The first round treated the product as Hub ↔ Chat and omitted Music/Podcasts. This round treats navigation, retained chat, and audio playback as separate state concerns.

- Four destinations: Nodes, Chat, Music, Podcasts.
- Hub-only Attention and Sessions live under the Nodes view switcher, not alongside global destinations.
- Browsing either media library never changes current playback.
- A single proposed playback surface represents the currently active audio item. Starting a different source explicitly asks to pause the current one; positions are preserved in mock state.
- Music uses track controls. Podcasts use back 15, forward 30, speed, and Up Next.
- Chat drafts survive all destination and media transitions.
- A mini player is present only when there is an active item in bottom-player concepts; idle space returns to the node list. Inline-header concepts retain their reserved strip.
- Settings is app-wide. Connections and source-specific configuration remain separate.

The unified playback handoff is a proposed interaction model, not a claim that the current app has a unified audio coordinator.

## Six directions

1. **Four destinations + mini player:** all four global destinations in the header; player at the bottom.
2. **Work / Listen:** Work contains Nodes/Chat; Listen contains Music/Podcasts; player continues across both.
3. **Context + inline playback:** compact destination menu with a dedicated playback strip in the header.
4. **Library drawer + now playing:** one app drawer and a minimal current-location header; player at the bottom.
5. **Minimal header + bottom tabs:** four labelled bottom tabs, mini player immediately above them, quiet contextual header.
6. **Dual activity rail:** all four destinations plus separate current-chat and current-audio anchors in the header.

## Deliverables

- `six-media-headers.png`: six directions with a podcast playing over Nodes.
- `media-flow.png` / `media-flow.html`: concept 05 idle, Nodes + podcast, Music + podcast, and Podcasts + music.
- `six-media-headers-idle.png`: idle playback states.
- `browsing-music-podcast-playing.png`: all concepts browsing music while a podcast continues.
- `browsing-podcasts-music-playing.png`: all concepts browsing podcasts while music continues.
- `concept-01.png` through `concept-06.png`: individual concept cards.
- `verification.json`: interaction-check results for all six.

`?concept=5` opens a focused concept. `?media=idle` and `?media=music` select initial audio states. `?state=Music` and `?state=Podcasts` select initial destinations.

## Verification

The browser checks cover all four destinations, browsing without stopping audio, pause/resume outside the source library, confirmation/cancellation of playback handoff, source-specific controls, saved episode position, podcast queue/speed, independent draft retention, Settings scope, and stable header geometry during navigation, playback state changes, and sync.

With the server running:

```sh
npx --yes --package @playwright/cli playwright-cli open http://127.0.0.1:8789/media/
npx --yes --package @playwright/cli playwright-cli resize 1440 1900
npx --yes --package @playwright/cli playwright-cli run-code --filename output/playwright/header-concepts/media/check-interactions.js
```
