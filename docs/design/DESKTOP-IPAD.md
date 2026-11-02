# Desktop & iPad — split-view concept

**Visual reference, not a live app.** The self-contained HTML and its fictional conversations remain a design artifact. Its native layout direction is now implemented for Mac/iPad in `ContentView`, `WorkspaceShell`, and `WorkspaceHeader`; see [Mac support](../MAC-SUPPORT.md). The iPhone shell is unchanged. The illustrative web Chat styling is not an injected replacement for a server's real frontend.

## Open and capture

The HTML is self-contained: system fonts, inline SVG, CSS and JavaScript; no dependencies, external assets, analytics or network requests. It also opens directly as a local file.

From the repository root:

```sh
python3 -m http.server 8789 --bind 127.0.0.1 --directory docs/design
```

| Preview | Browser viewport | Local path |
| --- | --- | --- |
| Mac / Agents | **1440 × 900** | `http://127.0.0.1:8789/desktop-ipad.html?device=mac&view=agents` |
| Mac / Chat | **1440 × 900** | `http://127.0.0.1:8789/desktop-ipad.html?device=mac&view=chat` |
| iPad landscape / Agents | **1194 × 834** | `http://127.0.0.1:8789/desktop-ipad.html?device=ipad&view=agents` |
| iPad landscape / Chat | **1194 × 834** | `http://127.0.0.1:8789/desktop-ipad.html?device=ipad&view=chat` |
| Narrow iPad / Agents | **768 × 1024** | `http://127.0.0.1:8789/desktop-ipad.html?device=ipad&view=agents` |
| Narrow iPad / Chat | **768 × 1024** | `http://127.0.0.1:8789/desktop-ipad.html?device=ipad&view=chat` |

The query selects device chrome and initial destination, **not viewport dimensions**. Resize the browser separately. `Concept / notes` contains device/destination links and the design rationale; it is closed by default so there is no presentation masthead competing with the app. Captures should show the concept at 100% browser zoom, not a scaled phone canvas.

### Browser verification

Rendered with Playwright/Chrome at 1440 × 900 (Mac), 1194 × 834 (iPad landscape), and 768 × 1024 (iPad portrait), with screenshots visually inspected. Measured a 52px content header, 17px chat prose, a 760px maximum Mac reading width, and no horizontal overflow in the checked Mac/portrait Chat views. Edited the local draft, switched Agents → Chat, and confirmed it remained intact; checked the narrow-iPad sidebar open/Escape-close behavior and the 390px unchanged-mobile notice. These checks validate only this HTML concept, not SwiftUI, WKWebView, Safari sizing parity, or a real iPad/Mac app.

## Visual direction

A quiet Apple-native light workspace: warm-neutral sidebar, white reading surface, restrained blue actions, fine separators and modest corner radii. No dashboard gradients, oversized metrics, hero branding or stretched floating phone tab bar.

- **Mac:** 220px sidebar, traffic lights in its top 52px region, content header aligned on the same horizontal line. Traffic lights are decorative, not working window controls.
- **iPad:** 200px sidebar and a separate 25px illustrative system status bar. No Mac traffic lights. The content header remains 52px.
- **Navigation:** Agents, Chat, Music, Podcasts; Settings anchored at the bottom. The selected item is a subdued filled row, not a bright panel. Chat remains the stable destination name, never an agent-specific global tab.
- **One content header:** a single quiet 52px row, with contextual title and small actions. In Agents this represents native chrome; in Chat it represents the agent-owned web header. There is no additional app header above Chat and no blank spacer where one used to be.
- **Readable type:** 17px chat prose and draft, 1.65 prose line height, 15px sidebar navigation, 14–16px primary list content. Secondary metadata is intentionally smaller, but messages are not. System font rendering rather than a canvas transform. This proposes an explicit readable base size; it does not assert measured parity with every Safari zoom/text setting.
- **Reading measure:** chat and composer share a maximum 760px width. Wide windows add breathing room rather than stretching every line across the screen. Agents has a 900px maximum list width so provenance and actions remain legible without becoming a dashboard.
- **Agents:** realistic grouped rows, connection provenance, availability and recent conversations. The online/all filter is local; all three fictional agents happen to be online. No pretend remote health checks. This first visual study shows the Agents panel only; Attention and Sessions must remain accessible in a production design and are not proposed for removal.
- **Chat:** a modest conversation title, full-sized prose, low-emphasis message tools, and a visible editable draft. No second conversation sidebar, model control panel or extra workspace header.

