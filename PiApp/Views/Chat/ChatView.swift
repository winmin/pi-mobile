import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model

    private let suggestions = [
        "Fix a bug in my project",
        "Explain how this codebase works",
        "Add a new feature",
        "Write tests for the store layer",
    ]

    var body: some View {
        let theme = model.theme
        Group {
            if let session = model.activeSession, !session.messages.isEmpty {
                messageList(session)
            } else {
                emptyState(theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.appBG)
        // Keeping the composer in a safe-area inset makes SwiftUI move the
        // whole bar above the keyboard on its very first presentation. A
        // bottom item in the main VStack can be compressed/clipped while the
        // keyboard safe area is animating, especially for a brand-new chat.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.activeSession?.status == .waitingApproval {
                    approvalBanner(theme)
                }
                Rectangle().fill(theme.border).frame(height: 0.5)
                ChatInputBar()
            }
            .background(theme.appBG)
        }
        .navigationTitle(model.activeSession?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Fallback approval UI — shown whenever the session waits for a decision,
    /// even if the pending tool card can't be located in the message list.
    private func approvalBanner(_ theme: PiTheme) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(theme.warning)
            Text("Pi is waiting for approval")
                .font(.callout)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button("Approve") { model.approveToolCall() }
                .buttonStyle(.borderedProminent)
                .tint(theme.success)
                .controlSize(.small)
            Button("Deny") { model.denyToolCall() }
                .buttonStyle(.bordered)
                .tint(theme.error)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.surface)
    }

    // MARK: - Messages

    private func messageList(_ session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.messages) { message in
                        MessageBubble(message: message)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onAppear {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .onChange(of: scrollToken(for: session)) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
        }
    }

    private func scrollToken(for session: ChatSession) -> Int {
        guard let last = session.messages.last else { return 0 }
        var token = session.messages.count ^ last.blocks.count
        if case .text(let text) = last.blocks.last {
            token ^= text.count
        }
        return token
    }

    // MARK: - Empty state

    private func emptyState(_ theme: PiTheme) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 24)
                PiGlyph(size: 52)
                Text("What should Pi work on?")
                    .font(.title2.bold())
                    .foregroundStyle(theme.textPrimary)
                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            model.send(prompt: suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.callout)
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(theme.surface2, in: Capsule())
                                .overlay(Capsule().stroke(theme.border, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center)
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

#Preview {
    ChatView()
        .environment(AppModel())
}
