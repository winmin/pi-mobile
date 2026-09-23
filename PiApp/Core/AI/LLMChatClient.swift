import Foundation
import UIKit

enum LLMError: LocalizedError {
    case invalidBaseURL(String)
    case noModel
    case missingCodexAccountID
    case http(Int, String)
    case streamInterrupted

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "Invalid provider base URL “\(url)”. Fix it in Settings → AI Providers."
        case .noModel:
            return "No model selected. Pick one in Settings → AI Providers."
        case .missingCodexAccountID:
            return "The ChatGPT login token has no account ID. Sign out of OpenAI and sign in again."
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .streamInterrupted:
            return "The response stream ended before the provider finished it."
        }
    }
}

/// Streams chat directly from the user's configured provider over SSE.
/// OpenAI API keys use Chat Completions, while ChatGPT OAuth credentials use
/// the separate Codex Responses adapter (the same split used by pi-ai).
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
            Self.log("request start provider=\(provider.id) api=\(provider.api.rawValue)")
            let credential = try await providerStore.validCredential(for: provider.id)
            let configuredModelID = await providerStore.activeModelID
            let fallbackModelID = await providerStore.availableModels(for: provider).first?.id
            let modelID = configuredModelID ?? fallbackModelID ?? ""
            guard !modelID.isEmpty else { throw LLMError.noModel }
            let transport = isOpenAICodex(provider: provider, credential: credential)
                ? "openai-codex-responses"
                : provider.api.rawValue
            Self.log("credential=\(credential.logKind) transport=\(transport) model=\(modelID)")

            var requestText = text
            var requestHistory = history
            var receivedText = ""
            var retryCount = 0

            while true {
                do {
                    let request = try buildRequest(provider: provider, credential: credential,
                                                   model: modelID, text: requestText,
                                                   history: requestHistory)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let contentType = (response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                    Self.log("response status=\(status) content-type=\(contentType)")
                    guard (200..<300).contains(status) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line + "\n"
                            if body.count > 400 { break }
                        }
                        let summary = String(body.prefix(500))
                        Self.log("response failure status=\(status) body=\(Self.redact(summary))")
                        throw LLMError.http(status, String(summary.prefix(200)))
                    }

                    let usage: TokenUsage
                    if isOpenAICodex(provider: provider, credential: credential) {
                        usage = try await parseOpenAICodex(bytes) { chunk in
                            receivedText += chunk
                            continuation.yield(.textDelta(chunk))
                        }
                    } else {
                        switch provider.api {
                        case .openaiCompletions:
                            usage = try await parseOpenAI(bytes) { chunk in
                                receivedText += chunk
                                continuation.yield(.textDelta(chunk))
                            }
                        case .anthropicMessages:
                            usage = try await parseAnthropic(bytes) { chunk in
                                receivedText += chunk
                                continuation.yield(.textDelta(chunk))
                            }
                        }
                    }
                    Self.log("stream completed input=\(usage.input) output=\(usage.output)")
                    continuation.yield(.messageFinished(usage))
                    return
                } catch {
                    Self.log("attempt \(retryCount + 1) failed: \(String(reflecting: error))")
                    guard retryCount < 2, isRetryableStreamError(error), !Task.isCancelled else {
                        throw error
                    }

                    retryCount += 1
                    try await waitUntilApplicationIsActive()
                    try await Task.sleep(nanoseconds: UInt64(retryCount) * 750_000_000)

                    // Streaming APIs do not expose a resume cursor. If some text was
                    // already delivered, continue from that partial assistant turn
                    // instead of replaying the original request and duplicating it.
                    if !receivedText.isEmpty {
                        requestHistory = history + [
                            ChatTurn(role: .user, text: text),
                            ChatTurn(role: .assistant, text: receivedText),
                        ]
                        requestText = "Continue the previous assistant response exactly where it stopped. "
                            + "Do not repeat any text and output only the continuation."
                    }
                }
            }
        } catch is CancellationError {
            Self.log("request cancelled")
            // Aborted by the user; AppModel has already reset the session state.
        } catch {
            Self.log("request failed: \(String(reflecting: error))")
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    // MARK: - Request building

    private func buildRequest(provider: AIProvider, credential: AICredential, model: String,
                              text: String, history: [ChatTurn]) throws -> URLRequest {
        if isOpenAICodex(provider: provider, credential: credential) {
            return try buildOpenAICodexRequest(credential: credential, model: model,
                                               text: text, history: history)
        }

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

    /// ChatGPT OAuth access tokens are not OpenAI Platform API keys. They must
    /// be sent to the ChatGPT Codex Responses endpoint with its account header
    /// and Responses-shaped input, rather than to /v1/chat/completions.
    private func buildOpenAICodexRequest(credential: AICredential, model: String,
                                         text: String, history: [ChatTurn]) throws -> URLRequest {
        guard case .oauth(let access, _, _, let storedAccountID) = credential else {
            preconditionFailure("Codex request requires an OAuth credential")
        }
        guard let accountID = storedAccountID ?? Self.codexAccountID(fromJWT: access),
              !accountID.isEmpty else {
            throw LLMError.missingCodexAccountID
        }

        let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("pi", forHTTPHeaderField: "originator")
        request.setValue("pi-mobile (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var input: [[String: Any]] = []
        for (index, turn) in history.enumerated() {
            switch turn.role {
            case .user:
                input.append(Self.codexUserMessage(turn.text))
            case .assistant:
                input.append(Self.codexAssistantMessage(turn.text, index: index))
            }
        }
        input.append(Self.codexUserMessage(text))

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": "You are Pi, a helpful coding assistant.",
            "input": input,
            "text": ["verbosity": "low"],
            "include": ["reasoning.encrypted_content"],
            "tool_choice": "auto",
            "parallel_tool_calls": true,
        ])
        return request
    }

    private func isOpenAICodex(provider: AIProvider, credential: AICredential) -> Bool {
        guard provider.id == "openai" else { return false }
        if case .oauth = credential { return true }
        return false
    }

    private static func codexUserMessage(_ text: String) -> [String: Any] {
        [
            "role": "user",
            "content": [["type": "input_text", "text": text]],
        ]
    }

    private static func codexAssistantMessage(_ text: String, index: Int) -> [String: Any] {
        [
            "type": "message",
            "role": "assistant",
            "content": [["type": "output_text", "text": text, "annotations": []]],
            "status": "completed",
            "id": "msg_\(index)",
        ]
    }

    private static func codexAccountID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return auth["chatgpt_account_id"] as? String
    }

    // MARK: - SSE parsing

    private func parseOpenAI(_ bytes: URLSession.AsyncBytes,
                             onText: (String) -> Void) async throws -> TokenUsage {
        var usage = TokenUsage()
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                completed = true
                break
            }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw LLMError.http(-1, message)
            }
            if let choices = json["choices"] as? [[String: Any]],
               let choice = choices.first {
                if let delta = choice["delta"] as? [String: Any],
                   let content = delta["content"] as? String, !content.isEmpty {
                    onText(content)
                }
                if choice["finish_reason"] is String {
                    completed = true
                }
            }
            if let u = json["usage"] as? [String: Any] {
                usage.input = (u["prompt_tokens"] as? Int) ?? usage.input
                usage.output = (u["completion_tokens"] as? Int) ?? usage.output
            }
        }
        guard completed else { throw LLMError.streamInterrupted }
        return usage
    }

    private func parseOpenAICodex(_ bytes: URLSession.AsyncBytes,
                                  onText: (String) -> Void) async throws -> TokenUsage {
        var usage = TokenUsage()
        var completed = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                // Codex normally completes with response.completed before this.
                break
            }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let eventType = json["type"] as? String
            switch eventType {
            case "response.output_text.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    onText(delta)
                }

            case "response.completed", "response.done", "response.incomplete":
                if let response = json["response"] as? [String: Any] {
                    if let error = response["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? "Codex response failed"
                        throw LLMError.http(-1, message)
                    }
                    if let u = response["usage"] as? [String: Any] {
                        usage.input = (u["input_tokens"] as? Int) ?? usage.input
                        usage.output = (u["output_tokens"] as? Int) ?? usage.output
                    }
                }
                completed = true

            case "response.failed":
                let response = json["response"] as? [String: Any]
                let error = response?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "Codex response failed"
                Self.log("Codex response.failed: \(Self.redact(message))")
                throw LLMError.http(-1, message)

            case "error":
                let message = json["message"] as? String
                    ?? (json["error"] as? [String: Any])?["message"] as? String
                    ?? "Unknown Codex stream error"
                Self.log("Codex error event: \(Self.redact(message))")
                throw LLMError.http(-1, message)

            default:
                break
            }
        }
        guard completed else { throw LLMError.streamInterrupted }
        return usage
    }

    private func parseAnthropic(_ bytes: URLSession.AsyncBytes,
                                onText: (String) -> Void) async throws -> TokenUsage {
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
                    onText(text)
                }
            case "message_delta":
                if let u = json["usage"] as? [String: Any] {
                    usage.output = (u["output_tokens"] as? Int) ?? usage.output
                }
            case "message_stop":
                return usage
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String
                    ?? "Unknown Anthropic stream error"
                throw LLMError.http(-1, message)
            default:
                break
            }
        }
        throw LLMError.streamInterrupted
    }

    private func isRetryableStreamError(_ error: Error) -> Bool {
        if let llmError = error as? LLMError,
           case .streamInterrupted = llmError { return true }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNotConnectedToInternet,
        ].contains(nsError.code)
    }

    /// Retrying while suspended only burns the retry immediately. Wait for the
    /// foreground so a broken background SSE stream can recover. Polling avoids
    /// a race where the activation notification fires between checking state
    /// and registering an observer.
    private func waitUntilApplicationIsActive() async throws {
        while await MainActor.run(body: {
            UIApplication.shared.applicationState != .active
        }) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private static func log(_ message: String) {
#if DEBUG
        let line = "[PiMobile][LLM] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
#endif
    }

    /// Avoid accidentally printing bearer/refresh tokens if a server embeds
    /// request data in an error response.
    private static func redact(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)(access_token|refresh_token|authorization|bearer|code_verifier)[\"' :=]+[^\"'\s,}]+"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )
    }
}

private extension AICredential {
    var logKind: String {
        switch self {
        case .apiKey: return "api-key"
        case .oauth: return "oauth"
        }
    }
}
