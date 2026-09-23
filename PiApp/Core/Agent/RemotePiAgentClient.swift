import Foundation

/// Native client for the separately-installed `remote-pi` Pi extension.
/// This coexists with WebSocketAgentClient, whose custom bridge protocol is
/// intentionally preserved for existing users.
actor RemotePiAgentClient: AgentClient {
    nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private let store: RemotePiStore
    private var connection: RemotePiConnection?
    private var receiveTask: Task<Void, Never>?
    private var activeMessageID: String?
    private var pendingTools: [String: UUID] = [:]

    init(store: RemotePiStore) {
        self.store = store
        var streamContinuation: AsyncStream<AgentEvent>.Continuation!
        events = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation
    }

    deinit {
        receiveTask?.cancel()
        continuation.finish()
        if let connection {
            Task { await connection.close() }
        }
    }

    func sendPrompt(_ text: String, history: [ChatTurn], permission: PermissionMode) async {
        do {
            let connection = try await ensureConnection()
            let id = RemotePiID.make()
            activeMessageID = id
            try await connection.sendInner([
                "type": "user_message",
                "id": id,
                "text": text,
            ])
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    func answerPermission(allow: Bool) async {
        guard let connection, let remoteID = pendingTools.keys.first else { return }
        try? await connection.sendInner([
            "type": "approve_tool",
            "id": RemotePiID.make(),
            "tool_call_id": remoteID,
            "decision": allow ? "allow" : "deny",
        ])
    }

    func abort() async {
        guard let connection, let target = activeMessageID else { return }
        try? await connection.sendInner([
            "type": "cancel",
            "id": RemotePiID.make(),
            "target_id": target,
        ])
    }

    /// Opens the relay connection before the first prompt so room metadata,
    /// especially the active remote model, is visible in the chat footer.
    func prepare() async {
        _ = try? await ensureConnection()
    }

    private func ensureConnection() async throws -> RemotePiConnection {
        if let connection { return connection }
        let configuration = try await store.configuration()
        let newConnection = RemotePiConnection(configuration: configuration)
        try await newConnection.connect()
        connection = newConnection
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    switch try await newConnection.receivePacket() {
                    case .message(let message):
                        await self?.handle(message)
                    case .model(let name):
                        await self?.setRemoteModel(name)
                    }
                }
            } catch is CancellationError {
                // Reconnect/teardown.
            } catch {
                await self?.connectionFailed(error, connection: newConnection)
            }
        }
        return newConnection
    }

    private func connectionFailed(_ error: Error, connection: RemotePiConnection) {
        if self.connection === connection {
            self.connection = nil
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    private func setRemoteModel(_ name: String) async {
        await store.updateActiveModel(name)
    }

    private func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "agent_chunk":
            guard let reply = message["in_reply_to"] as? String,
                  reply == activeMessageID,
                  let delta = message["delta"] as? String else { return }
            continuation.yield(.textDelta(delta))

        case "agent_done":
            guard let reply = message["in_reply_to"] as? String,
                  reply == activeMessageID else { return }
            var usage = TokenUsage()
            if let raw = message["usage"] as? [String: Any] {
                usage.input = number(raw["input_tokens"])
                usage.output = number(raw["output_tokens"])
            }
            activeMessageID = nil
            continuation.yield(.messageFinished(usage))

        case "tool_request":
            guard activeMessageID != nil,
                  let remoteID = message["tool_call_id"] as? String else { return }
            let localID = UUID()
            pendingTools[remoteID] = localID
            let tool = (message["tool"] as? String) ?? "Tool"
            let input = jsonString(message["args"])
            continuation.yield(.toolCallStarted(ToolCall(
                id: localID,
                name: tool,
                summary: toolSummary(message["args"]),
                input: input
            )))

        case "tool_result":
            guard let remoteID = message["tool_call_id"] as? String,
                  let localID = pendingTools.removeValue(forKey: remoteID) else { return }
            let error = message["error"] as? String
            let output = error ?? jsonString(message["result"])
            if !output.isEmpty {
                continuation.yield(.toolCallOutput(id: localID, chunk: output))
            }
            continuation.yield(.toolCallFinished(
                id: localID,
                status: error == nil ? .success : .failed,
                diff: nil
            ))

        case "error", "pair_error":
            let message = (message["message"] as? String)
                ?? (message["code"] as? String)
                ?? "Remote Pi error"
            continuation.yield(.failed(message))

        case "bye":
            continuation.yield(.failed("Remote Pi went offline: \((message["reason"] as? String) ?? "shutdown")"))
            connection = nil

        default:
            // user_input echoes, session history, presence and action replies do
            // not map to the current AgentClient UI surface yet.
            break
        }
    }

    private func number(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private func jsonString(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func toolSummary(_ value: Any?) -> String {
        guard let dictionary = value as? [String: Any] else { return "" }
        for key in ["path", "command", "query", "pattern", "url"] {
            if let value = dictionary[key] as? String {
                return String(value.prefix(100))
            }
        }
        return ""
    }
}
