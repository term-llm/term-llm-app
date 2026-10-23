# Contain → install app → access an agent

## Product target, not a claim of implemented onboarding

The desired demo is: create/start a contained agent, scan/open a link, install the iOS app if needed, approve access, and arrive at the native Hub. Native Hub control remains reachable when a node's web page is stalled.

This PR implements the native Hub client and simulator capture. It does **not** create a hosted redirect service, provision a public tunnel, register Universal Links, ship an App Store installation, or implement a new pairing protocol. The simulator's local protocol fixture is not evidence of those missing steps.

## What already exists

Core protocol inspected at `2496b5fddebdc9369642d062fa87b98cd649d415`:

- `tl contain new <name>` creates a workspace and can prompt to start it; `tl contain start <name>` starts an existing workspace.
- The CLI prints a local Web UI address and bearer token. A phone's `localhost` is not the workstation's `localhost`.
- `tl serve hub` discovers local contain workspaces by default. The phone can connect once that Hub has a reachable address, a valid HTTPS deployment and authentication.
- Passkey-enabled Hub already supports explicit app approval using a one-use PKCE-style browser handoff. Existing Hub and node credentials must not be confused with a link-service identifier.

## Three separate problems

1. **Reachability.** A public or VPN-reachable Hub, or an operator-approved tunnel/relay, must carry traffic from phone to Hub. An HTTP redirect cannot expose a private workstation. A service that proxies chat/API/WebSocket traffic is a data-plane relay, not a cheap link redirector; its reliability, bandwidth and security budget are different.
2. **Discovery.** A small link service can map a short opaque identifier to a Hub connection descriptor. Descriptors identify destinations; they do not grant administrator access. Validate HTTPS, credentials/userinfo, mount and origin in the app, show the destination before switching servers, and require consent. Do not let arbitrary links silently overwrite an existing connection.
3. **Authorization.** Approve with the Hub's own authentication. For newly created bearer-only agents, seamless one-use pairing requires a separately designed upstream protocol; do not put a permanent Hub/node token in a hosted redirect URL or trade possession of a public identifier for account access.

## Smallest honest hosted-link design

A possible follow-up is a dedicated domain with a short-lived `/connect/<opaque-id>` landing page and a Universal Link association for the app. Its job is to preserve the destination and offer **Open app** / install instructions, not to hold chats, inference or permanent credentials. It should avoid access-log leakage, third-party assets/analytics, referrers, unbounded registrations and unrestricted open redirects. Expiry, rate limits, authenticated registration, destination disclosure and revocation belong in the design before deployment.

Universal Links require app entitlement and association-file configuration. A link opened before installation is not an automatic deferred-login handoff after installation. Keep the browser landing page and ask for a second tap, or provide an expiring pairing code. Do not use fingerprinting or silently read the clipboard to manufacture continuity.

If the tunnel address changes, a link-service mapping may update discovery, but it does not by itself preserve the Hub's WebAuthn relying-party identity. Passkey continuity needs a stable configured HTTPS origin or an explicit migration story.

## Demo acceptance for the complete follow-up

- Fresh contain workspace, no preconfigured phone server URL.
- Show exactly how the phone reaches the workstation; no hidden pre-existing tunnel.
- Start without the app installed; installation and second-tap/code fallback are visible.
- Show destination confirmation and real authorization, including expired/replayed/revoked pairing attempts.
- Reach the native Hub and open the agent.
- Stall the node page and return using native Hub controls without waiting for JavaScript.
- Record the actual app and CLI, with fixture/staged portions clearly labelled. Never film credentials.

No new production service is deployed by this PR. Choose and approve the reachability/pairing design separately before turning the product target into an installation claim.
