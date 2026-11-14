# Connections and sign-in

## Add a server

Open **Settings → Connections** and enter a Hub or Direct Node's HTTPS URL,
including any path prefix such as `/ui/`. The app detects the server type; failed
discovery offers a retry rather than guessing. Add an optional name to make
multiple connections easier to distinguish.

A Hub provides access to its nodes; a Direct Node connects to one server.
Connection failures are isolated, so a slow or signed-out source does not sign
out the others. Hub administration is available only for Hub connections.
[Linked devices](LINKED-DEVICES.md) provide a separate pairing/transport option.

On Mac, the optional [local service](MACOS-COMPANION.md) appears as **This Mac**
after verification, already authenticated. Remote connections need no local CLI.

## HTTPS and local testing

Entered server addresses require HTTPS on physical iPhone/iPad devices and Mac.
Use a certificate the device trusts. A phone's `localhost` is not your Mac.
The managed **This Mac** connection and app-owned Linked devices bridge are
validated loopback exceptions, not permission to enter arbitrary HTTP URLs.

For **iOS simulator testing only**, the app accepts
`http://localhost:8080/ui/` when the server is running on the Mac. Other HTTP
hosts remain disallowed. Microphone and WebRTC features may also require a
secure context. External links open outside the app.

## Authentication

Use the connection's **Sign in** or **Authentication** action. For passkeys,
the app opens the system browser rather than requesting WebAuthn inside its
embedded chat view. Approve the handoff on the server's page; each handoff needs
a fresh passkey assertion. Initial server setup can also require its one-time
setup code.

The server returns a short-lived, single-use code bound to the app's PKCE
verifier. The app redeems it for its own session and installs that session into
the connection's isolated browser storage. This works with arbitrary server
domains without Associated Domains or an AASA file.

Servers need the native handoff endpoints described in the
[core sign-in protocol](https://github.com/term-llm/term-llm/blob/main/docs-site/content/guides/web-ui-and-api.md#native-app-sign-in).
If those endpoints are absent, upgrade the server or use Safari. Localhost
passkey tests also depend on the server accepting the `localhost` origin.

Token-authenticated connections use secure native fields, not tokens embedded
in URLs. Adding/removing passkeys that require recent authentication must be
completed in the Hub's browser **Security** panel. Browser reauthentication does
not automatically make the separate native session recently authenticated.
Signing out of the embedded view likewise does not sign out of the system
browser; server-side session revocation can revoke both.

## Credential isolation

- Each connection has its own WebKit website data and scoped credentials.
  Direct-node bearer credentials are held in Keychain.
- Saved connection metadata contains names, kinds and URLs, not credentials.
  Credentials do not belong in connection URLs, defaults or logs.
- Changing an endpoint or connection kind creates a new trust identity. Renaming
  a connection does not. Migrating an older saved URL may require signing in
  again; browser credentials are not copied automatically.
- Native requests use isolated sessions and scoped authentication, not ambient
  browser cookies. The app follows a Hub's validated proxy routes, never its
  nodes' private display addresses.
- Authorization failure clears that connection's protected state and closes its
  retained chat. A timeout alone is not treated as proof that access was revoked.

## Connection links

A `termllm://connect?server=<percent-encoded-HTTPS-Hub-root>` link opens a native
review form. It never silently connects or signs in. Embedded credentials,
query tokens, duplicate fields and localhost pairing addresses are rejected.

Custom links require the app to be installed. They are not deferred-install
links, a tunnel, or a way to make an unreachable server public. For the separate
Universal Link and hosted-onboarding prerequisites, see
[contain-to-app onboarding](CONTAIN-APP-ONBOARDING.md).

For protocol fixtures and source-isolation regression coverage, see
[phone Hub verification](PHONE-HUB.md) and
[native Hub capture](NATIVE-HUB-CAPTURE.md).
