# term-llm for iOS

A minimal SwiftUI shell for a self-hosted [term-llm](../term-llm) web server. Open `TermLLM.xcodeproj` in Xcode, choose an iPhone simulator or signing team/device, then run. Enter your server URL (including any path prefix, e.g. `https://example.com/term-llm/`). The URL is saved on device; browser cookies and site storage persist in WKWebView. Change servers from Settings.

HTTPS is required, including for self-hosted servers. Configure a trusted certificate or an HTTPS reverse proxy; microphone/WebRTC and other browser features also require a secure context. External links open outside the app. The camera and microphone permissions are requested by WebKit when the site needs them.

## Notifications and roadmap

Settings can request iOS notification permission. This **does not yet deliver completion alerts**: term-llm's existing Web Push subscriptions depend on service workers, which WKWebView does not expose as native APNs subscriptions. A later milestone needs device-token registration, authentication and routing on the server, APNs credentials, and an iOS push entitlement. Until then, use the website installed to the Home Screen if background completion alerts are needed. Likewise, keeping a voice session alive while locked requires a separate native audio/session design; the web view alone cannot guarantee it.

The web UI (including the hub) is shown as-is. Native hub navigation and native voice are future work.

## Passkeys for arbitrary servers

This app signs in through `ASWebAuthenticationSession` (the system browser), **not** WebAuthn inside `WKWebView`. When term-llm requests `/auth/login` or `/auth/setup`, the app opens the system passkey flow. The operator must approve the handoff on the server's page; each handoff requires a fresh passkey assertion (the initial sign-in assertion counts if they just signed in). **Only after approval** does term-llm redirect to the app with a 60-second, single-use code bound to a PKCE verifier held by the app. The app redeems it over HTTPS for a **separate** HttpOnly session cookie and installs that cookie in its WebKit store before loading the site. No Associated Domains entitlement or AASA file is needed for this flow, even when the server URL is entered at runtime. See the [term-llm native app sign-in protocol](https://github.com/samsaffron/term-llm/blob/main/docs-site/content/guides/web-ui-and-api.md#native-app-sign-in).

**Both sides must be updated:** run a term-llm server with the native handoff routes (`/auth/native/…`, `/api/auth/native/authorize`, and `/api/auth/native/redeem`), using `serve web --auth passkey --public-url https://your-host/ui/` or Hub passkey auth. Use the exact HTTPS public URL, including its base path, in the app. Plain HTTP is not enabled in this wrapper. First-passkey setup still needs the one-time server setup code; the system browser shows the setup page and then returns to approval, which requires a new passkey assertion. An existing browser session can skip the initial login page, but still needs an approval click and a fresh passkey assertion. For an older server without these endpoints, upgrade the server or use Safari instead. The Settings screen also offers **Sign in with passkey** to start a new native login manually.

The short-lived code appears only in the app-specific callback and cannot be reused. Authentication cookies remain separate: signing out of the embedded web view does not automatically sign out of the system-browser session. The server's regular passkey session management can revoke both. On a device, signing/provisioning must still succeed; the system browser's passkey provider needs an available passkey or a configured device passcode to create one.
