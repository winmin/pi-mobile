/**
 * pi-mobile-bridge — a pi/omp extension that serves this agent to the Pi iOS
 * app over the local network. No relay, no cloud: the extension opens a
 * WebSocket server inside the pi process and translates the app's wire
 * protocol to the extension API.
 *
 *   iPhone App ──LAN WebSocket──> pi-mobile-bridge (inside pi) ──> AgentSession
 *
 * Commands: /mobilebridge start | stop | status | port <n>
 */
import { createServer, type Server } from "node:http"
import os from "node:os"
import { WebSocketServer, WebSocket } from "ws"
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent"

const DEFAULT_PORT = 7777
const APPROVAL_TIMEOUT_MS = 60_000

// Read-only tools don't need mobile approval.
const AUTO_APPROVE = new Set(["read", "grep", "glob", "ls", "find"])

// ---------- helpers ----------

function summarize(args: unknown): string {
  if (!args || typeof args !== "object") return ""
  const a = args as Record<string, unknown>
  const candidate = a.path ?? a.file_path ?? a.command ?? a.pattern ?? a.query
  if (candidate != null) return String(candidate).slice(0, 80)
  try { return JSON.stringify(args).slice(0, 80) } catch { return "" }
}

function contentText(result: unknown): string {
  if (!result) return ""
  if (typeof result === "string") return result
  const content = (result as { content?: unknown }).content
  if (Array.isArray(content)) {
    return content
      .map((b) => (b && typeof (b as { text?: unknown }).text === "string" ? (b as { text: string }).text : ""))
      .filter(Boolean)
      .join("\n")
  }
  return ""
}

function lanAddresses(port: number): string[] {
  return Object.values(os.networkInterfaces())
    .flat()
    .filter((n) => n && n.family === "IPv4" && !n.internal)
    .map((n) => `ws://${n!.address}:${port}`)
}

interface PendingApproval {
  resolve: (allow: boolean) => void
  timer: NodeJS.Timeout
}

// ---------- extension ----------

