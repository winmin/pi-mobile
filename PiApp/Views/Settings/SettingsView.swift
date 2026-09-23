import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var store = model.providerStore
        let theme = model.theme
        Form {
            Section("AI Providers") {
                Picker("Provider", selection: Binding<String?>(
                    get: { store.activeProviderID },
                    set: { if let id = $0 { store.setActiveProvider(id) } }
                )) {
                    ForEach(store.providers) { provider in
                        Text(provider.name).tag(provider.id as String?)
                    }
                }
                if let provider = store.activeProvider {
                    if provider.models.isEmpty {
                        TextField("Model ID", text: Binding(
                            get: { store.activeModelID ?? "" },
                            set: { store.activeModelID = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    } else {
                        Picker("Model", selection: $store.activeModelID) {
                            ForEach(provider.models) { modelDef in
                                Text(modelDef.name).tag(modelDef.id as String?)
                            }
                        }
                    }
                }
                NavigationLink("Manage Providers") {
                    ProvidersSettingsView()
                }
            }
            .listRowBackground(theme.surface)

            Section("Appearance") {
                ForEach(PiTheme.builtIns) { option in
                    Button {
                        model.themeID = option.id
                    } label: {
                        HStack(spacing: 10) {
                            HStack(spacing: -4) {
                                ForEach([option.seed.app, option.seed.surface, option.seed.accent, option.seed.success], id: \.self) { hex in
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 14, height: 14)
                                        .overlay(Circle().stroke(theme.border, lineWidth: 0.5))
                                }
                            }
                            Text(option.name)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            if model.themeID == option.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chat font size: \(Int(model.chatFontSize))")
                        .foregroundStyle(theme.textPrimary)
                    Slider(value: $model.chatFontSize, in: 12...20, step: 1)
                        .tint(theme.accent)
                }
            }
            .listRowBackground(theme.surface)

            Section("Agent") {
                Picker("Permission mode", selection: $model.permissionMode) {
                    ForEach(PermissionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Picker("Backend", selection: $model.backend) {
                    ForEach(BackendKind.allCases) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                if model.backend == .webSocket {
                    TextField("Server URL", text: $model.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Reconnect") {
                        model.reconnect()
                    }
                }
            }
            .listRowBackground(theme.surface)

            Section("Behavior") {
                Toggle("Haptics", isOn: $model.hapticsEnabled)
                    .tint(theme.accent)
            }
            .listRowBackground(theme.surface)

            Section("About") {
                LabeledContent("App", value: "Pi iOS 0.1.0")
                Text("A mobile companion for the Pi coding agent")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
            }
            .listRowBackground(theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(theme.appBG)
        .navigationTitle("Settings")
        .tint(theme.accent)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
