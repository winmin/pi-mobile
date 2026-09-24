import SwiftUI

struct ChatInputBar: View {
    @Environment(AppModel.self) private var model
    @State private var prompt = ""
    @FocusState private var inputFocused: Bool

    private var session: ChatSession? { model.activeSession }
    private var isBusy: Bool {
        session?.status == .running || session?.status == .waitingApproval
    }
    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let theme = model.theme
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                permissionMenu(theme)
                TextField("Ask Pi anything…", text: $prompt, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.system(size: model.chatFontSize))
                    .foregroundStyle(theme.textPrimary)
                    .focused($inputFocused)
                    .layoutPriority(1)
                    .onSubmit(send)
                sendOrStopButton(theme)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.border, lineWidth: 0.5))
            caption(theme)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(theme.appBG)
#if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-uiFocusInput") {
                inputFocused = true
            }
        }
#endif
    }

    // MARK: - Permission mode menu

    private func permissionMenu(_ theme: PiTheme) -> some View {
        Menu {
            ForEach(PermissionMode.allCases) { mode in
                Button {
                    model.permissionMode = mode
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.rawValue)
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: mode.icon)
                    }
                }
            }
        } label: {
            Image(systemName: model.permissionMode.icon)
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(theme.surface2, in: Circle())
        }
    }

    // MARK: - Send / Stop

    @ViewBuilder
    private func sendOrStopButton(_ theme: PiTheme) -> some View {
        if isBusy {
            Button {
                model.abort()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(theme.error, in: Circle())
            }
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? theme.accent : theme.surface3, in: Circle())
            }
            .disabled(!canSend)
        }
    }

    // MARK: - Caption

    private func caption(_ theme: PiTheme) -> some View {
        HStack(spacing: 4) {
            if let session {
                Text("\(backendAndModel(for: session)) · \(model.permissionMode.rawValue) · \(formatTokenCount(session.usage.total)) tokens · \(formatCost(session.usage.costUSD))")
            } else {
                Text("\(backendAndModel(for: nil)) · \(model.permissionMode.rawValue) · No session")
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(theme.textFaint)
        .padding(.horizontal, 6)
    }

    private func backendAndModel(for session: ChatSession?) -> String {
        switch model.backend {
        case .directAPI:
            return "Direct · \(model.providerStore.activeModelID ?? "no model")"
        case .remotePi:
            let peerID = session?.remotePiPeerID ?? model.remotePiStore.selectedPeerID
            guard let peer = model.remotePiStore.peer(id: peerID) else {
                return "Remote Pi · unavailable"
            }
            let remoteModel = model.remotePiStore.activeModelName(for: peer.id)
                ?? "detecting model…"
            return "Remote Pi · \(peer.sessionName) · \(remoteModel)"
        case .webSocket:
            return "Remote WebSocket"
        }
    }

    private func send() {
        guard canSend, !isBusy else { return }
        model.send(prompt: prompt)
        prompt = ""
    }
}

#Preview {
    ChatInputBar()
        .environment(AppModel())
}
