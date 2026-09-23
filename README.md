# Pi iOS

A mobile companion for the [Pi coding agent](https://pi.dev) — a native SwiftUI port of [pi-desktop](../pi-desktop)'s chat experience for iPhone and iPad.

Chat directly against your own LLM providers with streaming, manage sessions, track real activity, and switch themes. No backend required — the app talks to model APIs over HTTPS.

## Features

- **Streaming chat** — token-by-token SSE rendering with Markdown, code blocks, thinking blocks, and a blinking cursor
- **Bring your own provider** — built-in Anthropic / OpenAI presets plus custom OpenAI-compatible endpoints (base URL + API key + model list), mirroring pi's provider config model
- **OAuth sign-in** — same flows as the pi agent:
  - **Claude (Anthropic)** — authorization code + PKCE with manual redirect-URL paste
  - **ChatGPT (OpenAI Codex)** — device code flow (login only; chat adapter not yet implemented)
  - Credentials stored in the iOS Keychain, tokens auto-refresh before expiry
- **Sessions** — grouped by project, rename / archive / delete, per-session token usage
- **Session persistence** — conversations are saved locally (JSON in Application Support) and survive app restarts; active session is restored
- **Timeline** — a real activity log of your prompts, responses, tool calls and approvals (persisted locally)
- **Home dashboard** — sessions / tokens / cost stats, activity heatmap, per-model usage — all computed from your actual usage
- **Themes** — Dark / Light / Nord / Gruvbox / Breeze Light, using pi-desktop's seed-color token system
- **Command palette** — ⌘K quick switcher (iPad / hardware keyboard)
- **Mock mode** — a scripted offline demo agent for showcasing the UI without any account

## Requirements

- Xcode 16+ (developed on Xcode 27)
- iOS 17.0+
- No third-party dependencies

## Build & run

```bash
open PiApp.xcodeproj
# or
xcodebuild -project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build
```

For a physical device: select your team in **Signing & Capabilities**, or pass
`DEVELOPMENT_TEAM=<your-team-id> -allowProvisioningUpdates` to `xcodebuild`.

## Configure a provider

1. Open **Settings → AI Providers → Manage Providers**
2. Pick a built-in provider (or **Add Provider** for a custom endpoint)
3. Paste an **API key**, or **Sign in with Claude (OAuth)** / **Sign in with ChatGPT (device code)**
4. Select the model in **Settings → AI Providers**, then chat

If you chat before configuring a provider, the assistant will point you to Settings.

## Architecture

```
PiApp/
├── Core/
│   ├── Agent/        # AgentClient protocol + Mock / WebSocket / LLM implementations
│   ├── AI/           # ProviderStore, OAuthManager, LLMChatClient (SSE), Keychain
│   ├── Models/       # ChatSession, ChatMessage, ToolCall, TimelineEntry, ActivityStats
│   ├── Store/        # AppModel (@Observable) — navigation, sessions, events, stats
│   ├── Theme/        # PiTheme — seed colors → derived tokens (pi-desktop compatible)
│   └── Mock/         # MockData — demo content, loaded only in Mock mode
└── Views/            # Root (split view), Home, Chat, Sessions, Timeline, Settings, CommandPalette
```

The `AgentClient` protocol abstracts the chat backend:

| Backend | Purpose |
|---|---|
| `LLMChatClient` | Direct HTTPS SSE chat with your provider (default) |
| `MockAgentClient` | Scripted offline demo with tool calls & permission flow |
| `WebSocketAgentClient` | Experimental JSONL-over-WebSocket client for a remote `pi --mode rpc` host |

### Debug launch arguments

Useful for UI tests and screenshots:

```bash
xcrun simctl launch booted dev.pi.ios.swing -uiRoute timeline
xcrun simctl launch booted dev.pi.ios.swing -uiSend "hello"
xcrun simctl launch booted dev.pi.ios.swing -uiSeedProvider http://127.0.0.1:8899/v1 my-model
```

## License

Apache-2.0. OAuth client identifiers and provider logic are derived from the
[pi](https://github.com/earendil-works/pi) agent (Apache-2.0).
