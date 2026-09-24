# pi-mobile-bridge

A pi/omp extension that serves your agent to the **Pi Mobile iOS app** over
the local network — no relay, no cloud, nothing leaves your LAN.

```
iPhone App ──LAN WebSocket──> pi-mobile-bridge (inside pi/omp) ──> AgentSession
```

Unlike a subprocess bridge, the extension runs **inside** your pi/omp process:
it shares the agent's session, credentials, tools and model configuration.

## Install

```bash
# from npm (recommended)
pi install npm:pi-mobile-bridge

# from a local checkout (loads in place; run npm install && npm run build first)
pi install ./extension

# one-shot without touching settings
pi --extension ./extension/dist/index.js
```

On omp, drop `dist/index.js` into `~/.omp/agent/extensions/` (omp shares pi's
extension API) or point `omp --extension` at it.

## Use

The bridge starts automatically with the session. Control it from pi:

```
/mobilebridge status          # listening URL + connected clients
/mobilebridge start|stop
/mobilebridge port 8888
```

In the app: **Settings → Agent → Backend → Remote (WebSocket)** → enter the
printed LAN URL (e.g. `ws://192.168.1.5:7777`) → **Reconnect**. Both devices
must be on the same network.

## What works over the bridge

- Streaming chat (text + thinking deltas) against the live agent session
- Tool call rendering: name, argument summary, live output, success/failure
- **Mobile approval gate**: non-read-only tool calls are forwarded to the app
  (`tool_call` hook → Approve/Deny, 60 s timeout → auto-deny). `read`, `grep`,
  `glob`, `ls`, `find` are auto-approved. With no app connected, the local UI
  handles approvals as usual.
- Abort (Stop button), real token usage + cost per response

## Develop

```bash
npm install
npm run build        # esbuild: src/index.ts -> dist/index.js (ws external)
```

## Notes

- Events are forwarded from `message_update` deltas only (same discipline as
  remote-pi) — the full conversation state stays in pi.
- Session replacement (`/new`, resume, fork) tears down and recreates the
  extension runtime; reconnect the app afterwards.
- Wire protocol is documented in
  [`PiApp/Core/Agent/WebSocketAgentClient.swift`](../PiApp/Core/Agent/WebSocketAgentClient.swift).
