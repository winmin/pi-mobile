import Foundation
import Observation
import UIKit

enum AppRoute: String, CaseIterable, Identifiable {
    case home = "Home"
    case chat = "Chat"
    case sessions = "Sessions"
    case timeline = "Timeline"
    case files = "Files"
    case settings = "Settings"

    var id: String { rawValue }

    /// Routes shown in the UI. Files is implemented but hidden for now.
    static var visibleCases: [AppRoute] { allCases.filter { $0 != .files } }

    var icon: String {
        switch self {
        case .home: return "house"
        case .chat: return "bubble.left.and.bubble.right"
        case .sessions: return "clock.arrow.circlepath"
        case .timeline: return "point.topleft.down.to.point.bottomright.curvepath"
        case .files: return "folder"
        case .settings: return "gearshape"
        }
    }
}

enum BackendKind: String, CaseIterable, Identifiable {
    case directAPI = "Direct API (provider)"
    case mock = "Mock (offline demo)"
    case webSocket = "Remote (WebSocket)"

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Navigation
    var route: AppRoute = .home
    var palettePresented = false

    // MARK: Sessions
    var sessions: [ChatSession]
    var activeSessionID: UUID?
    var permissionMode: PermissionMode {
        didSet { UserDefaults.standard.set(permissionMode.rawValue, forKey: "permissionMode") }
    }

    var activeSession: ChatSession? {
        sessions.first { $0.id == activeSessionID }
    }