export default function (pi: ExtensionAPI) {
  let server: Server | null = null
  let wss: WebSocketServer | null = null
  let port = DEFAULT_PORT
  const clients = new Set<WebSocket>()
  const pendingApprovals = new Map<string, PendingApproval>()
  let currentCtx: ExtensionContext | null = null
  let lastUsage: { input?: number; output?: number; cost?: { total?: number } } | null = null

  const broadcast = (obj: unknown) => {
    const frame = JSON.stringify(obj)
    for (const client of clients) {
      if (client.readyState === WebSocket.OPEN) client.send(frame)
    }
  }

  // ---------- WebSocket connections ----------

  function handleClient(socket: WebSocket) {
    clients.add(socket)
    socket.send(JSON.stringify({ type: "bridge_ready", binary: "extension", port }))

    socket.on("message", (data) => {
      let msg: { type?: string; text?: string; allow?: boolean }
      try { msg = JSON.parse(String(data)) } catch { return }
      switch (msg.type) {
        case "prompt": {
          const prompt = String(msg.text ?? "")
          if (!prompt.trim()) return
          lastUsage = null
          try {
            if (currentCtx?.isIdle() === false) {
              pi.sendUserMessage(prompt, { deliverAs: "followUp" })
            } else {
              pi.sendUserMessage(prompt)
            }
          } catch (err) {
            socket.send(JSON.stringify({ type: "error", message: String(err) }))
          }
          break
        }
        case "permission_answer": {
          const first = pendingApprovals.entries().next().value as [string, PendingApproval] | undefined
          if (first) {
            const [id, pending] = first
            clearTimeout(pending.timer)
            pendingApprovals.delete(id)
            pending.resolve(!!msg.allow)
          }
          break
        }
        case "abort":
          try { currentCtx?.abort() } catch { /* ignore */ }
          break
        default:
          break
      }
    })

    const drop = () => { clients.delete(socket) }
    socket.on("close", drop)
    socket.on("error", drop)
  }

  // ---------- server lifecycle ----------

  function startServer(ctx?: ExtensionContext) {
    if (server) return
    server = createServer((req, res) => {
      res.writeHead(200, { "content-type": "text/plain" })
      res.end("pi-lan-bridge: connect with a WebSocket client\n")
    })
    wss = new WebSocketServer({ server })
    wss.on("connection", handleClient)
    server.on("error", (err) => {
      ctx?.ui.notify(`LAN bridge error: ${err.message}`, "error")
      server = null
      wss = null
    })
    server.listen(port, "0.0.0.0", () => {
      const urls = lanAddresses(port)
      ctx?.ui.notify(`LAN bridge listening: ${urls[0] ?? `ws://0.0.0.0:${port}`}`, "info")
    })
  }

  function stopServer() {
    for (const [, pending] of pendingApprovals) {
      clearTimeout(pending.timer)
      pending.resolve(false)
    }
    pendingApprovals.clear()
    for (const client of clients) {
      try { client.terminate() } catch { /* ignore */ }
    }
    clients.clear()
    wss?.close()
    server?.close()
    wss = null
    server = null
  }

  // ---------- pi event wiring ----------

  pi.on("session_start", (_event, ctx) => {
    currentCtx = ctx
    startServer(ctx)
  })

  pi.on("session_shutdown", () => {
    currentCtx = null
    stopServer()
  })

  pi.on("message_update", (event) => {
    const ev = event.assistantMessageEvent
    if (!ev) return
    if (ev.type === "text_delta") {
      broadcast({ type: "text_delta", text: ev.delta ?? "" })
    } else if (ev.type === "thinking_delta") {
      broadcast({ type: "thinking_delta", text: ev.delta ?? "" })
    } else if (ev.type === "toolcall_start") {
      const id = (ev as unknown as { id?: string }).id
      const toolName = (ev as unknown as { toolName?: string }).toolName
      if (id) broadcast({ type: "tool_started", id, name: toolName ?? "tool", summary: "", input: "" })
    }
  })

  pi.on("tool_execution_start", (event) => {
    broadcast({
      type: "tool_started",
      id: event.toolCallId,
      name: event.toolName,
      summary: summarize(event.args),
      input: safeJSON(event.args),
    })
  })

  pi.on("tool_execution_update", (event) => {
    const text = contentText(event.partialResult)
    if (text) broadcast({ type: "tool_output", id: event.toolCallId, chunk: text })
  })

  pi.on("tool_execution_end", (event) => {
    const text = contentText(event.result)
    if (text) broadcast({ type: "tool_output", id: event.toolCallId, chunk: text })
    broadcast({
      type: "tool_finished",
      id: event.toolCallId,
      status: event.isError ? "failed" : "success",
      diff: (event.result as { details?: { diff?: string } } | undefined)?.details?.diff ?? null,
    })
  })

  // Approval gate: forward to the app and await the user's decision.
  pi.on("tool_call", async (event) => {
    if (AUTO_APPROVE.has(event.toolName)) return undefined
    if (clients.size === 0) return undefined // no app connected: let the local UI handle it
    const id = event.toolCallId
    broadcast({
      type: "tool_started",
      id,
      name: event.toolName,
      summary: summarize(event.input),
      input: safeJSON(event.input),
    })
    broadcast({
      type: "permission_requested",
      id,
      title: event.toolName,
      message: summarize(event.input),
    })
    const allow = await new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        pendingApprovals.delete(id)
        resolve(false)
      }, APPROVAL_TIMEOUT_MS)
      pendingApprovals.set(id, { resolve, timer })
    })
    if (!allow) return { block: true, reason: "Denied by user (pi-lan-bridge)" }
    return undefined
  })

  pi.on("agent_end", (event) => {
    const lastAssistant = [...event.messages]
      .reverse()
      .find((m) => m.role === "assistant" && (m as { usage?: unknown }).usage) as
      | { usage?: { input?: number; output?: number; cost?: { total?: number } } }
      | undefined
    lastUsage = lastAssistant?.usage ?? lastUsage
    broadcast({
      type: "message_finished",
      input: lastUsage?.input ?? 0,
      output: lastUsage?.output ?? 0,
      cost: lastUsage?.cost?.total ?? 0,
    })
  })

  // ---------- /lanbridge command ----------

  pi.registerCommand("mobilebridge", {
    description: "Mobile bridge for the Pi iOS app. Usage: /mobilebridge start|stop|status|port <n>",
    handler: async (args, ctx) => {
      const [sub, value] = args.trim().split(/\s+/, 2)
      switch (sub ?? "status") {
        case "start":
          startServer(ctx)
          ctx.ui.notify(`LAN bridge: ${lanAddresses(port).join(", ") || "listening"}`, "info")
          break
        case "stop":
          stopServer()
          ctx.ui.notify("LAN bridge stopped", "info")
          break
        case "port": {
          const n = Number(value)
          if (!Number.isInteger(n) || n < 1024 || n > 65535) {
            ctx.ui.notify("Usage: /mobilebridge port <1024-65535>", "warning")
            break
          }
          port = n
          if (server) { stopServer(); startServer(ctx) }
          ctx.ui.notify(`LAN bridge port set to ${port}`, "info")
          break
        }
        case "status":
        default:
          ctx.ui.notify(
            server
              ? `LAN bridge listening on :${port}, ${clients.size} client(s): ${lanAddresses(port).join(", ")}`
              : "LAN bridge stopped",
            "info")
          break
      }
    },
  })
}

function safeJSON(value: unknown): string {
  try { return JSON.stringify(value ?? {}) } catch { return "{}" }
}
