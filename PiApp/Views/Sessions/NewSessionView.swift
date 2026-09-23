import SwiftUI

struct NewSessionView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedBackend: BackendKind

    init(initialBackend: BackendKind) {
        _selectedBackend = State(initialValue: initialBackend)
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var providers = model.providerStore
        let theme = model.theme

        NavigationStack {
            Form {
                Section("Backend") {
                    Picker("Run this session with", selection: $selectedBackend) {
                        ForEach(BackendKind.allCases) { backend in
                            Label(backend.shortName, systemImage: backend.icon)
                                .tag(backend)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .listRowBackground(theme.surface)

                switch selectedBackend {
                case .directAPI:
                    Section("AI Provider") {
                        Picker("Provider", selection: Binding<String?>(
                            get: { providers.activeProviderID },
                            set: { if let id = $0 { providers.setActiveProvider(id) } }
                        )) {
                            ForEach(providers.providers) { provider in
                                Text(provider.name).tag(provider.id as String?)
                            }
                        }
                        if let provider = providers.activeProvider {
                            let availableModels = providers.availableModels(for: provider)
                            if availableModels.isEmpty {
                                TextField("Model ID", text: Binding(
                                    get: { providers.activeModelID ?? "" },
                                    set: { providers.activeModelID = $0 }
                                ))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            } else {
                                Picker("Model", selection: $providers.activeModelID) {
                                    ForEach(availableModels) { definition in
                                        Text(definition.name).tag(definition.id as String?)
                                    }
                                }
                            }
                            if !providers.isAuthenticated(provider: provider) {
                                Label("This provider still needs authentication in Settings.",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(theme.warning)
                            }
                        }
                    }
                    .listRowBackground(theme.surface)

                case .remotePi:
                    Section("Remote Pi") {
                        if let peer = model.remotePiStore.peer {
                            LabeledContent("Session", value: peer.sessionName)
                            LabeledContent("Model", value: model.remotePiStore.activeModelName ?? "Detecting…")
                        } else {
                            Label("Pair Remote Pi in Settings before creating this session.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(theme.warning)
                        }
                    }
                    .listRowBackground(theme.surface)

                case .webSocket:
                    Section("Remote WebSocket") {
                        TextField("Server URL", text: $model.serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Text("Uses the existing custom WebSocket bridge.")
                            .font(.caption)
                            .foregroundStyle(theme.textMuted)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.appBG)
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.newSessionPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        model.createSession(backend: selectedBackend)
                    }
                    .disabled(!canCreate)
                }
            }
        }
        .tint(theme.accent)
        .presentationDetents([.medium, .large])
    }

    private var canCreate: Bool {
        switch selectedBackend {
        case .remotePi:
            return model.remotePiStore.isPaired
        case .webSocket:
            guard let url = URL(string: model.serverURL),
                  let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "ws" || scheme == "wss"
        case .directAPI:
            return true
        }
    }
}

#Preview {
    NewSessionView(initialBackend: .directAPI)
        .environment(AppModel())
}
