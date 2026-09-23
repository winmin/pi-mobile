import Foundation

/// Events pushed from an agent backend to the UI.
/// Mirrors the JSONL event stream pi-desktop consumes from `pi --mode rpc`.
enum AgentEvent {
    case thinkingDelta(String)
    case textDelta(String)
    case toolCallStarted(ToolCall)
    case toolCallOutput(id: UUID, chunk: String)
    case toolCallFinished(id: UUID, status: ToolStatus, diff: String?)
    case permissionRequested(id: UUID)
    case messageFinished(TokenUsage)
    case failed(String)
}

/// One prior turn of conversation, sent along with each prompt.
struct ChatTurn: Equatable {
    enum Role: String, Equatable {
        case user, assistant
    }
    var role: Role
    var text: String
}

/// Transport-agnostic agent backend.
/// `MockAgentClient` drives a scripted local demo; `WebSocketAgentClient`
/// talks JSONL to a remote host running `pi --mode rpc`; `LLMChatClient`
/// streams chat directly from a configured LLM provider.
protocol AgentClient: AnyObject {
    var events: AsyncStream<AgentEvent> { get }
    func sendPrompt(_ text: String, history: [ChatTurn], permission: PermissionMode) async
    func answerPermission(allow: Bool) async
    func abort() async
}
