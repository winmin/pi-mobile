import CryptoKit
import Foundation
import Security

enum OAuthError: LocalizedError {
    case noPendingLogin
    case invalidCallback
    case stateMismatch
    case http(Int, String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .noPendingLogin:
            return "No sign-in in progress. Tap “Open Browser” first."
        case .invalidCallback:
            return "Could not read the redirect URL. Paste the full URL from the browser address bar."
        case .stateMismatch:
            return "Sign-in state mismatch. Please start the sign-in again."
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .malformedResponse(let detail):
            return "Unexpected response from auth server (\(detail))."
        }
    }
}

/// Implements pi's OAuth flows: Anthropic (authorization code + PKCE with manual-paste
/// fallback for iOS) and OpenAI Codex (device code), plus refresh grants.
@MainActor
final class OAuthManager {
    // Anthropic
    private static let anthropicClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let anthropicAuthorizeURL = "https://claude.ai/oauth/authorize"
    private static let anthropicTokenURL = "https://platform.claude.com/v1/oauth/token"
    private static let anthropicRedirectURI = "http://localhost:53692/callback"
    private static let anthropicScopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    // OpenAI Codex
    private static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let codexBase = "https://auth.openai.com"
    private static let codexRedirectURI = "http://localhost:1455/auth/callback"

    private var pendingAnthropicVerifier: String?

    // MARK: - Anthropic (PKCE + manual paste)

    func startAnthropicLogin() -> URL {
        let verifier = Self.makeVerifier()
        pendingAnthropicVerifier = verifier
        var components = URLComponents(string: Self.anthropicAuthorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.anthropicClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.anthropicRedirectURI),
            URLQueryItem(name: "scope", value: Self.anthropicScopes),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier),
        ]
        return components.url!
    }

    func finishAnthropicLogin(pastedURL: String) async throws -> AICredential {
        guard let verifier = pendingAnthropicVerifier else { throw OAuthError.noPendingLogin }
        let (code, state) = try Self.parseCodeAndState(pastedURL)
        guard state == verifier else { throw OAuthError.stateMismatch }

        let json = try await postJSON(Self.anthropicTokenURL, body: [
            "grant_type": "authorization_code",
            "client_id": Self.anthropicClientID,
            "code": code,
            "state": state,
            "redirect_uri": Self.anthropicRedirectURI,
            "code_verifier": verifier,
        ])
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw OAuthError.malformedResponse("missing access_token/refresh_token")
        }
        pendingAnthropicVerifier = nil
        return .oauth(access: access, refresh: refresh,
                      expires: Self.expiryDate(from: json), accountId: nil)
    }

    // MARK: - OpenAI Codex (device code)

    func startCodexDeviceLogin() async throws -> (userCode: String, verificationURL: URL,
                                                  poll: () async throws -> AICredential) {
        let json = try await postJSON(Self.codexBase + "/api/accounts/deviceauth/usercode",
                                      body: ["client_id": Self.codexClientID])
        guard let deviceAuthID = json["device_auth_id"] as? String,
              let userCode = json["user_code"] as? String else {
            throw OAuthError.malformedResponse("missing device_auth_id/user_code")
        }
        let interval = (json["interval"] as? NSNumber)?.doubleValue ?? 5
        let verificationURL = URL(string: Self.codexBase + "/codex/device")!

        let poll: () async throws -> AICredential = { [self] in
            while true {
                try Task.checkCancellation()
                do {
                    let tokenJSON = try await postJSON(Self.codexBase + "/api/accounts/deviceauth/token",
                                                       body: ["device_auth_id": deviceAuthID,
                                                              "user_code": userCode])
                    if let authorizationCode = tokenJSON["authorization_code"] as? String,
                       let codeVerifier = tokenJSON["code_verifier"] as? String {
                        return try await exchangeCodexCode(authorizationCode, verifier: codeVerifier)
                    }
                } catch OAuthError.http(let status, _) where status == 403 || status == 404 {
                    // Still waiting for the user to authorize.
                }
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        return (userCode, verificationURL, poll)
    }

    private func exchangeCodexCode(_ code: String, verifier: String) async throws -> AICredential {
        let json = try await postForm(Self.codexBase + "/oauth/token", fields: [
            "grant_type": "authorization_code",
            "client_id": Self.codexClientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": Self.codexRedirectURI,
        ])
        guard let access = json["access_token"] as? String else {
            throw OAuthError.malformedResponse("missing access_token")
        }
        let refresh = (json["refresh_token"] as? String) ?? ""
        return .oauth(access: access, refresh: refresh,
                      expires: Self.expiryDate(from: json),
                      accountId: Self.codexAccountID(fromJWT: access))
    }

    // MARK: - Refresh

    func refreshIfNeeded(_ credential: AICredential, providerID: String,
                         api: APIKind?) async throws -> AICredential {
        guard case .oauth(_, let refresh, let expires, let accountId) = credential else {
            return credential
        }
        guard Date().addingTimeInterval(300) >= expires else { return credential }

        switch api ?? .anthropicMessages {
        case .anthropicMessages:
            let json = try await postJSON(Self.anthropicTokenURL, body: [
                "grant_type": "refresh_token",
                "client_id": Self.anthropicClientID,
                "refresh_token": refresh,
            ])
            guard let newAccess = json["access_token"] as? String else {
                throw OAuthError.malformedResponse("refresh: missing access_token")
            }
            let newRefresh = (json["refresh_token"] as? String) ?? refresh
            return .oauth(access: newAccess, refresh: newRefresh,
                          expires: Self.expiryDate(from: json), accountId: accountId)

        case .openaiCompletions:
            let json = try await postForm(Self.codexBase + "/oauth/token", fields: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": Self.codexClientID,
            ])
            guard let newAccess = json["access_token"] as? String else {
                throw OAuthError.malformedResponse("refresh: missing access_token")
            }
            let newRefresh = (json["refresh_token"] as? String) ?? refresh
            let newAccountID = Self.codexAccountID(fromJWT: newAccess) ?? accountId
            return .oauth(access: newAccess, refresh: newRefresh,
                          expires: Self.expiryDate(from: json), accountId: newAccountID)
        }
    }

    // MARK: - PKCE helpers

    private static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func parseCodeAndState(_ pasted: String) throws -> (code: String, state: String) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           let state = components.queryItems?.first(where: { $0.name == "state" })?.value {
            return (code, state)
        }
        // Also accept a bare "code#state" paste.
        let parts = trimmed.split(separator: "#")
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        throw OAuthError.invalidCallback
    }

    private static func expiryDate(from json: [String: Any]) -> Date {
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        // pi stores now + expires_in*1000 - 300000 (5 min early refresh margin)
        return Date(timeIntervalSinceNow: expiresIn - 300)
    }

    private static func codexAccountID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    // MARK: - HTTP helpers

    private func postJSON(_ urlString: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func postForm(_ urlString: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await HTTPRetry.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.http(status, String(body.prefix(500)))
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
