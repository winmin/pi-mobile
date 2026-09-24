import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var renameTarget: ChatSession?
    @State private var renameText = ""

    private var activeSessions: [ChatSession] {
        model.sessions.filter { !$0.isArchived }
    }

    private var archivedSessions: [ChatSession] {
        model.sessions.filter { $0.isArchived }
    }

    private var projects: [String] {
        Array(Set(activeSessions.map(\.project))).sorted()
    }

    var body: some View {
        let theme = model.theme
        List {
            ForEach(projects, id: \.self) { project in
                Section(project) {
                    ForEach(activeSessions.filter { $0.project == project }) { session in
                        sessionRow(session, theme)
                    }
                }
                .listRowBackground(theme.surface)
            }
            if !archivedSessions.isEmpty {
                Section("Archived") {
                    ForEach(archivedSessions) { session in
                        sessionRow(session, theme)
                    }
                }
                .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.appBG)
        .navigationTitle("Sessions")
        .alert("Rename Session", isPresented: renamePresented) {
            TextField("Session title", text: $renameText)
            Button("Save") {
                if let target = renameTarget {
                    model.renameSession(target, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private func sessionRow(_ session: ChatSession, _ theme: PiTheme) -> some View {
        Button {
            model.openSession(session)
        } label: {
            HStack(spacing: 8) {
                SessionDot(session: session, theme: theme)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.callout)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text("\(sessionEndpoint(session)) · \(session.updatedAt.relativeShort) · \(formatTokenCount(session.usage.total)) tokens · \(formatCost(session.usage.costUSD))")
                        .font(.caption2)
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if session.id == model.activeSessionID {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.deleteSession(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                model.toggleArchive(session)
            } label: {
                Label(session.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            .tint(.orange)
        }
        .contextMenu {
            if !model.remotePiStore.peers.isEmpty {
                Menu {
                    ForEach(model.remotePiStore.peers) { peer in
                        Button {
                            model.assignRemotePiPeer(peer.id, to: session.id)
                        } label: {
                            Label(
                                "\(peer.sessionName) · \(peer.roomID)",
                                systemImage: session.backend == .remotePi
                                    && session.remotePiPeerID == peer.id
                                    ? "checkmark.circle.fill"
                                    : "desktopcomputer"
                            )
                        }
                    }
                } label: {
                    Label("Run with Remote Pi", systemImage: "desktopcomputer.and.arrow.down")
                }
            }
            Button {
                renameText = session.title
                renameTarget = session
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                model.toggleArchive(session)
            } label: {
                Label(session.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) {
                model.deleteSession(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func sessionEndpoint(_ session: ChatSession) -> String {
        guard session.backend == .remotePi else { return session.model }
        guard let peer = model.remotePiStore.peer(id: session.remotePiPeerID) else {
            return "Remote Pi unavailable"
        }
        if let remoteModel = model.remotePiStore.activeModelName(for: peer.id) {
            return "\(peer.sessionName) · \(remoteModel)"
        }
        return peer.sessionName
    }
}

#Preview {
    SessionsView()
        .environment(AppModel())
}
