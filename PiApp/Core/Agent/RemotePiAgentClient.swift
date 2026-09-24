import Foundation

/// Native client for the separately-installed `remote-pi` Pi extension.
/// This coexists with WebSocketAgentClient, whose custom bridge protocol is
/// intentionally preserved for existing users.
actor RemotePiAgentClient: AgentClient {
    nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private let store: RemotePiStore
    private let peerID: String
    private let activationTask: Task<Void, Never>?
    private var connection: RemotePiConnection?
    private var connectionTask: Task<RemotePiConnection, Error>?
    private var connectionTaskGeneration: UInt = 0
    private var connectionGeneration: UInt = 0
    private var receiveTask: Task<Void, Never>?
    private var activeMessageID: String?
    private var pendingTools: [String: UUID] = [:]
    private var isShutDown = false

    init(store: RemotePiStore, peerID: String, predecessor: RemotePiAgentClient? = nil) {
        self.store = store
        self.peerID = peerID
        if let predecessor {
            // Relay connections share one owner identity. Finish closing the
            // previous session's socket before this client authenticates, or a
            // fast session switch can leave the new socket looking connected
            // locally while the relay still routes to the old one.
            activationTask = Task {
                await predecessor.shutdown()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        } else {
            activationTask = nil
        }
        var streamContinuation: AsyncStream<AgentEvent>.Continuation!
        events = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation
    }

    deinit {
        connectionTask?.cancel()
        receiveTask?.cancel()
        continuation.finish()
        if let connection {
            Task { await connection.close() }
        }
    }

    func sendPrompt(_ text: String, history: [ChatTurn], permission: PermissionMode) async {
        do {
            let connection = try await ensureConnectionWithRetry()
            let id = RemotePiID.make()
            activeMessageID = id
            try await connection.sendInner([
                "type": "user_message",
                "id": id,
                "text": text,
            ])
        } catch {
            await resetConnection()
            activeMessageID = nil
            continuation.yield(.failed(Self.userFacingMessage(for: error)))
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
        _ = try? await ensureConnectionWithRetry()
    }

    /// iOS suspends WebSockets in the background. Force a clean socket on
    /// foreground instead of attempting to reuse a half-open URLSession task.
    func reconnectAfterForeground() async {
        guard !isShutDown else { return }
        await resetConnection()
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = try? await ensureConnectionWithRetry()
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        activeMessageID = nil
        await resetConnection()
        continuation.finish()
    }

    private func ensureConnectionWithRetry() async throws -> RemotePiConnection {
        var lastError: Error = RemotePiError.connectionClosed
        for attempt in 0..<3 {
            do {
                return try await ensureConnection()
            } catch {
                lastError = error
                Self.debugLog("connect attempt \(attempt + 1) failed: \(Self.errorDetails(error))")
                guard Self.isTransient(error), attempt < 2, !isShutDown else { throw error }
                let delay = attempt == 0 ? 400_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: UInt64(delay))
            }
        }
        throw lastError
    }

    private func ensureConnection() async throws -> RemotePiConnection {
        if let activationTask { await activationTask.value }
        guard !isShutDown else { throw RemotePiError.connectionClosed }
        if let connection { return connection }

        // `prepare()` and an immediate first send can overlap because actor
        // methods are re-entrant at an `await`. Share one handshake instead of
        // opening two sockets with the same relay identity (the relay may abort
        // one of those duplicate connections with POSIX ECONNABORTED).
        let task: Task<RemotePiConnection, Error>
        let taskGeneration: UInt
        if let connectionTask {
            task = connectionTask
            taskGeneration = connectionTaskGeneration
        } else {
            let store = self.store
            let peerID = self.peerID
            task = Task {
                let configuration = try await store.configuration(for: peerID)
                let newConnection = RemotePiConnection(configuration: configuration)
                try await newConnection.connect()
                return newConnection
            }
            connectionTask = task
            connectionTaskGeneration = connectionGeneration
            taskGeneration = connectionGeneration
        }

        let newConnection: RemotePiConnection
        do {
            newConnection = try await task.value
        } catch {
            if connectionTaskGeneration == taskGeneration {
                connectionTask = nil
            }
            throw error
        }
        if connectionTaskGeneration == taskGeneration {
            connectionTask = nil
        }
        guard taskGeneration == connectionGeneration else {
            await newConnection.close()
            throw CancellationError()
        }

        // Another waiter for the same single-flight task may have installed
        // the connection while this actor was suspended.
        if let connection { return connection }
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

    private func connectionFailed(_ error: Error, connection: RemotePiConnection) async {
        guard self.connection === connection else { return }
        Self.debugLog("receive loop disconnected: \(Self.errorDetails(error))")
        let interruptedResponse = activeMessageID != nil
        self.connection = nil
        connectionGeneration &+= 1
        receiveTask = nil
        activeMessageID = nil
        await connection.close()

        // Idle relay sockets are disposable: reconnect on the next send and do
        // not append a transport warning to an old assistant message.
        if interruptedResponse {
            continuation.yield(.failed(Self.userFacingMessage(for: error)))
        }
    }

    private func resetConnection() async {
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        guard let connection else { return }
        self.connection = nil
        await connection.close()
    }

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        let transientURLCodes: Set<Int> = [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
        ]
        if nsError.domain == NSPOSIXErrorDomain ||
            (nsError.domain == NSURLErrorDomain && transientURLCodes.contains(nsError.code)) {
            return "Remote Pi connection was interrupted. Check that Pi and the relay are online, then send again to reconnect."
        }
        return error.localizedDescription
    }

    private nonisolated static func isTransient(_ error: Error) -> Bool {
        if case RemotePiError.connectionClosed = error { return true }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return true }
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
        ].contains(nsError.code)
    }

    private nonisolated static func errorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }

    private nonisolated static func debugLog(_ message: String) {
#if DEBUG
        FileHandle.standardError.write(Data("[PiMobile][RemotePi] \(message)\n".utf8))
#endif
    }

    private func setRemoteModel(_ name: String) async {
        await store.updateActiveModel(name, for: peerID)
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