    // MARK: Settings (persisted)
    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "themeID") }
    }
    var chatFontSize: Double {
        didSet { UserDefaults.standard.set(chatFontSize, forKey: "chatFontSize") }
    }
    var backend: BackendKind {
        didSet {
            UserDefaults.standard.set(backend.rawValue, forKey: "backend")
            reconnect()
        }
    }
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }

    var theme: PiTheme { PiTheme.theme(withID: themeID) }

    // MARK: Agent backend
    private(set) var client: any AgentClient
    private var eventTask: Task<Void, Never>?

    // MARK: AI providers
    let providerStore = ProviderStore()

    // MARK: Demo data
    var fileTree: [FileNode]
    var timelineEntries: [TimelineEntry]
    var stats: ActivityStats

    init() {
        let defaults = UserDefaults.standard
        themeID = defaults.string(forKey: "themeID") ?? PiTheme.default.id
        chatFontSize = defaults.object(forKey: "chatFontSize") as? Double ?? 16
        serverURL = defaults.string(forKey: "serverURL") ?? "ws://localhost:7777/rpc"
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        permissionMode = PermissionMode(rawValue: defaults.string(forKey: "permissionMode") ?? "")
            ?? .default
        let initialBackend = BackendKind(rawValue: defaults.string(forKey: "backend") ?? "") ?? .directAPI
        backend = initialBackend

        // Demo content only in Mock mode; real backends start from a clean slate.
        if initialBackend == .mock {
            sessions = MockData.sessions
            timelineEntries = MockData.timeline
            stats = MockData.stats
        } else {
            sessions = []
            timelineEntries = Self.loadTimeline()
            stats = ActivityStats(totalSessions: 0, totalTokens: 0, totalCostUSD: 0,
                                  currentStreakDays: 0, heatmapWeeks: [], perModel: [])
        }
        fileTree = MockData.fileTree
        client = MockAgentClient()
        activeSessionID = sessions.first?.id
        reconnect()
        rebuildDerived()
        applyDebugLaunchArguments()
    }

    /// Screenshot/testing hooks, e.g. `-uiRoute chat` or `-uiSend "prompt"`.
    private func applyDebugLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-uiSeedProvider"), idx + 2 < args.count {
            // Point the app at a test provider, e.g. a local SSE stub:
            // -uiSeedProvider http://127.0.0.1:8899/v1 test-model
            backend = .directAPI
            let provider = AIProvider(
                id: "debug-stub", name: "Debug Stub",
                baseUrl: args[idx + 1], api: .openaiCompletions,
                models: [AIModelDef(id: args[idx + 2], name: args[idx + 2])])
            if !providerStore.providers.contains(where: { $0.id == provider.id }) {
                providerStore.addProvider(provider)
            } else {
                providerStore.updateProvider(provider)
            }
            providerStore.setCredential(.apiKey("debug-key"), for: provider.id)
            providerStore.activeProviderID = provider.id
            providerStore.activeModelID = args[idx + 2]
        }
        if let idx = args.firstIndex(of: "-uiRoute"), idx + 1 < args.count,
           let target = AppRoute.allCases.first(where: {
               $0.rawValue.lowercased() == args[idx + 1].lowercased()
           }) {
            route = target
        }
        if let idx = args.firstIndex(of: "-uiSend"), idx + 1 < args.count {
            let prompt = args[idx + 1]
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self.route = .chat
                self.send(prompt: prompt)
            }
        }
    }

    // MARK: - Backend wiring

    func reconnect() {
        eventTask?.cancel()
        switch backend {
        case .directAPI:
            client = LLMChatClient(providerStore: providerStore)
        case .mock:
            client = MockAgentClient()
        case .webSocket:
            if let url = URL(string: serverURL) {
                client = WebSocketAgentClient(url: url)
            } else {
                client = MockAgentClient()
            }
        }
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: - Session actions

    func newSession() {
        let session = ChatSession(
            title: "New session",
            project: "pi-ios",
            model: providerStore.activeModelID ?? "claude-sonnet-4")
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        route = .chat
        record(.message, "Session started", detail: session.model, session: session.title)
    }

    func openSession(_ session: ChatSession) {
        activeSessionID = session.id
        route = .chat
    }

    func deleteSession(_ session: ChatSession) {
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }

    func toggleArchive(_ session: ChatSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].isArchived.toggle()
    }

    func renameSession(_ session: ChatSession, to title: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }), !title.isEmpty else { return }
        sessions[idx].title = title
    }

    // MARK: - Chat actions

    func send(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if activeSession == nil { newSession() }
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }

        sessions[idx].messages.append(ChatMessage(role: .user, blocks: [.text(text)]))
        sessions[idx].messages.append(ChatMessage(role: .assistant, blocks: [], isStreaming: true))
        sessions[idx].status = .running
        sessions[idx].updatedAt = Date()
        if sessions[idx].title == "New session" {
            sessions[idx].title = String(text.prefix(40))
        }
        record(.message, "Prompt sent", detail: String(text.prefix(80)), session: sessions[idx].title)

        // Conversation history: text of user/assistant messages, skipping the
        // trailing empty streaming placeholder just appended.
        let history: [ChatTurn] = sessions[idx].messages.dropLast().compactMap { message in
            let text = message.blocks.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            return ChatTurn(role: message.role == .user ? .user : .assistant, text: text)
        }

        if backend == .directAPI {
            let configured = providerStore.activeProvider
                .map { providerStore.isAuthenticated(provider: $0) } ?? false
            if !configured {
                let last = sessions[idx].messages.count - 1
                sessions[idx].messages[last].blocks.append(.text(
                    "⚠️ No AI provider configured yet. Open **Settings → AI Providers** to add an API key or sign in, then try again."))
                sessions[idx].messages[last].isStreaming = false
                sessions[idx].status = .idle
                return
            }
        }

        let client = self.client
        let permission = permissionMode
        Task { await client.sendPrompt(text, history: history, permission: permission) }
    }

    func approveToolCall() {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[idx].status = .running
        setPendingToolCallStatus(in: idx, .running)
        record(.approval, "Tool call approved", session: sessions[idx].title)
        let client = self.client
        Task { await client.answerPermission(allow: true) }
    }

    func denyToolCall() {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[idx].status = .running
        record(.approval, "Tool call denied", session: sessions[idx].title)
        let client = self.client
        Task { await client.answerPermission(allow: false) }
    }

    func abort() {
        let client = self.client
        Task { await client.abort() }
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[idx].status = .idle
        if let last = sessions[idx].messages.indices.last, sessions[idx].messages[last].isStreaming {
            sessions[idx].messages[last].isStreaming = false
        }
    }

    // MARK: - Event handling

    private func handle(_ event: AgentEvent) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        guard let mIdx = sessions[sIdx].messages.lastIndex(where: { $0.role == .assistant }) else { return }

        switch event {
        case .thinkingDelta(let chunk):
            appendToBlock(in: sIdx, message: mIdx, kind: .thinking, chunk: chunk)
        case .textDelta(let chunk):
            appendToBlock(in: sIdx, message: mIdx, kind: .text, chunk: chunk)
        case .toolCallStarted(let call):
            sessions[sIdx].messages[mIdx].blocks.append(.toolCall(call))
        case .toolCallOutput(let id, let chunk):
            updateToolCall(in: sIdx, message: mIdx, id: id) { $0.output += chunk }
        case .toolCallFinished(let id, let status, let diff):
            updateToolCall(in: sIdx, message: mIdx, id: id) {
                $0.status = status
                if let diff { $0.diff = diff }
            }
            if let call = findToolCall(in: sIdx, id: id) {
                let verb = status == .success ? "succeeded" : status == .failed ? "failed" : "denied"
                record(.toolCall, "\(call.name) \(verb)", detail: call.summary,
                       session: sessions[sIdx].title)
            }
        case .permissionRequested(let id):
            updateToolCall(in: sIdx, message: mIdx, id: id) { $0.status = .pendingApproval }
            sessions[sIdx].status = .waitingApproval
            if hapticsEnabled {
                // Light haptic nudge for approval requests.
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
            }
        case .messageFinished(let usage):
            sessions[sIdx].messages[mIdx].isStreaming = false
            sessions[sIdx].status = .idle
            sessions[sIdx].usage.input += usage.input
            sessions[sIdx].usage.output += usage.output
            sessions[sIdx].usage.costUSD += usage.costUSD
            sessions[sIdx].updatedAt = Date()
            record(.message, "Response completed",
                   detail: "\(formatTokenCount(usage.total)) tokens",
                   session: sessions[sIdx].title)
            rebuildDerived()
        case .failed(let message):
            sessions[sIdx].messages[mIdx].isStreaming = false
            sessions[sIdx].messages[mIdx].blocks.append(.text("⚠️ \(message)"))
            sessions[sIdx].status = .idle
            record(.error, "Chat error", detail: message, session: sessions[sIdx].title)
        }
    }

    private enum BlockKind { case text, thinking }

    private func appendToBlock(in sIdx: Int, message mIdx: Int, kind: BlockKind, chunk: String) {
        var blocks = sessions[sIdx].messages[mIdx].blocks
        switch (kind, blocks.last) {
        case (.text, .some(.text(let existing))):
            blocks[blocks.count - 1] = .text(existing + chunk)
        case (.thinking, .some(.thinking(let existing))):
            blocks[blocks.count - 1] = .thinking(existing + chunk)
        case (.text, _):
            blocks.append(.text(chunk))
        case (.thinking, _):
            blocks.append(.thinking(chunk))
        }
        sessions[sIdx].messages[mIdx].blocks = blocks
    }

    private func updateToolCall(in sIdx: Int, message mIdx: Int, id: UUID,
                                mutate: (inout ToolCall) -> Void) {
        var blocks = sessions[sIdx].messages[mIdx].blocks
        for i in blocks.indices {
            if case .toolCall(var call) = blocks[i], call.id == id {
                mutate(&call)
                blocks[i] = .toolCall(call)
                sessions[sIdx].messages[mIdx].blocks = blocks
                return
            }
        }
    }

    private func setPendingToolCallStatus(in sIdx: Int, _ status: ToolStatus) {
        for mIdx in sessions[sIdx].messages.indices {
            var blocks = sessions[sIdx].messages[mIdx].blocks
            for i in blocks.indices {
                if case .toolCall(var call) = blocks[i], call.status == .pendingApproval {
                    call.status = status
                    blocks[i] = .toolCall(call)
                    sessions[sIdx].messages[mIdx].blocks = blocks
                }
            }
        }
    }

    private func findToolCall(in sIdx: Int, id: UUID) -> ToolCall? {
        for message in sessions[sIdx].messages {
            for block in message.blocks {
                if case .toolCall(let call) = block, call.id == id { return call }
            }
        }
        return nil
    }

    // MARK: - Timeline recording

    func record(_ kind: TimelineKind, _ title: String, detail: String = "", session: String = "") {
        timelineEntries.insert(TimelineEntry(kind: kind, title: title, detail: detail,
                                             sessionTitle: session, timestamp: Date()), at: 0)
        if timelineEntries.count > 200 {
            timelineEntries = Array(timelineEntries.prefix(200))
        }
        if let data = try? JSONEncoder().encode(timelineEntries) {
            UserDefaults.standard.set(data, forKey: "timelineEntries")
        }
    }

    private static func loadTimeline() -> [TimelineEntry] {
        guard let data = UserDefaults.standard.data(forKey: "timelineEntries"),
              let entries = try? JSONDecoder().decode([TimelineEntry].self, from: data) else { return [] }
        return entries
    }

    // MARK: - Stats

    private func rebuildDerived() {
        stats.totalSessions = sessions.count
        stats.totalTokens = sessions.reduce(0) { $0 + $1.usage.total }
        stats.totalCostUSD = sessions.reduce(0) { $0 + $1.usage.costUSD }
        // In Mock mode keep the demo heatmap/streak; otherwise compute from real sessions.
        guard backend != .mock else { return }

        var byModel: [String: Int] = [:]
        for session in sessions {
            byModel[session.model, default: 0] += session.usage.total
        }
        stats.perModel = byModel
            .map { (model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }

        let calendar = Calendar.current
        var perDay: [Date: Int] = [:]
        for session in sessions {
            perDay[calendar.startOfDay(for: session.updatedAt), default: 0] += 1
        }

        // 7 rows (Mon..Sun) x 18 weeks, newest cell = today.
        let today = calendar.startOfDay(for: Date())
        let todayWeekday = (calendar.component(.weekday, from: today) + 5) % 7
        var grid = Array(repeating: Array(repeating: 0, count: 18), count: 7)
        for day in 0..<7 {
            for week in 0..<18 {
                let daysBack = (17 - week) * 7 + (todayWeekday - day)
                guard daysBack >= 0,
                      let date = calendar.date(byAdding: .day, value: -daysBack, to: today) else { continue }
                let count = perDay[date] ?? 0
                grid[day][week] = count == 0 ? 0 : count == 1 ? 1 : count <= 3 ? 2 : count <= 6 ? 3 : 4
            }
        }
        stats.heatmapWeeks = grid

        var streak = 0
        var cursor = today
        if (perDay[cursor] ?? 0) == 0,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        while (perDay[cursor] ?? 0) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        stats.currentStreakDays = streak
    }
}
