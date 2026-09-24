#!/usr/bin/env node
/**
 * pi-bridge — LAN bridge between the Pi iOS app and a local `pi`/`omp` agent.
 *
 *   iPhone App ──WebSocket──> pi-bridge ──stdin/stdout JSONL──> pi --mode rpc
 *
 * Zero dependencies (Node ≥ 20). Usage:
 *   node bridge/pi-bridge.mjs                 # uses `pi`
 *   node bridge/pi-bridge.mjs --binary omp    # uses `omp`
 *   node bridge/pi-bridge.mjs --port 8888
 * Any extra args after `--` are passed to the agent, e.g.:
 *   node bridge/pi-bridge.mjs -- --provider anthropic --model claude-sonnet-4-5
 *
 * The app speaks a small JSON protocol (see WebSocketAgentClient.swift):
 *   → {"type":"prompt","text":"...","permission":"default","history":[...]}
 *   → {"type":"permission_answer","allow":true}
 *   → {"type":"abort"}
 * The bridge translates to/from `pi --mode rpc` JSONL frames.
 */
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { createHash, randomUUID } from 'node:crypto'
import os from 'node:os'

// ---------- args ----------
let port = 7777
let binary = 'pi'
let agentArgs = []
const argv = process.argv.slice(2)
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--binary') binary = argv[++i]
  else if (argv[i] === '--port') port = Number(argv[++i])
  else if (argv[i] === '--') { agentArgs = argv.slice(i + 1); break }
}

// ---------- minimal RFC 6455 WebSocket server ----------
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

function wsEncodeText(str) {
  const payload = Buffer.from(str, 'utf8')
  const len = payload.length
  let header
  if (len < 126) {
    header = Buffer.from([0x81, len])
  } else if (len < 65536) {
    header = Buffer.alloc(4)
    header[0] = 0x81; header[1] = 126
    header.writeUInt16BE(len, 2)
  } else {
    header = Buffer.alloc(10)
    header[0] = 0x81; header[1] = 127
    header.writeBigUInt64BE(BigInt(len), 2)
  }
  return Buffer.concat([header, payload])
}

function wsEncodePong(payload) {
  const p = payload ?? Buffer.alloc(0)
  return Buffer.concat([Buffer.from([0x8a, p.length]), p])
}

/** Incremental frame parser. Client→server frames are always masked. */
function makeFrameParser(onText, onPing, onClose) {
  let buf = Buffer.alloc(0)
  return (chunk) => {
    buf = Buffer.concat([buf, chunk])
    for (;;) {
      if (buf.length < 2) return
      const opcode = buf[0] & 0x0f
      const masked = (buf[1] & 0x80) !== 0
      let len = buf[1] & 0x7f
      let off = 2
      if (len === 126) {
        if (buf.length < 4) return
        len = buf.readUInt16BE(2); off = 4
      } else if (len === 127) {
        if (buf.length < 10) return
        len = Number(buf.readBigUInt64BE(2)); off = 10
      }
      const maskLen = masked ? 4 : 0
      if (buf.length < off + maskLen + len) return
      let payload = buf.subarray(off + maskLen, off + maskLen + len)
      if (masked) {
        const mask = buf.subarray(off, off + 4)
        payload = Buffer.from(payload)
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4]
      }
      buf = buf.subarray(off + maskLen + len)
      if (opcode === 0x8) { onClose(); return }
      if (opcode === 0x9) { onPing(payload); continue }
      if (opcode === 0x1) onText(payload.toString('utf8'))
      // binary / continuation frames are not used by the app; ignored
    }
  }
}

// ---------- pi RPC translation ----------

function summarize(name, args) {
  if (!args || typeof args !== 'object') return ''
  const candidate = args.path ?? args.file_path ?? args.command ?? args.pattern ?? args.query
  if (candidate != null) return String(candidate).slice(0, 80)
  try { return JSON.stringify(args).slice(0, 80) } catch { return '' }
}

function contentText(result) {
  if (!result) return ''
  if (typeof result === 'string') return result
  const content = result.content
  if (Array.isArray(content)) {
    return content.map((b) => (b && typeof b.text === 'string' ? b.text : ''))
      .filter(Boolean).join('\n')
  }
  return ''
}