## Responsive behavior — not a phone redesign

| Width | Proposed behavior |
| --- | --- |
| 901px and wider | Persistent split sidebar; Mac 220px / iPad 200px. Mac sidebar can also be hidden manually and reopened from the content header. |
| 600–900px | Sidebar starts collapsed. A leading button opens it as a temporary overlay; backdrop, Escape or destination selection dismisses it. Content uses the available width rather than shrinking to a 568px column beside a permanent sidebar. |
| Below 600px | **Existing mobile remains unchanged.** Only an explanatory concept notice is shown; there is deliberately no invented phone UI. |

At 768px this is explicitly a narrow-iPad proposal, not an assertion about the existing app's size-class implementation. The overlay does not unload Chat. Landscape and portrait retain the same reading type scale. Very short windows can scroll the transcript/list independently; virtual-keyboard and native safe-area behavior are outside a static browser concept.

## Local interactions

- Agents and Chat switch in the same document. The chat DOM, draft textarea and transcript remain mounted while hidden. Edit the draft, scroll Chat, visit Agents, then return to check the intended retained context.
- Navigation to Music and Podcasts shows clearly labelled scope placeholders, not invented media functionality. No playback starts or stops.
- Settings and Connections explain their separate ownership. Neither edits configuration.
- Sidebar collapse and narrow-iPad overlay are functional; search filters the fictional agent rows; the online/all segmented control changes local selection.
- Finch and the first recent conversation open the illustrated Chat. The other agents/history rows explain that only one conversation is mocked. No new session is created.
- Sending explains that nothing is sent and preserves the draft. Attachments request no files or permissions. The copy button attempts to copy only the fictional response, with a graceful fallback when clipboard access is unavailable.
- No reload persistence: the draft is held in this page only, not local storage. Reloading, following a device query link or closing the page restores the sample. No authentication, model, streaming or live connection is represented.

## Ownership and implementation limits

The repository README and selected header concept establish that **Chat already owns its web header** and that returning to Chat means the exact retained browser document, including draft and scroll. This proposal respects that boundary; the single HTML header changing ownership is a presentation device, **not an implementation recipe to hoist the remote header into SwiftUI**.

Native can propose a split-view container and destination navigation. It cannot safely duplicate or rewrite the upstream web header, typography or composer. The illustrated 52px Chat header, 17px body and 760px reading measure require coordination with the upstream term-llm web UI. Do not inject CSS/DOM patches to force this appearance or place a native toolbar on top of its existing toolbar. Until upstream supports the proposed appearance, retain the real agent-owned web header rather than claiming visual parity.

Any later implementation must preserve the retained WebView across destination switches, responsive native navigation independent of remote requests, per-connection data/credential isolation, and closure of protected documents on revocation. “Retained” here means a valid in-memory workspace, not automatically reviving a protected page after restart, source replacement or sign-out.

Settings remains app-wide; connection management is a distinct action. Media destinations and shared playback behavior are not redesigned. No claims are made about Catalyst titlebar APIs, Stage Manager, VoiceOver focus behavior, software keyboard layout, live server rendering, actual iPad status bars or native desktop support. The HTML is a visual/interaction discussion artifact, not production accessibility or device validation.

## Native implementation verification

The native implementation has separate passing checks: 81 focused simulator tests (three host/accessibility-dependent skips), two original iPhone UI journeys, and two iPad UI journeys covering landscape sidebar/panels/settings/agent Back and portrait Chat draft retention across all destinations. Retention tests mount an actual local WKWebView, cross the sidebar breakpoint, check native identity/draft/scroll, verify window detachment, and verify that hidden authorization revocation dismantles the protected document. Mac-destination signed compilation also passed. iPad UI captures use the labelled loopback HTTP protocol fixture, not real agents or production authentication. Native Mac harness reads still timed out; direct Mac interaction, Safari pixel parity, live notifications and device audio remain unverified.

## References consulted

- `README.md`: native destinations, connection provenance, retained Chat context, settings scope, web-owned Chat header.
- `output/walkthrough/04-agents.png`: existing mobile grouped Agents, system surfaces and four destinations.
- `output/walkthrough/07-chat.png`: existing agent-owned web header, readable conversation and composer, persistent native destination access.
- `output/playwright/header-concepts/media/selected/README.md`: no duplicate app header, stable Chat label, independent draft/playback state.

The existing phone captures are reference material, not targets to replace. No files under `output/` are modified by this deliverable.
