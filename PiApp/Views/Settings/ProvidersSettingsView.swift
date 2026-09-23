import SwiftUI

// MARK: - Provider list

struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model

    private var store: ProviderStore { model.providerStore }

    var body: some View {
        let theme = model.theme
        let _ = store.credentialVersion
        List {
            ForEach(store.providers) { provider in
                NavigationLink {
                    ProviderDetailView(providerID: provider.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(provider.name)
                                .font(.callout)
                                .foregroundStyle(theme.textPrimary)
                            if provider.id == store.activeProviderID {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(theme.accent.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                            authBadge(provider, theme)
                        }
                        Text(connectionDescription(for: provider))
                            .font(.caption2.monospaced())
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { store.providers[$0].id }.forEach(store.deleteProvider)
            }

            Button {
                let id = "custom-\(UUID().uuidString.prefix(6).lowercased())"
                store.addProvider(AIProvider(id: id, name: "New Provider", baseUrl: "",
                                             api: .openaiCompletions, models: []))
            } label: {
                Label("Add Provider", systemImage: "plus")
                    .foregroundStyle(theme.accent)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.appBG)
        .navigationTitle("AI Providers")
    }

    @ViewBuilder
    private func authBadge(_ provider: AIProvider, _ theme: PiTheme) -> some View {
        switch store.credential(for: provider.id) {
        case .apiKey:
            Text("API key ✓")
                .font(.caption2)
                .foregroundStyle(theme.success)
        case .oauth:
            Text("OAuth ✓")
                .font(.caption2)
                .foregroundStyle(theme.success)
        case nil:
            Text("Not configured")
                .font(.caption2)
                .foregroundStyle(theme.textFaint)
        }
    }

    private func connectionDescription(for provider: AIProvider) -> String {
        if provider.id == "openai", case .oauth? = store.credential(for: provider.id) {
            return "openai-codex-responses · chatgpt.com/backend-api"
        }
        return "\(provider.api.rawValue) · \(provider.baseUrl.isEmpty ? "no base URL" : provider.baseUrl)"
    }
}

// MARK: - Provider detail

struct ProviderDetailView: View {
    @Environment(AppModel.self) private var model
    let providerID: String

    @State private var name = ""
    @State private var baseUrl = ""
    @State private var api: APIKind = .openaiCompletions
    @State private var modelsText = ""
    @State private var apiKeyInput = ""
    @State private var saved = false
    @State private var showAnthropicSheet = false
    @State private var showCodexSheet = false

    private var store: ProviderStore { model.providerStore }
    private var provider: AIProvider? { store.providers.first { $0.id == providerID } }

    var body: some View {
        let theme = model.theme
        let _ = store.credentialVersion
        Form {
            Section("Provider") {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.body, design: .monospaced))
                Picker("API", selection: $api) {
                    ForEach(APIKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                TextField("Models (comma-separated ids)", text: $modelsText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button(saved ? "Saved ✓" : "Save Changes") {
                    save()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                }
                .disabled(name.isEmpty)
            }
            .listRowBackground(theme.surface)

            Section("Authentication") {
                switch store.credential(for: providerID) {
                case .apiKey:
                    Label("API key saved (••••)", systemImage: "key.fill")
                        .foregroundStyle(theme.success)
                case .oauth:
                    Label("Signed in with OAuth", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(theme.success)
                case nil:
                    Label("Not configured", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.warning)
                }

                SecureField("API Key", text: $apiKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save API Key") {
                    guard !apiKeyInput.isEmpty else { return }
                    store.setCredential(.apiKey(apiKeyInput), for: providerID)
                    apiKeyInput = ""
                }
                .disabled(apiKeyInput.isEmpty)

                if api == .anthropicMessages {
                    Button {
                        showAnthropicSheet = true
                    } label: {
                        Label("Sign in with Claude (OAuth)", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                if providerID == "openai" {
                    Button {
                        showCodexSheet = true
                    } label: {
                        Label("Sign in with ChatGPT (device code)", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    Text("ChatGPT OAuth uses your Codex access and is routed through the Codex Responses adapter. API keys continue to use the Base URL above.")
                        .font(.caption2)
                        .foregroundStyle(theme.textMuted)

                    if case .oauth? = store.credential(for: providerID) {
                        LabeledContent("Codex models", value: "\(store.availableModels(for: provider ?? AIProvider(id: providerID, name: "OpenAI", baseUrl: "", api: .openaiCompletions, models: [])).count)")
                        Button {
                            Task { try? await store.refreshCodexModels() }
                        } label: {
                            if store.isRefreshingCodexModels {
                                Label("Refreshing models…", systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label("Refresh model list", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(store.isRefreshingCodexModels)
                        if let error = store.codexModelsRefreshError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(theme.warning)
                                .textSelection(.enabled)
                        } else if let updated = store.codexModelsLastUpdated {
                            Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(theme.textMuted)
                        }
                    }
                }

                if store.credential(for: providerID) != nil {
                    Button("Sign Out", role: .destructive) {
                        store.deleteCredential(for: providerID)
                    }
                }
            }
            .listRowBackground(theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(theme.appBG)
        .navigationTitle(provider?.name ?? "Provider")
        .onAppear(perform: load)
        .sheet(isPresented: $showAnthropicSheet) {
            AnthropicLoginSheet(providerID: providerID)
        }
        .sheet(isPresented: $showCodexSheet) {
            CodexLoginSheet(providerID: providerID)
        }
    }

    private func load() {
        guard let provider else { return }
        name = provider.name
        baseUrl = provider.baseUrl
        api = provider.api
        modelsText = provider.models.map(\.id).joined(separator: ", ")
    }

    private func save() {
        guard var provider else { return }
        provider.name = name
        provider.baseUrl = baseUrl.trimmingCharacters(in: .whitespaces)
        provider.api = api
        provider.models = modelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { AIModelDef(id: $0, name: $0) }
        store.updateProvider(provider)
    }
}

// MARK: - Anthropic OAuth sheet

struct AnthropicLoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let providerID: String

    @State private var authorizeURL: URL?
    @State private var pasted = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("How it works") {
                    Text("1. Tap “Open Browser” and sign in to Claude.\n2. After login the browser tries to open a localhost address and fails to load — that’s expected.\n3. Copy the full URL from the address bar and paste it below.")
                        .font(.callout)
                }
                Section {
                    Button("Open Browser") {
                        if let authorizeURL { openURL(authorizeURL) }
                    }
                    .disabled(authorizeURL == nil)
                    TextField("Paste redirect URL or code#state", text: $pasted)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.callout, design: .monospaced))
                    Button(busy ? "Signing in…" : "Complete Sign In") {
                        complete()
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        if error.contains("invalid_grant") || error.localizedCaseInsensitiveContains("expired")
                            || error.localizedCaseInsensitiveContains("already") {
                            Text("Authorization codes are single-use and expire within minutes. Tap “Open Browser” again and paste the fresh redirect URL.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Sign in with Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            authorizeURL = model.providerStore.oauth.startAnthropicLogin()
        }
    }

    private func complete() {
        busy = true
        error = nil
        Task { @MainActor in
            do {
                let credential = try await model.providerStore.oauth.finishAnthropicLogin(pastedURL: pasted)
                model.providerStore.setCredential(credential, for: providerID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

// MARK: - OpenAI Codex device-login sheet

struct CodexLoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let providerID: String

    @State private var userCode: String?
    @State private var verificationURL: URL?
    @State private var status = "Requesting device code…"
    @State private var failure: String?
    @State private var loginTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let userCode {
                    Text("Enter this code at")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(userCode)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if let verificationURL {
                        Button("Open auth.openai.com") {
                            openURL(verificationURL)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("After sign-in, choose a Codex model and use the Direct API backend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle("Sign in with ChatGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { start() }
        .onDisappear { loginTask?.cancel() }
    }

    private func start() {
        loginTask = Task { @MainActor in
            do {
                let (code, url, poll) = try await model.providerStore.oauth.startCodexDeviceLogin()
                userCode = code
                verificationURL = url
                status = "Finish in the browser, then return here…"
                openURL(url)
                // Give iOS time to finish the foreground → Safari transition.
                // OAuthManager will wait until this app is active before polling.
                try await Task.sleep(nanoseconds: 750_000_000)
                let credential = try await poll()
                model.providerStore.setCredential(credential, for: providerID)
                status = "Loading available models…"
                do {
                    let models = try await model.providerStore.refreshCodexModels()
                    status = "Signed in · \(models.count) models loaded ✓"
                } catch {
                    // Authentication succeeded. Keep the bundled catalog as a
                    // fallback and let the user retry model discovery later.
                    status = "Signed in · using bundled model list ✓"
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            } catch is CancellationError {
                // Sheet dismissed while polling.
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

#Preview {
    ProvidersSettingsView()
        .environment(AppModel())
}
