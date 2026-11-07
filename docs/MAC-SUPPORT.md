# Mac support and tailnet connections

> For the separate native macOS companion target (`TermLLMMac`), including its
> development-only delivery status, CLI provisioning and local service controls,
> see [Native macOS companion](MACOS-COMPANION.md). This document describes the
> existing iOS app running on Apple Silicon Macs.

## Apple Silicon Mac

The app runs as **Designed for iPad/iPhone**, not as a native macOS or Mac Catalyst target. Development builds must provision both the app and notification extension for the Mac. This does not establish App Store availability or distribution-build behavior.

Mac-only controls:

- **Navigate:** Command–1 through Command–4 select Agents, Chat, Music, and Podcasts.
- **Settings:** Command–comma.
- **Refresh:** Command–R refreshes Agents, or reloads the visible Chat. It does not reload a retained chat while another tab is selected. Music and Podcasts have no root refresh command.
- **Chat back:** Command–[ when the visible Chat has a back item.
- **Chat text size:** Command–plus/minus, Command–0 to reset to 125%; also available in Settings → Chat appearance. The local preference ranges from 75–200% and does not navigate/reload the page. Mac uses a viewport-aware UIKit content mode plus WebKit text-only adjustment; its actual `pageZoom` stays at 100%. Responsive CSS still selects a desktop layout when there is room. iPhone/iPad content mode, zoom and text adjustment remain untouched. The 125% starting point is adjustable, not a claim of measured Safari pixel parity.
- **Listen:** secondary-click queue/history rows for the same actions as their swipe controls.

Commands are scoped to the active app window and disabled behind sheets/alerts. Plain text and system editing keys are not overridden. The phone/iPad shell does not use the additional Mac command-host controller.

Multiple windows remain disabled. `NOTIFICATION-OWNERSHIP.md` gates them on proving scene-specific notification routing and the current voice/listen singleton ownership. Enabling another scene without that work is not a safe UI-only fix.

## Adaptive workspace

The approved [desktop/iPad concepts](design/DESKTOP-IPAD.md) now inform the native larger-screen shell:

- Device selection, not window width, chooses the shell: iPhone keeps its original TabView; iPad and Designed-for-iPad-on-Mac use the workspace at all widths.
- The sidebar is 200pt on iPad / 220pt on Mac and persistent at 900pt and wider. Narrow windows use a dismissible overlay. A narrow Chat uses a 44pt leading navigation rail, not a floating button over the web header or composer.
- Agents, Music and Podcasts have quiet 52pt minimum native root headers. Pushed agent/playlist screens retain native Back navigation. Agents, Attention and Sessions remain available. Wide Agents lists use a readable bounded measure.
- Chat gets **no second native header**. Its frontend still owns the real header, typography, content width and composer. The concept's fictional chat and exact 760px/17px web design are not injected into remote pages.
- Resizing and destination selection use one stable content hierarchy. Retained Chat leaves the native window when inactive without being discarded; native destinations stay mounted and hidden. Authorization revocation still tears down a hidden protected document.
- The shared playback shelf stays outside the scrolling destinations. Selecting a destination does not start or stop playback.

Mac-only viewport-aware content mode and text-only scaling address undersized web rendering without changing the phone/tablet path. UIKit's page zoom can narrow the visual viewport while leaving fixed `width: 100%` app/header/composer geometry at its original width; it can also counteract text sizing. Mac therefore keeps page zoom at 100% and uses the standard `-webkit-text-size-adjust` / `text-size-adjust` presentation properties on the main document. The small script runs in WebKit's isolated client world, preserves other connection scripts, and never replaces the document or app structure. Existing size preferences still apply as text scale. The HTML concepts remain design references, not screenshots of the app.

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
