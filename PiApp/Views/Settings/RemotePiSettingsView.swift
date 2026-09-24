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
                TextField("Relay URL for new pairings", text: $store.relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Text("The public Remote Pi relay is used by default. Each paired Pi keeps the relay that was used when it was added.")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
            }
            .listRowBackground(theme.surface)

            if !store.peers.isEmpty {
                Section("Paired Pi") {
                    ForEach(store.peers) { peer in
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                model.setDefaultRemotePiPeer(peer.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(peer.sessionName)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(theme.textPrimary)
                                        if store.selectedPeerID == peer.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(theme.accent)
                                        }
                                    }
                                    Text("Room \(peer.roomID)")
                                        .font(.caption)
                                        .foregroundStyle(theme.textSecondary)
                                    Text(store.activeModelName(for: peer.id) ?? peer.relayURL)
                                        .font(.caption2)
                                        .foregroundStyle(theme.textMuted)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button("Use for active session") {
                                    model.useRemotePiPeerForActiveSession(peer.id)
                                }
                                Button("Forget on this iPhone", role: .destructive) {
                                    model.forgetRemotePiPeer(peer.id)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }

                    Text("The checked Pi is the default for new sessions. Use the menu to assign a Pi to the active session.")
                        .font(.caption)
                        .foregroundStyle(theme.textMuted)
                }
                .listRowBackground(theme.surface)
            }

            Section(store.peers.isEmpty ? "Pair" : "Add another Pi") {
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
                model.setDefaultRemotePiPeer(peer.id)
                if model.activeSession == nil {
                    model.backend = .remotePi
                }
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
