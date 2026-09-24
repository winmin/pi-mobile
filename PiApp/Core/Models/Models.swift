import Foundation

// MARK: - Permission modes (mirrors pi-desktop)

enum PermissionMode: String, CaseIterable, Codable, Identifiable {
    case `default` = "Default"
    case acceptEdits = "Accept Edits"
    case plan = "Plan"
    case bypassPermissions = "Bypass"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .default: return "Ask before edits & commands"
        case .acceptEdits: return "Auto-accept file edits"
        case .plan: return "Plan only, no changes"
        case .bypassPermissions: return "Run everything"
        }
    }

    var icon: String {
        switch self {
        case .default: return "hand.raised"
        case .acceptEdits: return "checkmark.circle"
        case .plan: return "map"
        case .bypassPermissions: return "bolt"
        }
    }
}

// MARK: - Chat content

enum ToolStatus: String, Codable {
    case running
    case pendingApproval
    case success
    case failed
    case denied
}

struct ToolCall: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String            // e.g. "Read", "Edit", "Bash", "Glob"
    var summary: String         // e.g. "src/store.ts"
    var input: String
    var output: String
    var diff: String?           // unified diff for Edit/Write
    var status: ToolStatus

    init(id: UUID = UUID(), name: String, summary: String, input: String = "",
         output: String = "", diff: String? = nil, status: ToolStatus = .running) {
        self.id = id
        self.name = name
        self.summary = summary
        self.input = input
        self.output = output
        self.diff = diff
        self.status = status
    }
}

enum ContentBlock: Identifiable, Equatable {
    case text(String)
    case thinking(String)
    case toolCall(ToolCall)

    var id: UUID {
        switch self {
        case .toolCall(let call): return call.id
        case .text, .thinking: return UUID() // value blocks are not stable-identified
        }
    }
}

extension ContentBlock: Codable {
    private enum Kind: String, Codable { case text, thinking, toolCall }
    private enum CodingKeys: String, CodingKey { case kind, text, toolCall }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .thinking:
            self = .thinking(try container.decode(String.self, forKey: .text))
        case .toolCall:
            self = .toolCall(try container.decode(ToolCall.self, forKey: .toolCall))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .thinking(let text):
            try container.encode(Kind.thinking, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .toolCall(let call):
            try container.encode(Kind.toolCall, forKey: .kind)
            try container.encode(call, forKey: .toolCall)
        }
    }
}

enum MessageRole: String, Codable { case user, assistant }

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var role: MessageRole
    var blocks: [ContentBlock]
    var timestamp: Date
    var isStreaming: Bool

    init(id: UUID = UUID(), role: MessageRole, blocks: [ContentBlock],
         timestamp: Date = Date(), isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }
}

// MARK: - Session

enum SessionStatus: String, Codable {
    case idle
    case running
    case waitingApproval
}

struct TokenUsage: Equatable, Codable {
    var input: Int = 0
    var output: Int = 0
    var costUSD: Double = 0

    var total: Int { input + output }
}

struct ChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var project: String
    var model: String
    /// Nil only for sessions saved before per-session backend selection was added.
    var backend: BackendKind?
    /// Stable RemotePiPeer.id selected for this session. It is retained if the
    /// backend changes so switching back to Remote Pi restores the same peer.
    var remotePiPeerID: String?
    var messages: [ChatMessage]
    var status: SessionStatus
    var usage: TokenUsage
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    init(id: UUID = UUID(), title: String, project: String, model: String,
         backend: BackendKind? = nil,
         remotePiPeerID: String? = nil,
         messages: [ChatMessage] = [], status: SessionStatus = .idle,
         usage: TokenUsage = TokenUsage(), createdAt: Date = Date(),
         updatedAt: Date = Date(), isArchived: Bool = false) {
        self.id = id
        self.title = title
        self.project = project
        self.model = model
        self.backend = backend
        self.remotePiPeerID = remotePiPeerID
        self.messages = messages
        self.status = status
        self.usage = usage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}

// MARK: - Timeline

enum TimelineKind: String, Codable {
    case message, toolCall, fork, approval, error
}

struct TimelineEntry: Identifiable, Codable {
    var id = UUID()
    var kind: TimelineKind
    var title: String
    var detail: String
    var sessionTitle: String
    var timestamp: Date
}

// MARK: - Files

struct FileNode: Identifiable, Equatable, Hashable {
    let id = UUID()
    var name: String
    var isDirectory: Bool
    var children: [FileNode]?
    var content: String?      // file body for preview
    var isModified: Bool      // git dirty marker

    init(name: String, isDirectory: Bool, children: [FileNode]? = nil,
         content: String? = nil, isModified: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.content = content
        self.isModified = isModified
    }
}

// MARK: - Activity stats (home dashboard)

struct ActivityStats {
    var totalSessions: Int
    var totalTokens: Int
    var totalCostUSD: Double
    var currentStreakDays: Int
    var heatmapWeeks: [[Int]]   // 7 rows (days) x N weeks, intensity 0...4
    var perModel: [(model: String, tokens: Int)]
}
