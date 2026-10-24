# Persistent header concepts

**Current iteration:** see `media/index.html` and `media/README.md` for the revised six concepts that include Music, Podcasts, persistent playback, and source-specific controls. The root gallery is the earlier Hub/Chat-only study.

Standalone interaction prototypes, not changes to the SwiftUI application.

Run `python3 -m http.server 8789 --directory output/playwright/header-concepts` and open `http://localhost:8789/`.

- Gallery: `/`
- Individual concept: `/?concept=1` through `/?concept=6`
- Chat state: `/?concept=1&state=chat`

Every phone has independent state. Try the view controls, open a node or resume chat, enter a draft and return, open Connections or Settings, and use the gallery's Sync controls. The data and conversations are illustrative only.

1. **Command rail** — native two-row toolbar with explicit content tabs and a direct chat action.
2. **Workspace segments** — an always-visible Hub / Chat switch above the content tabs.
3. **Context switcher** — one compact row; tap the title to change Hub views.
4. **Breadcrumb bar** — a stable home anchor and explicit Hub / view context; recent chat is a compact text action.
5. **Floating dock** — a fixed floating navigation capsule with icon-led destinations and an overflow sheet.
6. **Session rail** — a contrasting terminal-inspired header with a permanent current-conversation ribbon.

All concepts keep the header mounted, reserve their sync/status space, default to online nodes, and separate app Settings from connection management. Each has one primary Settings entry (direct gear or one overflow entry).

## Visual deliverables

- `six-headers.png`: all six concepts in the same node-list context.
- `header-behaviors.png` / `states.html`: each persistent header in Nodes and Chat states.
- `six-headers-chat.png` and `six-headers-syncing.png`: full-screen state comparisons.
- `01-*.png` through `06-*.png`: individual concept cards.
- `verification.json`: browser interaction checks for all six concepts.

The HTML also works by opening `index.html` directly in a normal browser; it has no external dependencies. These are browser-rendered interaction studies, not pixel-exact native iOS builds.

To repeat verification with the local server running:

```sh
npx --yes --package @playwright/cli playwright-cli open http://127.0.0.1:8789/
npx --yes --package @playwright/cli playwright-cli resize 1440 1850
npx --yes --package @playwright/cli playwright-cli run-code --filename output/playwright/header-concepts/check-interactions.js
```
