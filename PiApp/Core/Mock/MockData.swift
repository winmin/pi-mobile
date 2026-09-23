import Foundation

/// Demo content so the app is fully explorable offline.
enum MockData {
    static let sessions: [ChatSession] = [
        ChatSession(
            title: "Fix streaming status race",
            project: "pi-desktop",
            model: "claude-sonnet-4",
            messages: [
                ChatMessage(role: .user, blocks: [
                    .text("状态栏一直卡在 running，帮我看看"),
                ]),
                ChatMessage(role: .assistant, blocks: [
                    .thinking("The status stays 'running' after the stream ends. Likely sendPrompt resolves before the RPC stream completes."),
                    .text("问题在 `sendPrompt`：它没有等待流结束就重置了状态。修复如下："),
                    .toolCall(ToolCall(
                        name: "Edit", summary: "src/store.ts",
                        input: "{\"path\": \"src/store.ts\"}",
                        output: "Applied 1 edit to src/store.ts",
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
                        status: .success)),
                    .text("修好了，`idle` 现在只在流真正结束后设置。测试也全绿。"),
                ], timestamp: Date().addingTimeInterval(-3600)),
            ],
            usage: TokenUsage(input: 12_400, output: 3_100, costUSD: 0.046),
            createdAt: Date().addingTimeInterval(-86400),
            updatedAt: Date().addingTimeInterval(-3600)),
        ChatSession(
            title: "Add nord theme variant",
            project: "pi-desktop",
            model: "claude-sonnet-4",
            messages: [
                ChatMessage(role: .user, blocks: [.text("Add a Nord color theme")]),
                ChatMessage(role: .assistant, blocks: [
                    .text("已添加 Nord 主题，seed 色板：\n\n- `app`: `#2e3440`\n- `surface`: `#3b4252`\n- `accent`: `#88c0d0`\n\n派生 token 全部自动生成。"),
                ], timestamp: Date().addingTimeInterval(-7200)),
            ],
            usage: TokenUsage(input: 8_200, output: 1_900, costUSD: 0.031),
            createdAt: Date().addingTimeInterval(-172800),
            updatedAt: Date().addingTimeInterval(-7200)),
        ChatSession(
            title: "Refactor IPC contracts",
            project: "pi-agent",
            model: "gpt-5-codex",
            messages: [
                ChatMessage(role: .user, blocks: [.text("Split ipc-contracts.ts into per-domain modules")]),
                ChatMessage(role: .assistant, blocks: [
                    .text("已按域拆分为 15 个模块，shared 层只保留纯类型，没有运行时依赖。"),
                ], timestamp: Date().addingTimeInterval(-200_000)),
            ],
            usage: TokenUsage(input: 22_800, output: 6_400, costUSD: 0.089),
            createdAt: Date().addingTimeInterval(-259200),
            updatedAt: Date().addingTimeInterval(-200_000)),
    ]

