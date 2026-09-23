import Foundation

/// Talks line-delimited JSON to a remote host running `pi --mode rpc`
/// (or the pi monorepo's `server` package) over WebSocket.
///
/// Wire format (one JSON object per message):
///   → {"type":"prompt","text":"...","permission":"default"}
///   → {"type":"permission_answer","allow":true}
///   → {"type":"abort"}
///   ← {"type":"text_delta","text":"..."} / {"type":"thinking_delta",...}
///   ← {"type":"tool_started","id":"...","name":"...","summary":"..."}
///   ← {"type":"tool_output","id":"...","chunk":"..."}
///   ← {"type":"tool_finished","id":"...","status":"success","diff":"..."}
///   ← {"type":"permission_requested","id":"..."}
///   ← {"type":"message_finished","input":0,"output":0,"cost":0.0}
final class WebSocketAgentClient: AgentClient {
    let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pendingCalls: [String: UUID] = [:]

    init(url: URL) {
        var cont: AsyncStream<AgentEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        Task { await receiveLoop() }
    }

    func sendPrompt(_ text: String, history: [ChatTurn], permission: PermissionMode) async {
        var object: [String: Any] = ["type": "prompt", "text": text, "permission": permission.rawValue]
        if !history.isEmpty {
            object["history"] = history.map { ["role": $0.role.rawValue, "text": $0.text] }
        }
        await send(object)
    }

    func answerPermission(allow: Bool) async {
        await send(["type": "permission_answer", "allow": allow])
    }

    func abort() async {
        await send(["type": "abort"])
    }

    // MARK: - Plumbing

    private func send(_ object: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        try? await task?.send(.string(string))
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleLine(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleLine(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                continuation.yield(.failed(error.localizedDescription))
                return
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "text_delta":
            if let t = obj["text"] as? String { continuation.yield(.textDelta(t)) }
        case "thinking_delta":
            if let t = obj["text"] as? String { continuation.yield(.thinkingDelta(t)) }
        case "tool_started":
            let remoteID = (obj["id"] as? String) ?? UUID().uuidString
            let localID = UUID()
            pendingCalls[remoteID] = localID
            let call = ToolCall(
                id: localID,
                name: (obj["name"] as? String) ?? "Tool",
                summary: (obj["summary"] as? String) ?? "",
                input: (obj["input"] as? String) ?? "")
            continuation.yield(.toolCallStarted(call))
        case "tool_output":
            if let rid = obj["id"] as? String, let local = pendingCalls[rid],
               let chunk = obj["chunk"] as? String {
                continuation.yield(.toolCallOutput(id: local, chunk: chunk))
            }
        case "tool_finished":
            if let rid = obj["id"] as? String, let local = pendingCalls[rid] {
                let status: ToolStatus = ((obj["status"] as? String) == "failed") ? .failed : .success
                continuation.yield(.toolCallFinished(id: local, status: status, diff: obj["diff"] as? String))
                pendingCalls.removeValue(forKey: rid)
            }
        case "permission_requested":
            if let rid = obj["id"] as? String, let local = pendingCalls[rid] {
                continuation.yield(.permissionRequested(id: local))
            }
        case "message_finished":
            var usage = TokenUsage()
            usage.input = (obj["input"] as? Int) ?? 0
            usage.output = (obj["output"] as? Int) ?? 0
            usage.costUSD = (obj["cost"] as? Double) ?? 0
            continuation.yield(.messageFinished(usage))
        case "error":
            continuation.yield(.failed((obj["message"] as? String) ?? "Unknown error"))
        default:
            break
        }
    }
}