function handleConnection(socket) {
  const send = (obj) => {
    try { socket.write(wsEncodeText(JSON.stringify(obj))) } catch { /* socket dying */ }
  }

  let proc = null
  let lineBuf = ''
  let currentToolId = null
  let pendingUiId = null
  let lastUsage = null
  let finishedSent = false

  const writeRpc = (obj) => {
    if (proc && proc.stdin.writable) proc.stdin.write(JSON.stringify(obj) + '\n')
  }

  const startAgent = () => {
    if (proc) return
    try {
      proc = spawn(binary, ['--mode', 'rpc', '--no-session', ...agentArgs],
        { stdio: ['pipe', 'pipe', 'inherit'] })
    } catch (err) {
      send({ type: 'error', message: `failed to spawn ${binary}: ${err.message}` })
      return
    }
    proc.on('error', (err) => {
      send({ type: 'error', message: `cannot run "${binary}": ${err.message}` })
      proc = null
    })
    proc.on('exit', (code) => {
      proc = null
      send({ type: 'error', message: `agent process exited (code ${code ?? '?'})` })
    })
    proc.stdout.on('data', (d) => {
      lineBuf += d.toString('utf8')
      let idx
      while ((idx = lineBuf.indexOf('\n')) >= 0) {
        const line = lineBuf.slice(0, idx).replace(/\r$/, '')
        lineBuf = lineBuf.slice(idx + 1)
        if (line.trim().length > 0) handleAgentLine(line)
      }
    })
    // Readiness probe (pi emits nothing until asked).
    writeRpc({ id: '__bridge_probe__', type: 'get_state' })
  }

  function handleAgentLine(line) {
    let msg
    try { msg = JSON.parse(line) } catch { return }
    switch (msg.type) {
      case 'ready':            // OMP hello frame; plain v1 JSONL is fine, ignore
      case 'response':         // command ack envelope; the app doesn't need it
      case 'turn_start':
      case 'turn_end':
      case 'message_start':
      case 'agent_start':
      case 'agent_settled':
      case 'queue_update':
        return

      case 'message_update': {
        const ev = msg.assistantMessageEvent
        if (msg.usage) lastUsage = msg.usage
        if (!ev) return
        if (ev.type === 'text_delta') {
          send({ type: 'text_delta', text: ev.delta ?? '' })
        } else if (ev.type === 'thinking_delta') {
          send({ type: 'thinking_delta', text: ev.delta ?? '' })
        } else if (ev.type === 'toolcall_start') {
          currentToolId = ev.id
          send({ type: 'tool_started', id: ev.id, name: ev.toolName ?? 'tool', summary: '', input: '' })
        }
        return
      }

      case 'tool_execution_start': {
        currentToolId = msg.toolCallId
        send({
          type: 'tool_started',
          id: msg.toolCallId,
          name: msg.toolName ?? 'tool',
          summary: summarize(msg.toolName, msg.args),
          input: safeJSON(msg.args),
        })
        return
      }

      case 'tool_execution_update': {
        const text = contentText(msg.partialResult)
        if (text) send({ type: 'tool_output', id: msg.toolCallId, chunk: text })
        return
      }

      case 'tool_execution_end': {
        const text = contentText(msg.result)
        if (text) send({ type: 'tool_output', id: msg.toolCallId, chunk: text })
        send({
          type: 'tool_finished',
          id: msg.toolCallId,
          status: msg.isError ? 'failed' : 'success',
          diff: msg.result?.details?.diff ?? null,
        })
        currentToolId = null
        return
      }

      case 'extension_ui_request': {
        // Approval dialogs are blocking — map confirm to the app's permission flow.
        if (msg.method === 'confirm') {
          pendingUiId = msg.id
          send({
            type: 'permission_requested',
            id: currentToolId ?? msg.id,
            title: msg.title ?? '',
            message: msg.message ?? '',
          })
        } else if (msg.method === 'select' || msg.method === 'input' || msg.method === 'editor') {
          // Other blocking dialogs would deadlock the turn; cancel them.
          writeRpc({ type: 'extension_ui_response', id: msg.id, cancelled: true })
        }
        return
      }

      case 'message_end': {
        if (msg.message?.role === 'assistant' && msg.message.usage) {
          lastUsage = msg.message.usage
        }
        return
      }

      case 'agent_end': {
        if (finishedSent) return
        finishedSent = true
        send({
          type: 'message_finished',
          input: lastUsage?.input ?? 0,
          output: lastUsage?.output ?? 0,
          cost: lastUsage?.cost?.total ?? 0,
        })
        return
      }

      case 'extension_error':
        send({ type: 'error', message: `${msg.event ?? 'extension'}: ${msg.error ?? 'error'}` })
        return

      case 'error':
        send({ type: 'error', message: msg.error ?? msg.message ?? 'agent error' })
        return

      default:
        return
    }
  }

  const cleanup = () => {
    try { proc?.stdin.end() } catch { /* ignore */ }
    try { proc?.kill() } catch { /* ignore */ }
    proc = null
    try { socket.destroy() } catch { /* ignore */ }
  }

  const onText = (text) => {
    let msg
    try { msg = JSON.parse(text) } catch { return }
    switch (msg.type) {
      case 'prompt':
        startAgent()
        finishedSent = false
        lastUsage = null
        writeRpc({ id: randomUUID(), type: 'prompt', message: String(msg.text ?? '') })
        break
      case 'permission_answer':
        if (pendingUiId) {
          writeRpc({ type: 'extension_ui_response', id: pendingUiId, confirmed: !!msg.allow })
          pendingUiId = null
        }
        break
      case 'abort':
        writeRpc({ id: randomUUID(), type: 'abort' })
        break
      default:
        break
    }
  }

  const parser = makeFrameParser(onText, (ping) => {
    try { socket.write(wsEncodePong(ping)) } catch { /* ignore */ }
  }, cleanup)

  socket.on('data', parser)
  socket.on('close', cleanup)
  socket.on('error', cleanup)

  send({ type: 'bridge_ready', binary })
}

function safeJSON(value) {
  try { return JSON.stringify(value ?? {}) } catch { return '{}' }
}

// ---------- HTTP + upgrade ----------

const server = createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain' })
  res.end('pi-bridge: connect with a WebSocket client\n')
})

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key']
  if (!key) { socket.destroy(); return }
  const accept = createHash('sha1').update(key + WS_GUID).digest('base64')
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`)
  handleConnection(socket)
})

server.listen(port, '0.0.0.0', () => {
  const ips = Object.values(os.networkInterfaces())
    .flat()
    .filter((n) => n && n.family === 'IPv4' && !n.internal)
    .map((n) => n.address)
  console.log(`pi-bridge (agent: ${binary}, port: ${port})`)
  console.log(`  local:   ws://127.0.0.1:${port}`)
  for (const ip of ips) console.log(`  LAN:     ws://${ip}:${port}`)
  console.log('Set this URL in the app: Settings → Agent → Backend → Remote (WebSocket)')
})
