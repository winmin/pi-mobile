import SwiftUI

struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantContent
        }
    }

    // MARK: - User

    private var userBubble: some View {
        let theme = model.theme
        return HStack {
            Spacer(minLength: 48)
            Text(userText)
                .font(.system(size: model.chatFontSize))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.accent.opacity(0.6), lineWidth: 0.5)
                )
        }
    }

    private var userText: String {
        message.blocks.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Assistant

    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isLast: index == message.blocks.count - 1)
            }
            if message.blocks.isEmpty && message.isStreaming {
                StreamingCursor()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock, isLast: Bool) -> some View {
        switch block {
        case .thinking(let text):
            ThinkingBlock(text: text)
        case .text(let text):
            VStack(alignment: .leading, spacing: 2) {
                MarkdownText(text: text, fontSize: model.chatFontSize)
                if message.isStreaming && isLast {
                    StreamingCursor()
                }
            }
        case .toolCall(let call):
            ToolCallCard(call: call)
        }
    }
}

// MARK: - Thinking

struct ThinkingBlock: View {
    @Environment(AppModel.self) private var model
    let text: String
    @State private var expanded = false

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Thought for a moment")
                        .font(.caption.italic())
                }
                .foregroundStyle(theme.textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: max(model.chatFontSize - 3, 10)).italic())
                    .foregroundStyle(theme.textMuted)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface2, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Tool call card

struct ToolCallCard: View {
    @Environment(AppModel.self) private var model
    let call: ToolCall
    @State private var expanded = false
    @State private var pulsing = false

    private var statusColor: Color {
        let theme = model.theme
        switch call.status {
        case .running: return theme.accent
        case .pendingApproval: return theme.warning
        case .success: return theme.success
        case .failed, .denied: return theme.error
        }
    }

    private var statusIcon: String {
        switch call.status {
        case .running: return "circle.dashed"
        case .pendingApproval: return "exclamationmark.shield.fill"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .denied: return "hand.raised.fill"
        }
    }

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                header(theme)
            }
            .buttonStyle(.plain)

            if !call.output.isEmpty {
                Text(call.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            if expanded, let diff = call.diff {
                DiffView(diff: diff)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            if call.status == .pendingApproval {
                approvalFooter(theme)
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 0.5))
        .onAppear {
            guard call.status == .running else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    private func header(_ theme: PiTheme) -> some View {
        HStack(spacing: 8) {
            Text(call.name.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .opacity(call.status == .running ? (pulsing ? 0.45 : 1) : 1)
            Text(call.summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(statusColor)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(theme.textFaint)
        }
        .padding(10)
        .contentShape(Rectangle())
    }

    private func approvalFooter(_ theme: PiTheme) -> some View {
        HStack(spacing: 10) {
            Button {
                model.approveToolCall()
            } label: {
                Label("Approve", systemImage: "checkmark")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(theme.success, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
            }
            Button {
                model.denyToolCall()
            } label: {
                Label("Deny", systemImage: "xmark")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.error, lineWidth: 1))
                    .foregroundStyle(theme.error)
            }
        }
        .buttonStyle(.plain)
        .padding(10)
    }
}

#Preview {
    MessageBubble(message: MockData.sessions[0].messages[1])
        .environment(AppModel())
        .padding()
}
