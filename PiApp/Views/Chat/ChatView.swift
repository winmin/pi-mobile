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
        VStack(spacing: 0) {
            if let session = model.activeSession, !session.messages.isEmpty {
                messageList(session)
            } else {
                emptyState(theme)
            }
            Rectangle().fill(theme.border).frame(height: 0.5)
            ChatInputBar()
        }
        .background(theme.appBG)
        .navigationTitle(model.activeSession?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
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
        VStack(spacing: 20) {
            Spacer()
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
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

#Preview {
    ChatView()
        .environment(AppModel())
}
