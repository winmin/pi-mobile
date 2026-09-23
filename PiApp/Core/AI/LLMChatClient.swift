import Foundation

enum LLMError: LocalizedError {
    case invalidBaseURL(String)
    case noModel
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "Invalid provider base URL “\(url)”. Fix it in Settings → AI Providers."
        case .noModel:
            return "No model selected. Pick one in Settings → AI Providers."
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        }
    }
}

/// Streams chat completions directly from the user's configured LLM provider
/// (OpenAI-compatible or Anthropic Messages API) over SSE. No RPC involved.
final class LLMChatClient: AgentClient {
    let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private let providerStore: ProviderStore
    private var streamTask: Task<Void, Never>?

    init(providerStore: ProviderStore) {
        self.providerStore = providerStore
        var cont: AsyncStream<AgentEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func sendPrompt(_ text: String, history: [ChatTurn], permission: PermissionMode) async {
        streamTask?.cancel()
        streamTask = Task { await run(text: text, history: history) }
    }

    func answerPermission(allow: Bool) async {
        // Direct API chat has no tool permission round trip.
    }

    func abort() async {
        streamTask?.cancel()
    }

    // MARK: - Request lifecycle

    private func run(text: String, history: [ChatTurn]) async {
        do {
            guard let provider = await providerStore.activeProvider else {
                throw ProviderError.noActiveProvider
            }
            let credential = try await providerStore.validCredential(for: provider.id)
            let modelID = await providerStore.activeModelID ?? provider.models.first?.id ?? ""
            guard !modelID.isEmpty else { throw LLMError.noModel }

            let request = try buildRequest(provider: provider, credential: credential,
                                           model: modelID, text: text, history: history)
            let (bytes, response) = try await HTTPRetry.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                var body = ""
                for try await line in bytes.lines {
                    body += line + "\n"
                    if body.count > 400 { break }
                }
                throw LLMError.http(status, String(body.prefix(200)))
            }

            switch provider.api {
            case .openaiCompletions:
                try await parseOpenAI(bytes)
            case .anthropicMessages:
                try await parseAnthropic(bytes)
            }
        } catch is CancellationError {
            // Aborted by the user; AppModel has already reset the session state.
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    // MARK: - Request building

    private func buildRequest(provider: AIProvider, credential: AICredential, model: String,
                              text: String, history: [ChatTurn]) throws -> URLRequest {
        guard !provider.baseUrl.isEmpty,
              let base = URL(string: provider.baseUrl) else {
            throw LLMError.invalidBaseURL(provider.baseUrl)
        }

        switch provider.api {
        case .openaiCompletions:
            var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            switch credential {
            case .apiKey(let key):
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            case .oauth(let access, _, _, _):
                request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            }
            var messages: [[String: Any]] = history.map {
                ["role": $0.role.rawValue, "content": $0.text]
            }
            messages.append(["role": "user", "content": text])
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": messages,
                "stream": true,
                "stream_options": ["include_usage": true],
            ])
            return request

        case .anthropicMessages:
            var request = URLRequest(url: base.appendingPathComponent("v1/messages"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            var system: [[String: Any]] = []
            if case .oauth(let access, _, _, _) = credential, access.hasPrefix("sk-ant-oat") {
                // Claude Code OAuth tokens require the CLI identity block and headers.
                system.append(["type": "text",
                               "text": "You are Claude Code, Anthropic's official CLI for Claude."])
                request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                request.setValue("claude-cli/2.1.280", forHTTPHeaderField: "user-agent")
                request.setValue("cli", forHTTPHeaderField: "x-app")
                request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
                request.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            } else if case .apiKey(let key) = credential {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            system.append(["type": "text", "text": "You are Pi, a helpful coding assistant."])

            var messages: [[String: Any]] = history.map { turn in
                ["role": turn.role.rawValue,
                 "content": [["type": "text", "text": turn.text]]]
            }
            messages.append(["role": "user",
                             "content": [["type": "text", "text": text]]])
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 8192,
                "stream": true,
                "system": system,
                "messages": messages,
            ])
            return request
        }
    }

    // MARK: - SSE parsing

    private func parseOpenAI(_ bytes: URLSession.AsyncBytes) async throws {
        var usage = TokenUsage()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                continuation.yield(.failed(message))
                return
            }
            if let choices = json["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.textDelta(content))
            }
            if let u = json["usage"] as? [String: Any] {
                usage.input = (u["prompt_tokens"] as? Int) ?? usage.input
                usage.output = (u["completion_tokens"] as? Int) ?? usage.output
            }
        }
        continuation.yield(.messageFinished(usage))
    }

    private func parseAnthropic(_ bytes: URLSession.AsyncBytes) async throws {
        var usage = TokenUsage()
        var event = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            switch event {
            case "message_start":
                if let message = json["message"] as? [String: Any],
                   let u = message["usage"] as? [String: Any] {
                    usage.input = (u["input_tokens"] as? Int) ?? usage.input
                }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   (delta["type"] as? String) == "text_delta",
                   let text = delta["text"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                }
            case "message_delta":
                if let u = json["usage"] as? [String: Any] {
                    usage.output = (u["output_tokens"] as? Int) ?? usage.output
                }
            case "message_stop":
                continuation.yield(.messageFinished(usage))
                return
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String
                    ?? "Unknown Anthropic stream error"
                continuation.yield(.failed(message))
                return
            default:
                break
            }
        }
        continuation.yield(.messageFinished(usage))
    }
}
