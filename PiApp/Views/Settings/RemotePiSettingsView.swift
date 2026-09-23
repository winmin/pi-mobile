import SwiftUI
import UIKit

struct RemotePiSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pairingCode = ""
    @State private var showScanner = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        @Bindable var store = model.remotePiStore
        let theme = model.theme

        Form {
            Section("Connection") {
                TextField("Relay URL", text: $store.relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Text("The public Remote Pi relay is used by default. You can enter your self-hosted relay here.")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
            }
            .listRowBackground(theme.surface)

            if let peer = store.peer {
                Section("Paired Pi") {
                    LabeledContent("Session", value: peer.sessionName)
                    LabeledContent("Room", value: peer.roomID)
                    if let activeModel = store.activeModelName {
                        LabeledContent("Model", value: activeModel)
                    }
                    LabeledContent("Paired", value: peer.pairedAt.formatted(date: .abbreviated, time: .shortened))
                    Button("Use Remote Pi backend") {
                        model.backend = .remotePi
                    }
                    Button("Forget on this iPhone", role: .destructive) {
                        store.forgetPairing()
                        if model.backend == .remotePi {
                            model.backend = .directAPI
                        }
                    }
                }
                .listRowBackground(theme.surface)
            } else {
                Section("Pair") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Install the extension on your computer:")
                        Text("pi install npm:remote-pi")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("2. In Pi run `/remote-pi`, then `/remote-pi pair`.")
                        Text("3. Scan its QR code or paste the pairing link below.")
                    }
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)

                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
                    }

                    TextField("remotepi://pair?…", text: $pairingCode, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2...5)

                    Button("Paste from Clipboard") {
                        pairingCode = UIPasteboard.general.string ?? ""
                    }

                    Button(store.isPairing ? "Pairing…" : "Pair") {
                        beginPairing()
                    }
                    .disabled(store.isPairing || pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .listRowBackground(theme.surface)
            }

            if let successMessage {
                Section {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                }
                .listRowBackground(theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.appBG)
        .navigationTitle("Remote Pi")
        .tint(theme.accent)
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                RemotePiQRScannerView { code in
                    showScanner = false
                    pairingCode = code
                    beginPairing()
                } onError: { message in
                    showScanner = false
                    errorMessage = message
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Remote Pi QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
        }
        .alert("Remote Pi", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func beginPairing() {
        let code = pairingCode
        successMessage = nil
        Task {
            do {
                let peer = try await model.remotePiStore.pair(using: code)
                model.backend = .remotePi
                successMessage = "Paired with \(peer.sessionName)."
                pairingCode = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack {
        RemotePiSettingsView()
            .environment(AppModel())
    }
}
