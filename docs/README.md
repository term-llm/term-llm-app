# Documentation

## Using term-llm

- [App guide](APP-GUIDE.md) — agents, chat, voice, notifications, media and the demo.
- [Connections and sign-in](CONNECTIONS.md) — HTTPS, authentication and credential isolation.
- [Device tools](DEVICE-TOOLS.md) — sharing tools with a conversation, including media and location.
- [Mac support](MAC-SUPPORT.md) — Mac controls, Computer Use setup and platform differences.
- [Local service on Mac](MACOS-COMPANION.md) — installing/managing the CLI and updating the app.
- [Linked devices](LINKED-DEVICES.md) — pairing and host-backed connections.

## Development and operations

Both app targets live in `TermLLM.xcodeproj`. Use scheme `TermLLM` for iOS or
`TermLLMMac` for Mac. An unsigned simulator compile check is:

```sh
xcodebuild build -project TermLLM.xcodeproj -scheme TermLLM \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Real-device builds need signing/capabilities for the app and notification
extension, including their shared app and Keychain groups. Music playback needs
the MusicKit App Service. See the [notification contract](../NOTIFICATION-OWNERSHIP.md)
and [Mac build/signing notes](MAC-SUPPORT.md) before shipping.

- [GitHub Actions](SELF-HOSTED-CI.md) — self-hosted checks, test plans, signing and releases.
  Xcode Cloud app workflows are separate; their metadata lives in
  `TermLLM.xcodeproj/xcshareddata/xcodecloud/`.
- [Push relay](../push-relay/README.md) — encrypted notification delivery and deployment.
- [Phone Hub verification](PHONE-HUB.md) and [native Hub capture](NATIVE-HUB-CAPTURE.md) — local protocol fixtures and simulator journeys, not live-server proof.
- [Listen performance](LISTEN-PERFORMANCE.md) — media profiling and verification limits.
- [Computer Use](design/COMPUTER-USE.md) and [desktop/iPad concepts](design/DESKTOP-IPAD.md) — architecture and design references, not app screenshots.
- [Contain-to-app onboarding](CONTAIN-APP-ONBOARDING.md) — reachability and link-service prerequisites, including work not implemented by this app.

[MIT license](../LICENSE) · [Third-party notices](../THIRD-PARTY-NOTICES.md)
