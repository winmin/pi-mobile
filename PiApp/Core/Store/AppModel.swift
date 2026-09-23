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

enum BackendKind: String, CaseIterable, Codable, Identifiable {
    case directAPI = "Direct API (provider)"
    case webSocket = "Remote (WebSocket)"
    case remotePi = "Remote Pi (plugin)"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .directAPI: return "Direct API"
        case .webSocket: return "Remote WebSocket"
        case .remotePi: return "Remote Pi"
        }
    }

    var icon: String {
        switch self {
        case .directAPI: return "network"
        case .webSocket: return "cable.connector"
        case .remotePi: return "desktopcomputer.and.arrow.down"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Navigation
    var route: AppRoute = .home
    var palettePresented = false
    var newSessionPresented = false

    // MARK: Sessions
    var sessions: [ChatSession]
    var activeSessionID: UUID? {
        didSet { UserDefaults.standard.set(activeSessionID?.uuidString, forKey: "activeSessionID") }
    }
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
            if let activeSessionID,
               let index = sessions.firstIndex(where: { $0.id == activeSessionID }) {
                sessions[index].backend = backend
                persistSessions()
            }
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
    private var responseBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: AI providers
    let providerStore = ProviderStore()

    // MARK: Remote Pi plugin
    let remotePiStore = RemotePiStore()

    // MARK: Demo data
    var fileTree: [FileNode]
    var timelineEntries: [TimelineEntry]
    var stats: ActivityStats

    // MARK: - Persistence

    private static var sessionsFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PiApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    private static func loadSessions() -> [ChatSession] {
        guard let data = try? Data(contentsOf: sessionsFileURL),
              let sessions = try? JSONDecoder().decode([ChatSession].self, from: data) else { return [] }
        return sessions
    }

    private func persistSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: Self.sessionsFileURL, options: .atomic)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        themeID = defaults.string(forKey: "themeID") ?? PiTheme.default.id
        chatFontSize = defaults.object(forKey: "chatFontSize") as? Double ?? 16
        serverURL = defaults.string(forKey: "serverURL") ?? "ws://localhost:7777/rpc"
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        permissionMode = PermissionMode(rawValue: defaults.string(forKey: "permissionMode") ?? "")
            ?? .default
        let savedBackend = BackendKind(rawValue: defaults.string(forKey: "backend") ?? "") ?? .directAPI
        let savedProviderID = defaults.string(forKey: "activeProviderID")
        let directProviderReady = savedProviderID.map {
            KeychainHelper.get($0) != nil || defaults.data(forKey: "credential.\($0)") != nil
        } ?? false
        let savedRemotePiPairing = KeychainHelper.get("remote-pi.peer") != nil
        // If Direct was left selected without a credential (for example after
        // a diagnostic launch), do not strand an already-paired Remote Pi user
        // in the "provider not configured" path.
        let initialBackend: BackendKind = savedBackend == .directAPI
            && !directProviderReady
            && savedRemotePiPairing
            ? .remotePi
            : savedBackend
        backend = initialBackend
        if initialBackend != savedBackend {
            defaults.set(initialBackend.rawValue, forKey: "backend")
        }

        sessions = Self.loadSessions()
        timelineEntries = Self.loadTimeline()
        stats = ActivityStats(totalSessions: 0, totalTokens: 0, totalCostUSD: 0,
                              currentStreakDays: 0, heatmapWeeks: [], perModel: [])
        fileTree = MockData.fileTree
        client = MockAgentClient()
        activeSessionID = sessions.first?.id
        rebuildDerived()
        if let savedID = defaults.string(forKey: "activeSessionID"),
           sessions.contains(where: { $0.id.uuidString == savedID }) {
            activeSessionID = UUID(uuidString: savedID)
        }
        reconnect()
#if DEBUG
        let providerID = providerStore.activeProviderID ?? "none"
        let providerReady = providerStore.activeProvider
            .map { providerStore.isAuthenticated(provider: $0) } ?? false
        let openAIKind: String
        switch providerStore.credential(for: "openai") {
        case .oauth?: openAIKind = "oauth"
        case .apiKey?: openAIKind = "api-key"
        case nil: openAIKind = "none"
        }
        let startupLine = "[PiMobile][App] backend=\(backend.shortName) provider=\(providerID) "
            + "providerConfigured=\(providerReady) openAI=\(openAIKind) "
            + "remotePiPaired=\(remotePiStore.isPaired)\n"
        FileHandle.standardError.write(Data(startupLine.utf8))
#endif
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
        var remoteClientToPrepare: RemotePiAgentClient?
        switch backend {
        case .directAPI:
            client = LLMChatClient(providerStore: providerStore)
        case .webSocket:
            if let url = URL(string: serverURL) {
                client = WebSocketAgentClient(url: url)
            } else {
                client = MockAgentClient()
            }
        case .remotePi:
            let remoteClient = RemotePiAgentClient(store: remotePiStore)
            client = remoteClient
            remoteClientToPrepare = remoteClient
        }
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        if remotePiStore.isPaired, let remoteClientToPrepare {
            Task { await remoteClientToPrepare.prepare() }
        }
    }

    // MARK: - Session actions

    func presentNewSession() {
        newSessionPresented = true
    }

    func createSession(backend selectedBackend: BackendKind) {
        let sessionModel: String
        switch selectedBackend {
        case .directAPI:
            sessionModel = providerStore.activeModelID ?? "no model"
        case .remotePi:
            sessionModel = remotePiStore.activeModelName ?? "Remote Pi"
        case .webSocket:
            sessionModel = "Remote WebSocket"
        }
        let session = ChatSession(
            title: "New session",
            project: "pi-ios",
            model: sessionModel,
            backend: selectedBackend)
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        backend = selectedBackend
        newSessionPresented = false
        route = .chat
        record(.message, "Session started", detail: session.model, session: session.title)
        persistSessions()
    }

    func openSession(_ session: ChatSession) {
        activeSessionID = session.id
        backend = session.backend ?? .directAPI
        route = .chat
    }

    func deleteSession(_ session: ChatSession) {
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
        persistSessions()
    }

    func toggleArchive(_ session: ChatSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx].isArchived.toggle()
        persistSessions()
    }

    func renameSession(_ session: ChatSession, to title: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }), !title.isEmpty else { return }
        sessions[idx].title = title
        persistSessions()
    }

    // MARK: - Chat actions

    func send(prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if activeSession == nil { createSession(backend: backend) }
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }

        sessions[idx].messages.append(ChatMessage(role: .user, blocks: [.text(text)]))
        sessions[idx].messages.append(ChatMessage(role: .assistant, blocks: [], isStreaming: true))
        sessions[idx].status = .running
        sessions[idx].updatedAt = Date()
        if sessions[idx].title == "New session" {
            sessions[idx].title = String(text.prefix(40))
        }
        record(.message, "Prompt sent", detail: String(text.prefix(80)), session: sessions[idx].title)
        persistSessions()

        // Conversation history excludes both the current user prompt and the
        // trailing empty streaming placeholder. LLMChatClient appends the
        // current prompt when it builds the provider request.
        let history: [ChatTurn] = sessions[idx].messages.dropLast(2).compactMap { message in
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
        if backend == .remotePi, !remotePiStore.isPaired {
            let last = sessions[idx].messages.count - 1
            sessions[idx].messages[last].blocks.append(.text(
                "⚠️ Remote Pi is not paired. Open **Settings → Remote Pi Plugin** and scan the QR from `/remote-pi pair`."))
            sessions[idx].messages[last].isStreaming = false
            sessions[idx].status = .idle
            persistSessions()
            return
        }

        let client = self.client
        let permission = permissionMode
        beginResponseBackgroundTask()
        Task { await client.sendPrompt(text, history: history, permission: permission) }
    }

    func approveToolCall() {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[idx].status = .running
        setPendingToolCallStatus(in: idx, .running)
        record(.approval, "Tool call approved", session: sessions[idx].title)
        persistSessions()
        let client = self.client
        Task { await client.answerPermission(allow: true) }
    }

    func denyToolCall() {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[idx].status = .running
        record(.approval, "Tool call denied", session: sessions[idx].title)
        persistSessions()
        let client = self.client
        Task { await client.answerPermission(allow: false) }
    }

    func abort() {
        let client = self.client
        Task { await client.abort() }
        endResponseBackgroundTask()
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[idx].status = .idle
        if let last = sessions[idx].messages.indices.last, sessions[idx].messages[last].isStreaming {
            sessions[idx].messages[last].isStreaming = false
        }
        persistSessions()
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
            persistSessions()
        case .permissionRequested(let id):
            updateToolCall(in: sIdx, message: mIdx, id: id) { $0.status = .pendingApproval }
            sessions[sIdx].status = .waitingApproval
            persistSessions()
            if hapticsEnabled {
                // Light haptic nudge for approval requests.
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
            }
        case .messageFinished(let usage):
            endResponseBackgroundTask()
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
            persistSessions()
        case .failed(let message):
            endResponseBackgroundTask()
            sessions[sIdx].messages[mIdx].isStreaming = false
            sessions[sIdx].messages[mIdx].blocks.append(.text("⚠️ \(message)"))
            sessions[sIdx].status = .idle
            record(.error, "Chat error", detail: message, session: sessions[sIdx].title)
            persistSessions()
        }
    }

    // MARK: - Background execution

    /// Gives an in-flight SSE response a short grace period when the user
    /// switches apps. iOS still controls the deadline; longer work is recovered
    /// by LLMChatClient when the app becomes active again.
    private func beginResponseBackgroundTask() {
        endResponseBackgroundTask()
        responseBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Finish AI response"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.endResponseBackgroundTask()
            }
        }
    }

    private func endResponseBackgroundTask() {
        guard responseBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(responseBackgroundTask)
        responseBackgroundTask = .invalid
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
