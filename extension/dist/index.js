// src/index.ts
import { createServer } from "node:http";
import os from "node:os";
import { WebSocketServer, WebSocket } from "ws";
var DEFAULT_PORT = 7777;
var APPROVAL_TIMEOUT_MS = 6e4;
var AUTO_APPROVE = /* @__PURE__ */ new Set(["read", "grep", "glob", "ls", "find"]);
function summarize(args) {
  if (!args || typeof args !== "object") return "";
  const a = args;
  const candidate = a.path ?? a.file_path ?? a.command ?? a.pattern ?? a.query;
  if (candidate != null) return String(candidate).slice(0, 80);
  try {
    return JSON.stringify(args).slice(0, 80);
  } catch {
    return "";
  }
}
function contentText(result) {
  if (!result) return "";
  if (typeof result === "string") return result;
  const content = result.content;
  if (Array.isArray(content)) {
    return content.map((b) => b && typeof b.text === "string" ? b.text : "").filter(Boolean).join("\n");
  }
  return "";
}
function lanAddresses(port) {
  return Object.values(os.networkInterfaces()).flat().filter((n) => n && n.family === "IPv4" && !n.internal).map((n) => `ws://${n.address}:${port}`);
}
function index_default(pi) {
  let server = null;
  let wss = null;
  let port = DEFAULT_PORT;
  const clients = /* @__PURE__ */ new Set();
  const pendingApprovals = /* @__PURE__ */ new Map();
  let currentCtx = null;
  let lastUsage = null;
  const broadcast = (obj) => {
    const frame = JSON.stringify(obj);
    for (const client of clients) {
      if (client.readyState === WebSocket.OPEN) client.send(frame);
    }
  };
  function handleClient(socket) {
    clients.add(socket);
    socket.send(JSON.stringify({ type: "bridge_ready", binary: "extension", port }));
    socket.on("message", (data) => {
      let msg;
      try {
        msg = JSON.parse(String(data));
      } catch {
        return;
      }
      switch (msg.type) {
        case "prompt": {
          const prompt = String(msg.text ?? "");
          if (!prompt.trim()) return;
          lastUsage = null;
          try {
            if (currentCtx?.isIdle() === false) {
              pi.sendUserMessage(prompt, { deliverAs: "followUp" });
            } else {
              pi.sendUserMessage(prompt);
            }
          } catch (err) {
            socket.send(JSON.stringify({ type: "error", message: String(err) }));
          }
          break;
        }
        case "permission_answer": {
          const first = pendingApprovals.entries().next().value;
          if (first) {
            const [id, pending] = first;
            clearTimeout(pending.timer);
            pendingApprovals.delete(id);
            pending.resolve(!!msg.allow);
          }
          break;
        }
        case "abort":
          try {
            currentCtx?.abort();
          } catch {
          }
          break;
        default:
          break;
      }
    });
    const drop = () => {
      clients.delete(socket);
    };
    socket.on("close", drop);
    socket.on("error", drop);
  }
  function startServer(ctx) {
    if (server) return;
    server = createServer((req, res) => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("pi-lan-bridge: connect with a WebSocket client\n");
    });
    wss = new WebSocketServer({ server });
    wss.on("connection", handleClient);
    server.on("error", (err) => {
      ctx?.ui.notify(`LAN bridge error: ${err.message}`, "error");
      server = null;
      wss = null;
    });
    server.listen(port, "0.0.0.0", () => {
      const urls = lanAddresses(port);
      ctx?.ui.notify(`LAN bridge listening: ${urls[0] ?? `ws://0.0.0.0:${port}`}`, "info");
    });
  }
  function stopServer() {
    for (const [, pending] of pendingApprovals) {
      clearTimeout(pending.timer);
      pending.resolve(false);
    }
    pendingApprovals.clear();
    for (const client of clients) {
      try {
        client.terminate();
      } catch {
      }
    }
    clients.clear();
    wss?.close();
    server?.close();
    wss = null;
    server = null;
  }
  pi.on("session_start", (_event, ctx) => {
    currentCtx = ctx;
    startServer(ctx);
  });
  pi.on("session_shutdown", () => {
    currentCtx = null;
    stopServer();
  });
  pi.on("message_update", (event) => {
    const ev = event.assistantMessageEvent;
    if (!ev) return;
    if (ev.type === "text_delta") {
      broadcast({ type: "text_delta", text: ev.delta ?? "" });
    } else if (ev.type === "thinking_delta") {
      broadcast({ type: "thinking_delta", text: ev.delta ?? "" });
    } else if (ev.type === "toolcall_start") {
      const id = ev.id;
      const toolName = ev.toolName;
      if (id) broadcast({ type: "tool_started", id, name: toolName ?? "tool", summary: "", input: "" });
    }
  });
  pi.on("tool_execution_start", (event) => {
    broadcast({
      type: "tool_started",
      id: event.toolCallId,
      name: event.toolName,
      summary: summarize(event.args),
      input: safeJSON(event.args)
    });
  });
  pi.on("tool_execution_update", (event) => {
    const text = contentText(event.partialResult);
    if (text) broadcast({ type: "tool_output", id: event.toolCallId, chunk: text });
  });
  pi.on("tool_execution_end", (event) => {
    const text = contentText(event.result);
    if (text) broadcast({ type: "tool_output", id: event.toolCallId, chunk: text });
    broadcast({
      type: "tool_finished",
      id: event.toolCallId,
      status: event.isError ? "failed" : "success",
      diff: event.result?.details?.diff ?? null
    });
  });
  pi.on("tool_call", async (event) => {
    if (AUTO_APPROVE.has(event.toolName)) return void 0;
    if (clients.size === 0) return void 0;
    const id = event.toolCallId;
    broadcast({
      type: "tool_started",
      id,
      name: event.toolName,
      summary: summarize(event.input),
      input: safeJSON(event.input)
    });
    broadcast({
      type: "permission_requested",
      id,
      title: event.toolName,
      message: summarize(event.input)
    });
    const allow = await new Promise((resolve) => {
      const timer = setTimeout(() => {
        pendingApprovals.delete(id);
        resolve(false);
      }, APPROVAL_TIMEOUT_MS);
      pendingApprovals.set(id, { resolve, timer });
    });
    if (!allow) return { block: true, reason: "Denied by user (pi-lan-bridge)" };
    return void 0;
  });
  pi.on("agent_end", (event) => {
    const lastAssistant = [...event.messages].reverse().find((m) => m.role === "assistant" && m.usage);
    lastUsage = lastAssistant?.usage ?? lastUsage;
    broadcast({
      type: "message_finished",
      input: lastUsage?.input ?? 0,
      output: lastUsage?.output ?? 0,
      cost: lastUsage?.cost?.total ?? 0
    });
  });
  pi.registerCommand("mobilebridge", {
    description: "Mobile bridge for the Pi iOS app. Usage: /mobilebridge start|stop|status|port <n>",
    handler: async (args, ctx) => {
      const [sub, value] = args.trim().split(/\s+/, 2);
      switch (sub ?? "status") {
        case "start":
          startServer(ctx);
          ctx.ui.notify(`LAN bridge: ${lanAddresses(port).join(", ") || "listening"}`, "info");
          break;
        case "stop":
          stopServer();
          ctx.ui.notify("LAN bridge stopped", "info");
          break;
        case "port": {
          const n = Number(value);
          if (!Number.isInteger(n) || n < 1024 || n > 65535) {
            ctx.ui.notify("Usage: /mobilebridge port <1024-65535>", "warning");
            break;
          }
          port = n;
          if (server) {
            stopServer();
            startServer(ctx);
          }
          ctx.ui.notify(`LAN bridge port set to ${port}`, "info");
          break;
        }
        case "status":
        default:
          ctx.ui.notify(
            server ? `LAN bridge listening on :${port}, ${clients.size} client(s): ${lanAddresses(port).join(", ")}` : "LAN bridge stopped",
            "info"
          );
          break;
      }
    }
  });
}
function safeJSON(value) {
  try {
    return JSON.stringify(value ?? {});
  } catch {
    return "{}";
  }
}
export {
  index_default as default
};
