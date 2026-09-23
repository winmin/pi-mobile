import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private struct PaletteCommand: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        var hint: String?
        let run: @MainActor (AppModel) -> Void
    }

    private var commands: [PaletteCommand] {
        var result = AppRoute.visibleCases.map { route in
            PaletteCommand(icon: route.icon, title: "Go to \(route.rawValue)", hint: "View") { model in
                model.route = route
            }
        }
        result.append(PaletteCommand(icon: "plus.bubble", title: "New Session") { model in
            model.presentNewSession()
        })
        if model.activeSession?.status == .running {
            result.append(PaletteCommand(icon: "stop.circle", title: "Abort Current Run") { model in
                model.abort()
            })
        }
        result.append(PaletteCommand(icon: "paintpalette", title: "Cycle Theme", hint: model.theme.name) { model in
            let all = PiTheme.builtIns
            let index = all.firstIndex { $0.id == model.themeID } ?? 0
            model.themeID = all[(index + 1) % all.count].id
        })
        result.append(PaletteCommand(icon: "gearshape", title: "Open Settings") { model in
            model.route = .settings
        })
        return result
    }

    private var filtered: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        let theme = model.theme
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textMuted)
                    TextField("Type a command…", text: $query)
                        .focused($searchFocused)
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { execute(filtered.first) }
                }
                .padding(12)

                Rectangle().fill(theme.border).frame(height: 0.5)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { command in
                            Button {
                                execute(command)
                            } label: {
                                commandRow(command, theme)
                            }
                        }
                        if filtered.isEmpty {
                            Text("No matching commands")
                                .font(.callout)
                                .foregroundStyle(theme.textMuted)
                                .padding(20)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .frame(maxWidth: 420)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(theme.borderStrong, lineWidth: 0.5)
            )
            .padding(.horizontal, 24)
        }
        .background(escapeButton)
        .onAppear { searchFocused = true }
    }

    private func commandRow(_ command: PaletteCommand, _ theme: PiTheme) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .font(.callout)
                .foregroundStyle(theme.accent)
                .frame(width: 24)
            Text(command.title)
                .font(.callout)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if let hint = command.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(theme.textFaint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var escapeButton: some View {
        Button("") { dismiss() }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .allowsHitTesting(false)
    }

    private func execute(_ command: PaletteCommand?) {
        guard let command else { return }
        command.run(model)
        dismiss()
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.15)) {
            model.palettePresented = false
        }
    }
}

#Preview {
    CommandPaletteView()
        .environment(AppModel())
}
