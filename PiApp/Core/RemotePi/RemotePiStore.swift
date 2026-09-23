import CryptoKit
import Foundation
import Observation
import UIKit

struct RemotePiPeer: Codable, Equatable {
    var remotePublicKey: String
    var sessionName: String
    var relayURL: String
    var roomID: String
    var pairedAt: Date
}

struct RemotePiConfiguration {
    var peer: RemotePiPeer
    var privateKey: Data
}

struct RemotePiPairPayload {
    var token: String
    var remotePublicKey: String
    var sessionName: String
    var relayURL: String?
    var roomID: String?

    init(uriString: String) throws {
        let trimmed = uriString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "remotepi",
              components.host?.lowercased() == "pair" else {
            throw RemotePiError.invalidPairingCode
        }

        let values = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })
        guard let token = values["t"],
              let tokenData = Data(base64AnyEncoded: token), tokenData.count == 16,
              let remoteKey = values["epk"],
              let remoteKeyData = Data(base64AnyEncoded: remoteKey), remoteKeyData.count == 32,
              let name = values["n"], !name.isEmpty else {
            throw RemotePiError.invalidPairingCode
        }

        self.token = token
        remotePublicKey = remoteKeyData.base64EncodedString()
        sessionName = String(name.prefix(80))
        relayURL = values["r"]?.nilIfEmpty
        roomID = values["rm"]?.nilIfEmpty
    }
}

enum RemotePiError: LocalizedError {
    case notPaired
    case invalidPairingCode
    case invalidRelayURL
    case invalidFrame
    case connectionClosed
    case pairingTimedOut
    case pairingRejected(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Remote Pi is not paired. Open Settings → Remote Pi Plugin."
        case .invalidPairingCode:
            return "Invalid Remote Pi QR code or pairing link."
        case .invalidRelayURL:
            return "Enter a valid http(s) or ws(s) relay URL."
        case .invalidFrame:
            return "Remote Pi returned an invalid protocol frame."
        case .connectionClosed:
            return "The Remote Pi connection was closed."
        case .pairingTimedOut:
            return "Pairing timed out. Run /remote-pi pair again and scan the new QR code."
        case .pairingRejected(let message), .remote(let message):
            return message
        }
    }
}

@MainActor
@Observable
final class RemotePiStore {
    static let defaultRelayURL = "https://relay-rp1.jacobmoura.work"

    var relayURL: String {
        didSet { UserDefaults.standard.set(relayURL, forKey: "remotePi.relayURL") }
    }
    private(set) var peer: RemotePiPeer?
    private(set) var isPairing = false
    private(set) var activeModelName: String?

    var isPaired: Bool { peer != nil }

    private let peerKey = "remote-pi.peer"
    private let identityKey = "remote-pi.owner-private-key"

    init() {
        relayURL = UserDefaults.standard.string(forKey: "remotePi.relayURL")
            ?? Self.defaultRelayURL
        if let json = KeychainHelper.get(peerKey),
           let data = json.data(using: .utf8) {
            peer = try? JSONDecoder().decode(RemotePiPeer.self, from: data)
        }
    }

    func configuration() throws -> RemotePiConfiguration {
        guard let peer else { throw RemotePiError.notPaired }
        return RemotePiConfiguration(peer: peer, privateKey: try loadOrCreatePrivateKey())
    }

    @discardableResult
    func pair(using rawCode: String) async throws -> RemotePiPeer {
        guard !isPairing else { throw RemotePiError.remote("Pairing is already in progress.") }
        isPairing = true
        defer { isPairing = false }

        let payload = try RemotePiPairPayload(uriString: rawCode)
        let effectiveRelay = payload.relayURL ?? relayURL
        guard RemotePiConnection.webSocketURL(from: effectiveRelay) != nil else {
            throw RemotePiError.invalidRelayURL
        }

        let provisionalPeer = RemotePiPeer(
            remotePublicKey: payload.remotePublicKey,
            sessionName: payload.sessionName,
            relayURL: effectiveRelay,
            roomID: payload.roomID ?? "main",
            pairedAt: Date()
        )
        let connection = RemotePiConnection(configuration: RemotePiConfiguration(
            peer: provisionalPeer,
            privateKey: try loadOrCreatePrivateKey()
        ))

        do {
            try await connection.connect()
            let requestID = RemotePiID.make()
            try await connection.sendInner([
                "type": "pair_request",
                "id": requestID,
                "token": payload.token,
                "device_name": UIDevice.current.name,
            ])

            let deadline = Date().addingTimeInterval(20)
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                await connection.close()
            }
            defer { timeout.cancel() }

            while true {
                let reply: [String: Any]
                do {
                    reply = try await connection.receiveInner()
                } catch {
                    if Date() >= deadline { throw RemotePiError.pairingTimedOut }
                    throw error
                }
                guard (reply["in_reply_to"] as? String) == requestID else { continue }
                switch reply["type"] as? String {
                case "pair_ok":
                    let confirmed = RemotePiPeer(
                        remotePublicKey: payload.remotePublicKey,
                        sessionName: (reply["session_name"] as? String) ?? payload.sessionName,
                        relayURL: effectiveRelay,
                        roomID: (reply["room_id"] as? String) ?? payload.roomID ?? "main",
                        pairedAt: Date()
                    )
                    try save(peer: confirmed)
                    relayURL = effectiveRelay
                    await connection.close()
                    return confirmed
                case "pair_error":
                    let message = (reply["message"] as? String)
                        ?? (reply["code"] as? String)
                        ?? "Pairing was rejected by Remote Pi."
                    throw RemotePiError.pairingRejected(message)
                default:
                    continue
                }
            }
        } catch {
            await connection.close()
            throw error
        }
    }

    func forgetPairing() {
        peer = nil
        activeModelName = nil
        KeychainHelper.delete(peerKey)
        // This build supports one Remote Pi peer. Rotate the owner identity
        // too, otherwise the Pi still sees the next pairing attempt as the
        // already-paired owner and intentionally ignores pair_request.
        KeychainHelper.delete(identityKey)
    }

    func updateActiveModel(_ name: String) {
        activeModelName = name
    }

    private func save(peer: RemotePiPeer) throws {
        let data = try JSONEncoder().encode(peer)
        guard let json = String(data: data, encoding: .utf8),
              KeychainHelper.set(json, for: peerKey) == errSecSuccess else {
            throw RemotePiError.remote("Could not save the Remote Pi pairing in Keychain.")
        }
        self.peer = peer
    }

    private func loadOrCreatePrivateKey() throws -> Data {
        if let encoded = KeychainHelper.get(identityKey),
           let data = Data(base64Encoded: encoded), data.count == 32 {
            return data
        }
        let key = Curve25519.Signing.PrivateKey()
        let data = key.rawRepresentation
        guard KeychainHelper.set(data.base64EncodedString(), for: identityKey) == errSecSuccess else {
            throw RemotePiError.remote("Could not save the Remote Pi identity in Keychain.")
        }
        return data
    }
}

enum RemotePiID {
    /// UUIDv7: the Remote Pi protocol uses time-sortable UUIDs for requests.
    static func make() -> String {
        var bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        bytes[0] = UInt8((milliseconds >> 40) & 0xff)
        bytes[1] = UInt8((milliseconds >> 32) & 0xff)
        bytes[2] = UInt8((milliseconds >> 24) & 0xff)
        bytes[3] = UInt8((milliseconds >> 16) & 0xff)
        bytes[4] = UInt8((milliseconds >> 8) & 0xff)
        bytes[5] = UInt8(milliseconds & 0xff)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}

private extension Data {
    init?(base64AnyEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
