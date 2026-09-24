# pi-bridge — LAN backend for the Pi iOS app

Runs a real `pi` (or `omp`) coding agent on your computer and lets the iOS app
drive it directly over the local network — no relay, no cloud, no NAT traversal.

```
iPhone App ──WebSocket (LAN)──> pi-bridge ──stdin/stdout JSONL──> pi --mode rpc
```

## Usage

```bash
node bridge/pi-bridge.mjs                 # uses `pi`
node bridge/pi-bridge.mjs --binary omp    # uses `omp` (oh-my-pi fork)
node bridge/pi-bridge.mjs --port 8888
node bridge/pi-bridge.mjs -- --provider anthropic --model claude-sonnet-4-5
```

Requires Node.js ≥ 20 and a working `pi`/`omp` CLI with credentials configured
(`pi auth login` or your `models.json` providers). The bridge prints its LAN
addresses on startup:

```
pi-bridge (agent: omp, port: 7777)
  local:   ws://127.0.0.1:7777
  LAN:     ws://192.168.1.5:7777
```

In the app: **Settings → Agent → Backend → Remote (WebSocket)**, enter the LAN
URL, tap **Reconnect**. Both devices must be on the same network. The app
allows cleartext WebSocket on local networks (`NSAllowsLocalNetworking`); no
TLS is needed inside a trusted LAN.

## What works over the bridge

- Streaming chat (text + thinking deltas) with full conversation state kept by
  the agent process
- Tool call rendering: name, arguments summary, live output, success/failure
- Permission approvals: the agent's confirm dialogs appear in the app as
  Approve/Deny; other blocking dialogs (select/input/editor) are auto-cancelled
  to avoid deadlocks
- Abort (Stop button)
- Real token usage + cost reported per response

## Notes

- Each app session spawns its own agent process (`--no-session`), killed when
  the WebSocket disconnects.
- Conversation history lives in the agent process for the life of the
  connection; the `history` field sent by the app is currently ignored.
- OMP protocol v2 chunking (frames > 1 MiB) is not implemented — the bridge
  stays on plain JSONL v1, which OMP speaks by default.
- The bridge is single-agent-per-connection; run multiple bridges on different
  ports for parallel sessions.
