import CryptoKit
import Foundation

enum RemotePiInboundPacket {
    case message([String: Any])
    case model(String)
}

actor RemotePiConnection {
    private let configuration: RemotePiConfiguration
    private var socket: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?

    init(configuration: RemotePiConfiguration) {
        self.configuration = configuration
    }

    static func webSocketURL(from rawURL: String) -> URL? {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        guard components.host != nil else { return nil }
        return components.url
    }

    func connect() async throws {
        if socket != nil { return }
        guard let url = Self.webSocketURL(from: configuration.peer.relayURL) else {
            throw RemotePiError.invalidRelayURL
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: configuration.privateKey)
        let task = URLSession.shared.webSocketTask(with: url)
#if DEBUG
        FileHandle.standardError.write(Data(
            "[PiMobile][RemotePi] connecting host=\(url.host ?? "unknown") room=\(configuration.peer.roomID)\n".utf8
        ))
#endif
        socket = task
        task.resume()

        do {
            try await sendFrame([
                "type": "hello",
                "pubkey": key.publicKey.rawRepresentation.base64EncodedString(),
                "room_id": "main",
            ])
            let challenge = try await receiveFrame()
            guard (challenge["type"] as? String) == "challenge",
                  let encodedNonce = challenge["nonce"] as? String,
                  let nonce = Data(base64AnyEncoded: encodedNonce) else {
                throw RemotePiError.invalidFrame
            }
            let signature = try key.signature(for: nonce)
            try await sendFrame([
                "type": "auth",
                "sig": signature.base64EncodedString(),
            ])
            // Room metadata is how the plugin publishes the active Pi model.
            // Subscribe after relay authentication so the chat footer can show
            // the model running on the remote computer rather than a local one.
            try await sendFrame([
                "type": "subscribe_rooms",
                "peers": [configuration.peer.remotePublicKey],
            ])
            try await sendFrame([
                "type": "rooms_check",
                "peers": [configuration.peer.remotePublicKey],
            ])
            startHeartbeat()
#if DEBUG
            FileHandle.standardError.write(Data(
                "[PiMobile][RemotePi] authenticated room=\(configuration.peer.roomID)\n".utf8
            ))
#endif
        } catch {
#if DEBUG
            let nsError = error as NSError
            FileHandle.standardError.write(Data(
                "[PiMobile][RemotePi] handshake failed \(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)\n".utf8
            ))
#endif
            task.cancel(with: .goingAway, reason: nil)
            socket = nil
            throw error
        }
    }

    func sendInner(_ inner: [String: Any]) async throws {
        guard socket != nil else { throw RemotePiError.connectionClosed }
#if DEBUG
        let innerType = (inner["type"] as? String) ?? "unknown"
        FileHandle.standardError.write(Data(
            "[PiMobile][RemotePi] send inner=\(innerType) room=\(configuration.peer.roomID)\n".utf8
        ))
#endif
        let innerData = try JSONSerialization.data(withJSONObject: inner)
        try await sendFrame([
            "peer": configuration.peer.remotePublicKey,
            "room": configuration.peer.roomID,
            "ct": innerData.base64EncodedString(),
        ])
    }

    func receiveInner() async throws -> [String: Any] {
        while true {
            switch try await receivePacket() {
            case .message(let inner): return inner
            case .model: continue
            }
        }
    }

    func receivePacket() async throws -> RemotePiInboundPacket {
        while socket != nil {
            let frame = try await receiveFrame()
            if let type = frame["type"] as? String {
#if DEBUG
                let code = (frame["code"] as? String).map { " code=\($0)" } ?? ""
                let roomCount = (frame["rooms"] as? [[String: Any]]).map { " rooms=\($0.count)" } ?? ""
                FileHandle.standardError.write(Data(
                    "[PiMobile][RemotePi] receive control=\(type)\(code)\(roomCount)\n".utf8
                ))
#endif
                if type == "error" {
                    throw RemotePiError.remote((frame["message"] as? String) ?? "Remote Pi relay error.")
                }
                if let model = roomModel(from: frame) {
                    return .model(model)
                }
                // Other presence and room control frames are not chat payloads.
                continue
            }
            guard let peer = frame["peer"] as? String,
                  normalizedBase64(peer) == normalizedBase64(configuration.peer.remotePublicKey),
                  let encoded = frame["ct"] as? String,
                  let data = Data(base64AnyEncoded: encoded),
                  let inner = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
#if DEBUG
            let innerType = (inner["type"] as? String) ?? "unknown"
            FileHandle.standardError.write(Data(
                "[PiMobile][RemotePi] receive inner=\(innerType) room=\(configuration.peer.roomID)\n".utf8
            ))
#endif
            return .message(inner)
        }
        throw RemotePiError.connectionClosed
    }

    func close() {
#if DEBUG
        FileHandle.standardError.write(Data(
            "[PiMobile][RemotePi] closing room=\(configuration.peer.roomID)\n".utf8
        ))
#endif
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func sendFrame(_ frame: [String: Any]) async throws {
        guard let socket else { throw RemotePiError.connectionClosed }
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemotePiError.invalidFrame
        }
        try await socket.send(.string(text))
    }

    private func receiveFrame() async throws -> [String: Any] {
        guard let socket else { throw RemotePiError.connectionClosed }
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw RemotePiError.invalidFrame
        }
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemotePiError.invalidFrame
        }
        return frame
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.sendPing()
            }
        }
    }

    private func sendPing() async {
        guard let socket else { return }
        await withCheckedContinuation { continuation in
            socket.sendPing { _ in continuation.resume() }
        }
    }

    private func roomModel(from frame: [String: Any]) -> String? {
        guard let peer = frame["peer"] as? String,
              normalizedBase64(peer) == normalizedBase64(configuration.peer.remotePublicKey),
              let type = frame["type"] as? String else { return nil }

        switch type {
        case "rooms":
            guard let rooms = frame["rooms"] as? [[String: Any]],
                  let room = rooms.first(where: {
                      ($0["room_id"] as? String) == configuration.peer.roomID
                  }) else { return nil }
            return nonEmptyModel(room["model"])

        case "room_announced":
            guard (frame["room_id"] as? String) == configuration.peer.roomID else { return nil }
            return nonEmptyModel(frame["model"])
                ?? nonEmptyModel((frame["meta"] as? [String: Any])?["model"])

        case "room_meta_updated":
            guard (frame["room_id"] as? String) == configuration.peer.roomID else { return nil }
            return nonEmptyModel((frame["meta"] as? [String: Any])?["model"])

        default:
            return nil
        }
    }
}

private func nonEmptyModel(_ value: Any?) -> String? {
    guard let model = value as? String,
          !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return model
}

private func normalizedBase64(_ value: String) -> String? {
    Data(base64AnyEncoded: value)?.base64EncodedString()
}

private extension Data {
    init?(base64AnyEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}
