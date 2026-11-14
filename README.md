# term-llm for iPhone, iPad and Mac

A native client for [term-llm](https://github.com/term-llm/term-llm): chat with
agents, follow their work, and give them access to tools on your device.

- **Agents and chat:** browse agents and conversations, see what needs your
  attention, and chat with text or live voice.
- **Music and podcasts:** local playlists, Apple Music, an audio queue and
  offline downloads.
- **Device tools:** let agents manage media or use location and navigation on
  iPhone/iPad. Mac also offers optional Computer Use.
- **Multiple connections:** connect to remote Hubs or Direct Nodes, or manage
  a local term-llm service on Mac.

The app is a client, not a standalone model runtime. You need a term-llm server
for real conversations; the built-in demo works without one.

## Get started

1. On Mac, [download the signed app](https://term-llm.com/mac/download).
   To build for any platform, see below.
2. Choose **Try demo**, or add your server's HTTPS URL in
   **Settings → Connections** and sign in.
3. Choose an agent and open a conversation.

On Mac, **Local Service… → Set Up term-llm** can install and manage the official
CLI instead of connecting to a remote server. It is optional; see
[local service setup](docs/MACOS-COMPANION.md).

The demo's replies are scripted, not AI. Device tools can make real local
changes even in the demo, and require opt-in for each conversation.

## Build from source

Open `TermLLM.xcodeproj` in Xcode and choose a scheme:

| Scheme | Platform |
| --- | --- |
| `TermLLM` | iPhone and iPad (iOS 17+) |
| `TermLLMMac` | Native Mac app (macOS 14+) |

Both targets share `TermLLM/`; Mac-specific code lives in `TermLLMMac/`.
Choose a simulator to explore the iOS app, or configure signing for your team
to run on a device or use the Mac app's Keychain-backed connections.
See [Mac development notes](docs/MAC-SUPPORT.md) for build commands and signing limits.

## Documentation

- [Using the app](docs/APP-GUIDE.md)
- [Connections and sign-in](docs/CONNECTIONS.md)
- [All guides and developer documentation](docs/README.md)

## License

[MIT](LICENSE). Dependencies retain their own licenses; see
[third-party notices](THIRD-PARTY-NOTICES.md).