    static let fileTree: [FileNode] = [
        FileNode(name: "pi-desktop", isDirectory: true, children: [
            FileNode(name: "src", isDirectory: true, children: [
                FileNode(name: "main", isDirectory: true, children: [
                    FileNode(name: "pi-rpc-manager.ts", isDirectory: false,
                             content: """
                             import { spawn } from 'node:child_process'
                             import readline from 'node:readline'

                             /** Drives a `pi --mode rpc` subprocess over JSONL stdin/stdout. */
                             export class PiRpcManager {
                               private proc = spawn('pi', ['--mode', 'rpc'])
                               private pending = new Map<number, (v: unknown) => void>()

                               send(command: object): Promise<unknown> {
                                 const id = Math.floor(Math.random() * 1e9)
                                 this.proc.stdin.write(JSON.stringify({ id, ...command }) + '\\n')
                                 return new Promise((resolve) => this.pending.set(id, resolve))
                               }
                             }
                             """,
                             isModified: true),
                    FileNode(name: "ipc-handlers.ts", isDirectory: false,
                             content: "// Registers all 141 IPC channels from src/shared/ipc-contracts.ts\n"),
                ]),
                FileNode(name: "renderer", isDirectory: true, children: [
                    FileNode(name: "store.ts", isDirectory: false,
                             content: """
                             import { createStore } from 'zustand'

                             export const useStore = createStore<AppState>((set) => ({
                               sessions: [],
                               currentView: 'home',
                               permissionMode: 'default',
                               sendPrompt: async (text) => {
                                 set({ status: 'running' })
                                 const done = rpc.send({ type: 'prompt', text })
                                 await done.finally(() => {
                                   set({ status: 'idle' })
                                   refreshStats()
                                 })
                               },
                             }))
                             """,
                             isModified: true),
                    FileNode(name: "app.tsx", isDirectory: false,
                             content: "// Shell: Sidebar + WorkspaceTabs + currentView + StatusBar\n"),
                ]),
                FileNode(name: "shared", isDirectory: true, children: [
                    FileNode(name: "ipc-contracts.ts", isDirectory: false,
                             content: "// 141 typed IPC channels across 15 domains\n"),
                    FileNode(name: "default-settings.ts", isDirectory: false,
                             content: "export const DEFAULT_SETTINGS = { theme: 'dark', fontSize: 16 }\n"),
                ]),
            ]),
            FileNode(name: "package.json", isDirectory: false,
                     content: "{\n  \"name\": \"pi-desktop\",\n  \"productName\": \"Pi Desktop\",\n  \"version\": \"0.1.8-alpha\"\n}\n"),
            FileNode(name: "README.md", isDirectory: false,
                     content: "# Pi Desktop\n\nGUI frontend for the Pi coding agent.\n"),
        ]),
    ]

    static let timeline: [TimelineEntry] = [
        TimelineEntry(kind: .toolCall, title: "Edit src/store.ts", detail: "+7 -3 lines",
                      sessionTitle: "Fix streaming status race", timestamp: Date().addingTimeInterval(-3400)),
        TimelineEntry(kind: .approval, title: "Approved: npm test", detail: "Bash command",
                      sessionTitle: "Fix streaming status race", timestamp: Date().addingTimeInterval(-3200)),
        TimelineEntry(kind: .message, title: "Status race fixed", detail: "37 tests passing",
                      sessionTitle: "Fix streaming status race", timestamp: Date().addingTimeInterval(-3600)),
        TimelineEntry(kind: .fork, title: "Forked session", detail: "from #42 · try-alternative-fix",
                      sessionTitle: "Fix streaming status race", timestamp: Date().addingTimeInterval(-5400)),
        TimelineEntry(kind: .toolCall, title: "Read src/themes.ts", detail: "128 lines",
                      sessionTitle: "Add nord theme variant", timestamp: Date().addingTimeInterval(-7300)),
        TimelineEntry(kind: .message, title: "Nord theme added", detail: "5 built-in themes total",
                      sessionTitle: "Add nord theme variant", timestamp: Date().addingTimeInterval(-7200)),
        TimelineEntry(kind: .error, title: "RPC timeout", detail: "pi --mode rpc did not respond in 30s",
                      sessionTitle: "Refactor IPC contracts", timestamp: Date().addingTimeInterval(-201_000)),
        TimelineEntry(kind: .message, title: "IPC split into 15 modules", detail: "shared layer is type-only now",
                      sessionTitle: "Refactor IPC contracts", timestamp: Date().addingTimeInterval(-200_000)),
    ]

    static let stats: ActivityStats = {
        // 18 weeks x 7 days of plausible activity
        var weeks: [[Int]] = []
        var seeded = UInt64(42)
        func nextRandom() -> Int {
            seeded = seeded &* 6364136223846793005 &+ 1442695040888963407
            return Int((seeded >> 33) % 100)
        }
        for _ in 0..<7 {
            var row: [Int] = []
            for _ in 0..<18 {
                let roll = nextRandom()
                row.append(roll < 25 ? 0 : roll < 50 ? 1 : roll < 72 ? 2 : roll < 90 ? 3 : 4)
            }
            weeks.append(row)
        }
        return ActivityStats(
            totalSessions: 3,
            totalTokens: 58_800,
            totalCostUSD: 0.83,
            currentStreakDays: 6,
            heatmapWeeks: weeks,
            perModel: [("claude-sonnet-4", 41_200), ("gpt-5-codex", 14_600), ("claude-opus-4.5", 3_000)])
    }()
}
