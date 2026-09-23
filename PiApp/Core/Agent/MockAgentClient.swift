import Foundation

/// Scripted local agent for demo purposes. Simulates thinking, streaming
/// markdown, tool calls (with diffs) and the permission-approval round trip.
final class MockAgentClient: AgentClient {
    private let continuation: AsyncStream<AgentEvent>.Continuation
    let events: AsyncStream<AgentEvent>

    private var runTask: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<Bool, Never>?

    init() {
        var cont: AsyncStream<AgentEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func sendPrompt(_ text: String, history: [ChatTurn], permission: PermissionMode) async {
        runTask?.cancel()
        runTask = Task { await run(script: Self.script(for: text), permission: permission) }
    }

    func answerPermission(allow: Bool) async {
        permissionContinuation?.resume(returning: allow)
        permissionContinuation = nil
    }

    func abort() async {
        runTask?.cancel()
        if let pending = permissionContinuation {
            pending.resume(returning: false)
            permissionContinuation = nil
        }
    }

    // MARK: - Script engine

    private enum Step {
        case think(String)
        case say(String)          // streamed token by token
        case tool(ToolCall, output: String, pauseMs: UInt64)
        case toolWithDiff(ToolCall, diff: String, output: String)
        case ask(ToolCall)        // permission-gated tool
        case finish
    }

    private func run(script: [Step], permission: PermissionMode) async {
        var usage = TokenUsage()
        for step in script {
            if Task.isCancelled { return }
            switch step {
            case .think(let text):
                for chunk in text.chunked(into: 12) {
                    if Task.isCancelled { return }
                    continuation.yield(.thinkingDelta(chunk))
                    try? await Task.sleep(nanoseconds: 24_000_000)
                }
            case .say(let text):
                usage.output += text.count / 4
                for chunk in text.chunked(into: 6) {
                    if Task.isCancelled { return }
                    continuation.yield(.textDelta(chunk))
                    try? await Task.sleep(nanoseconds: 18_000_000)
                }
            case .tool(var call, let output, let pauseMs):
                continuation.yield(.toolCallStarted(call))
                try? await Task.sleep(nanoseconds: pauseMs * 1_000_000)
                if Task.isCancelled { return }
                for chunk in output.chunked(into: 40) {
                    if Task.isCancelled { return }
                    continuation.yield(.toolCallOutput(id: call.id, chunk: chunk))
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                call.status = .success
                continuation.yield(.toolCallFinished(id: call.id, status: .success, diff: nil))
            case .toolWithDiff(var call, let diff, let output):
                continuation.yield(.toolCallStarted(call))
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
                if !output.isEmpty {
                    continuation.yield(.toolCallOutput(id: call.id, chunk: output))
                }
                call.status = .success
                continuation.yield(.toolCallFinished(id: call.id, status: .success, diff: diff))
            case .ask(let call):
                if permission == .bypassPermissions || permission == .acceptEdits {
                    await runStep(call)
                } else {
                    var pending = call
                    pending.status = .pendingApproval
                    continuation.yield(.toolCallStarted(pending))
                    continuation.yield(.permissionRequested(id: call.id))
                    let allowed: Bool = await withCheckedContinuation { c in
                        permissionContinuation = c
                    }
                    if Task.isCancelled { return }
                    if allowed {
                        continuation.yield(.toolCallOutput(id: call.id, chunk: Self.bashOutput))
                        continuation.yield(.toolCallFinished(id: call.id, status: .success, diff: nil))
                    } else {
                        continuation.yield(.toolCallFinished(id: call.id, status: .denied, diff: nil))
                    }
                }
            case .finish:
                usage.input += 1200
                usage.costUSD = Double(usage.total) / 1_000_000 * 3.0
                continuation.yield(.messageFinished(usage))
            }
        }
    }

    private func runStep(_ call: ToolCall) async {
        continuation.yield(.toolCallStarted(call))
        try? await Task.sleep(nanoseconds: 600_000_000)
        continuation.yield(.toolCallOutput(id: call.id, chunk: Self.bashOutput))
        continuation.yield(.toolCallFinished(id: call.id, status: .success, diff: nil))
    }

    // MARK: - Scripts

    private static let bashOutput = """
        $ npm test

        Test Suites: 4 passed, 4 total
        Tests:       37 passed, 37 total
        Snapshots:   0 total
        Time:        3.412 s
        """

    private static func script(for prompt: String) -> [Step] {
        let lower = prompt.lowercased()
        if lower.contains("test") || lower.contains("测试") {
            return testScript
        }
        if lower.contains("diff") || lower.contains("review") || lower.contains("评审") {
            return reviewScript
        }
        return defaultScript
    }

    private static let defaultScript: [Step] = [
        .think("Let me look at the project structure first to understand what we're working with, then find the relevant code path."),
        .say("我来看一下相关代码。先读一下 store 的实现：\n\n"),
        .tool(
            ToolCall(name: "Read", summary: "src/store.ts", input: "{\"path\": \"src/store.ts\"}"),
            output: """
                import { createStore } from 'zustand'

                export const useStore = createStore<AppState>((set) => ({
                  sessions: [],
                  currentView: 'home',
                  permissionMode: 'default',
                  // ...
                }))
                """,
            pauseMs: 900),
        .say("找到问题了：`sendPrompt` 里没有等待流结束就更新了状态。修一下：\n\n"),
        .toolWithDiff(
            ToolCall(name: "Edit", summary: "src/store.ts", input: "{\"path\": \"src/store.ts\"}"),
            diff: """
                @@ -42,9 +42,12 @@ export const useStore = createStore<AppState>((set) => ({
                   sendPrompt: async (text) => {
                     set({ status: 'running' })
                -    await rpc.send({ type: 'prompt', text })
                -    set({ status: 'idle' })
                +    const done = rpc.send({ type: 'prompt', text })
                +    await done.finally(() => {
                +      set({ status: 'idle' })
                +      refreshStats()
                +    })
                   },
                """,
            output: "Applied 1 edit to src/store.ts"),
        .say("改完了。现在跑一下测试确认没有回归：\n\n"),
        .ask(ToolCall(name: "Bash", summary: "npm test", input: "{\"command\": \"npm test\"}")),
        .say("\n\n全部通过 ✅。总结一下改动：\n\n- `sendPrompt` 现在会等待 RPC 流真正结束\n- 结束后自动刷新统计面板\n- 状态不会再卡在 `running`\n\n还需要我顺手把 `abort` 的竞态也处理掉吗？"),
        .finish,
    ]

    private static let testScript: [Step] = [
        .think("The user wants to run tests. I'll execute the test suite and analyze failures if any."),
        .say("好的，跑一遍完整测试套件：\n\n"),
        .ask(ToolCall(name: "Bash", summary: "npm test", input: "{\"command\": \"npm test\"}")),
        .say("\n\n**37 个测试全部通过**，4 个测试套件，耗时 3.4s。覆盖率方面 `store.ts` 的分支覆盖率偏低（68%），主要缺 `abort` 竞态的用例。要我补上吗？"),
        .finish,
    ]

    private static let reviewScript: [Step] = [
        .think("Let me check the git status and produce a diff of the current changes for review."),
        .say("当前工作区有 3 个改动文件，我生成一下 diff：\n\n"),
        .tool(
            ToolCall(name: "Bash", summary: "git diff --stat", input: "{\"command\": \"git diff --stat\"}"),
            output: " src/store.ts    |  7 +++++--\n src/chat.tsx    | 12 ++++++------\n src/themes.ts   |  2 +-\n 3 files changed, 12 insertions(+), 9 deletions(-)",
            pauseMs: 500),
        .toolWithDiff(
            ToolCall(name: "Read", summary: "git diff src/store.ts"),
            diff: """
                @@ -42,9 +42,12 @@ export const useStore = createStore<AppState>((set) => ({
                   sendPrompt: async (text) => {
                     set({ status: 'running' })
                -    await rpc.send({ type: 'prompt', text })
                -    set({ status: 'idle' })
                +    const done = rpc.send({ type: 'prompt', text })
                +    await done.finally(() => {
                +      set({ status: 'idle' })
                +      refreshStats()
                +    })
                   },
                """,
            output: ""),
        .say("\n\n改动看起来没问题：\n\n1. **状态修复** —— `idle` 现在只在流结束后设置\n2. **统计刷新** —— 移到 `finally` 里，异常路径也能覆盖\n\n可以 Commit 了。"),
        .finish,
    ]
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard !isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for ch in self {
            current.append(ch)
            if current.count >= size {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
