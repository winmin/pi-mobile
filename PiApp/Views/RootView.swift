import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var preferredColumn: NavigationSplitViewColumn = .detail

    var body: some View {
        @Bindable var model = model
        let theme = model.theme
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            sidebar(theme)
        } detail: {
            NavigationStack {
                detail
                    .background(theme.appBG)
            }
        }
        .tint(theme.accent)
        .background(theme.appBG.ignoresSafeArea())
        .background(paletteShortcutButton)
        .sheet(isPresented: $model.newSessionPresented) {
            NewSessionView(initialBackend: model.backend)
                .environment(model)
        }
        .overlay {
            if model.palettePresented {
                CommandPaletteView()
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Sidebar

    private func sidebar(_ theme: PiTheme) -> some View {
        List {
            Section {
                HStack(spacing: 10) {
                    PiGlyph(size: 26)
                    Text("Pi Mobile")
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }

            Section("Views") {
                ForEach(AppRoute.visibleCases) { route in
                    Button {
                        model.route = route
                        preferredColumn = .detail
                    } label: {
                        Label(route.rawValue, systemImage: route.icon)
                            .foregroundStyle(model.route == route ? theme.accent : theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .listRowBackground(model.route == route ? theme.accent.opacity(0.12) : Color.clear)
                }
            }

            Section("Sessions") {
                ForEach(model.sessions.filter { !$0.isArchived }) { session in
                    Button {
                        model.openSession(session)
                        preferredColumn = .detail
                    } label: {
                        sessionRow(session, theme)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .listRowBackground(session.id == model.activeSessionID && model.route == .chat
                        ? theme.accent.opacity(0.12) : Color.clear)
                }
                Button {
                    model.presentNewSession()
                    preferredColumn = .detail
                } label: {
                    Label("New Session", systemImage: "plus")
                        .foregroundStyle(theme.accent)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.appBG)
    }

    private func sessionRow(_ session: ChatSession, _ theme: PiTheme) -> some View {
        HStack(spacing: 8) {
            SessionDot(session: session, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text("\(session.model) · \(session.updatedAt.relativeShort)")
                    .font(.caption2)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch model.route {
        case .home: HomeView()
        case .chat: ChatView()
        case .sessions: SessionsView()
        case .timeline: TimelineView()
        case .files: FilesView()
        case .settings: SettingsView()
        }
    }

    private var paletteShortcutButton: some View {
        Button("") {
            withAnimation(.easeInOut(duration: 0.15)) {
                model.palettePresented.toggle()
            }
        }
        .keyboardShortcut("k", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
