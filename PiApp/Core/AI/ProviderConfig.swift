import Foundation
import Observation

// MARK: - Provider model

struct AIModelDef: Codable, Identifiable, Equatable {
    var id: String
    var name: String
}

enum APIKind: String, Codable, CaseIterable {
    case openaiCompletions = "openai-completions"
    case anthropicMessages = "anthropic-messages"
}

struct AIProvider: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseUrl: String
    var api: APIKind
    var models: [AIModelDef]
}

// MARK: - Credentials (mirrors pi's auth.json shape)

enum AICredential: Equatable {
    case apiKey(String)
    case oauth(access: String, refresh: String, expires: Date, accountId: String?)
}

extension AICredential: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key, access, refresh, expires, accountId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "api_key":
            self = .apiKey(try container.decode(String.self, forKey: .key))
        case "oauth":
            let access = try container.decode(String.self, forKey: .access)
            let refresh = try container.decode(String.self, forKey: .refresh)
            let expiresMs = try container.decode(Double.self, forKey: .expires)
            let accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
            self = .oauth(access: access, refresh: refresh,
                          expires: Date(timeIntervalSince1970: expiresMs / 1000),
                          accountId: accountId)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "Unknown credential type \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .apiKey(let key):
            try container.encode("api_key", forKey: .type)
            try container.encode(key, forKey: .key)
        case .oauth(let access, let refresh, let expires, let accountId):
            try container.encode("oauth", forKey: .type)
            try container.encode(access, forKey: .access)
            try container.encode(refresh, forKey: .refresh)
            try container.encode(expires.timeIntervalSince1970 * 1000, forKey: .expires)
            try container.encodeIfPresent(accountId, forKey: .accountId)
        }
    }
}

// MARK: - Store

enum ProviderError: LocalizedError {
    case noActiveProvider
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .noActiveProvider:
            return "No active AI provider. Configure one in Settings → AI Providers."
        case .notAuthenticated:
            return "Provider not authenticated. Add an API key or sign in (Settings → AI Providers)."
        }
    }
}

@MainActor
@Observable
final class ProviderStore {
    var providers: [AIProvider] {
        didSet { persistProviders() }
    }
    var activeProviderID: String? {
        didSet { UserDefaults.standard.set(activeProviderID, forKey: "activeProviderID") }
    }
    var activeModelID: String? {
        didSet { UserDefaults.standard.set(activeModelID, forKey: "activeModelID") }
    }

    /// Bumped whenever a Keychain credential changes so observing views re-render.
    private(set) var credentialVersion = 0

    /// The ChatGPT Codex catalog is account-scoped and is returned by the same
    /// backend used for OAuth inference. Keep the last successful result so the
    /// model picker is still useful offline; `codexModels` below is only the
    /// bundled fallback for a first launch or a failed refresh.
    private(set) var discoveredCodexModels: [AIModelDef] = []
    private(set) var codexModelsLastUpdated: Date?
    private(set) var isRefreshingCodexModels = false
    private(set) var codexModelsRefreshError: String?

    private var discoveredCodexAccountID: String?

    let oauth = OAuthManager()

    var activeProvider: AIProvider? {
        providers.first { $0.id == activeProviderID }
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "aiProviders"),
           let decoded = try? JSONDecoder().decode([AIProvider].self, from: data) {
            providers = decoded
        } else {
            providers = Self.builtIns
        }
        activeProviderID = defaults.string(forKey: "activeProviderID") ?? providers.first?.id
        activeModelID = defaults.string(forKey: "activeModelID")
            ?? providers.first { $0.id == activeProviderID }?.models.first?.id

        if let data = defaults.data(forKey: Self.codexModelsCacheKey),
           let cache = try? JSONDecoder().decode(CodexModelsCache.self, from: data),
           case .oauth(_, _, _, let accountID)? = Self.loadCredential(for: "openai"),
           cache.accountID == accountID {
            discoveredCodexModels = cache.models
            discoveredCodexAccountID = cache.accountID
            codexModelsLastUpdated = cache.updatedAt
        }

        // OAuth and API-key OpenAI use different APIs and model catalogs. Keep
        // old installs usable after adding the Codex adapter by moving an OAuth
        // login off the legacy API-key-only model selection.
        if activeProviderID == "openai",
           case .oauth? = Self.loadCredential(for: "openai"),
           !availableCodexModels.contains(where: { $0.id == activeModelID }) {
            activeModelID = availableCodexModels.first?.id ?? Self.defaultCodexModelID
        }
    }

    static let defaultCodexModelID = "gpt-5.4"

    static let codexModels: [AIModelDef] = [
        AIModelDef(id: "gpt-5.4", name: "GPT-5.4"),
        AIModelDef(id: "gpt-5.4-mini", name: "GPT-5.4 Mini"),
        AIModelDef(id: "gpt-5.3-codex", name: "GPT-5.3 Codex"),
        AIModelDef(id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark"),
        AIModelDef(id: "gpt-5.2-codex", name: "GPT-5.2 Codex"),
        AIModelDef(id: "gpt-5.2", name: "GPT-5.2"),
        AIModelDef(id: "gpt-5.1-codex-max", name: "GPT-5.1 Codex Max"),
        AIModelDef(id: "gpt-5.1-codex-mini", name: "GPT-5.1 Codex Mini"),
        AIModelDef(id: "gpt-5.1", name: "GPT-5.1"),
    ]

    private static let codexModelsCacheKey = "openai.codexModelsCache.v1"
    // The backend filters out models whose minimum Codex client version is
    // newer than this value. This app implements the catalog/Responses shape
    // used by Codex CLI 0.156.1; using the app's unrelated 0.1.0 marketing
    // version causes the server to validly return an empty catalog.
    private static let codexProtocolVersion = "0.156.1"

    private var availableCodexModels: [AIModelDef] {
        discoveredCodexModels.isEmpty ? Self.codexModels : discoveredCodexModels
    }

    static let builtIns: [AIProvider] = [
        AIProvider(id: "anthropic", name: "Anthropic",
                   baseUrl: "https://api.anthropic.com", api: .anthropicMessages,
                   models: [
                       AIModelDef(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5"),
                       AIModelDef(id: "claude-opus-4-5", name: "Claude Opus 4.5"),
                       AIModelDef(id: "claude-haiku-4-5", name: "Claude Haiku 4.5"),
                   ]),
        AIProvider(id: "openai", name: "OpenAI",
                   baseUrl: "https://api.openai.com/v1", api: .openaiCompletions,
                   models: [
                       AIModelDef(id: "gpt-5", name: "GPT-5"),
                       AIModelDef(id: "gpt-5-mini", name: "GPT-5 Mini"),
                       AIModelDef(id: "gpt-4.1", name: "GPT-4.1"),
                   ]),
        AIProvider(id: "custom", name: "Custom (OpenAI-compatible)",
                   baseUrl: "", api: .openaiCompletions, models: []),
    ]

    // MARK: Providers

    func addProvider(_ provider: AIProvider) {
        providers.append(provider)
    }

    func updateProvider(_ provider: AIProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        if provider.id == activeProviderID,
           !provider.models.contains(where: { $0.id == activeModelID }) {
            activeModelID = provider.models.first?.id ?? activeModelID
        }
    }

    func deleteProvider(id: String) {
        providers.removeAll { $0.id == id }
        deleteCredential(for: id)
        if activeProviderID == id {
            activeProviderID = providers.first?.id
            activeModelID = providers.first?.models.first?.id
        }
    }

    func setActiveProvider(_ id: String) {
        activeProviderID = id
        if let provider = providers.first(where: { $0.id == id }) {
            let models = availableModels(for: provider)
            if !models.contains(where: { $0.id == activeModelID }) {
                activeModelID = models.first?.id ?? activeModelID
            }
        }
    }

    /// ChatGPT OAuth exposes the Codex catalog. OpenAI API keys and custom
    /// endpoints continue to use the models configured on the provider.
    func availableModels(for provider: AIProvider) -> [AIModelDef] {
        if provider.id == "openai", case .oauth? = credential(for: provider.id) {
            return availableCodexModels
        }
        return provider.models
    }

    /// Fetch the picker-visible model catalog for the signed-in ChatGPT
    /// account. A refresh failure deliberately leaves the cached/bundled list
    /// intact and never invalidates a successful OAuth login.
    @discardableResult
    func refreshCodexModels() async throws -> [AIModelDef] {
        guard case .oauth(let access, _, _, let storedAccountID) = try await validCredential(for: "openai") else {
            throw ProviderError.notAuthenticated
        }

        let accountID = storedAccountID ?? Self.codexAccountID(fromJWT: access)
        var components = URLComponents(string: "https://chatgpt.com/backend-api/codex/models")!
        components.queryItems = [
            URLQueryItem(name: "client_version", value: Self.codexProtocolVersion),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.httpMethod = "GET"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue("pi-mobile", forHTTPHeaderField: "originator")
        request.setValue("pi-mobile/\(Self.clientVersion) codex/\(Self.codexProtocolVersion) (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        isRefreshingCodexModels = true
        codexModelsRefreshError = nil
        defer { isRefreshingCodexModels = false }

        do {
#if DEBUG
            Self.writeLog("GET chatgpt.com/backend-api/codex/models")
#endif
            let (data, urlResponse) = try await HTTPRetry.data(for: request)
            let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? -1
#if DEBUG
            Self.writeLog("models status=\(status) bytes=\(data.count)")
#endif
            guard (200..<300).contains(status) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw OAuthError.http(status, String(body.prefix(500)))
            }

            let response = try JSONDecoder().decode(CodexModelsResponse.self, from: data)
            let models = response.models
                .filter { $0.visibility == "list" }
                .sorted { lhs, rhs in
                    if lhs.priority == rhs.priority { return lhs.slug < rhs.slug }
                    return lhs.priority < rhs.priority
                }
                .map { AIModelDef(id: $0.slug, name: $0.displayName.isEmpty ? $0.slug : $0.displayName) }

            guard !models.isEmpty else {
                throw OAuthError.malformedResponse("model catalog contained no picker-visible models")
            }

            let now = Date()
            discoveredCodexModels = models
            discoveredCodexAccountID = accountID
            codexModelsLastUpdated = now
            let cache = CodexModelsCache(accountID: accountID, models: models, updatedAt: now)
            if let cacheData = try? JSONEncoder().encode(cache) {
                UserDefaults.standard.set(cacheData, forKey: Self.codexModelsCacheKey)
            }
            if activeProviderID == "openai",
               !models.contains(where: { $0.id == activeModelID }) {
                activeModelID = models.first?.id
            }
            return models
        } catch {
            codexModelsRefreshError = error.localizedDescription
#if DEBUG
            Self.writeLog("models refresh failed: \(String(reflecting: error))")
#endif
            throw error
        }
    }

    // MARK: Credentials (Keychain)

    func credential(for providerID: String) -> AICredential? {
        Self.loadCredential(for: providerID)
    }

    private static func loadCredential(for providerID: String) -> AICredential? {
        if let json = KeychainHelper.get(providerID),
           let data = json.data(using: .utf8),
           let credential = try? JSONDecoder().decode(AICredential.self, from: data) {
            return credential
        }
        // Fallback for unsigned simulator builds where the Keychain is unavailable.
        if let data = UserDefaults.standard.data(forKey: "credential.\(providerID)"),
           let credential = try? JSONDecoder().decode(AICredential.self, from: data) {
            return credential
        }
        return nil
    }

    func setCredential(_ credential: AICredential, for providerID: String) {
        if providerID == "openai", case .oauth(_, _, _, let accountID) = credential,
           discoveredCodexAccountID != accountID {
            discoveredCodexModels = []
            discoveredCodexAccountID = accountID
            codexModelsLastUpdated = nil
            UserDefaults.standard.removeObject(forKey: Self.codexModelsCacheKey)
        }
        if let data = try? JSONEncoder().encode(credential),
           let json = String(data: data, encoding: .utf8) {
            if KeychainHelper.set(json, for: providerID) != errSecSuccess {
                UserDefaults.standard.set(data, forKey: "credential.\(providerID)")
            } else {
                UserDefaults.standard.removeObject(forKey: "credential.\(providerID)")
            }
        }
        if providerID == "openai", case .oauth = credential,
           activeProviderID == providerID,
           !availableCodexModels.contains(where: { $0.id == activeModelID }) {
            activeModelID = availableCodexModels.first?.id ?? Self.defaultCodexModelID
        }
        credentialVersion += 1
    }

    func deleteCredential(for providerID: String) {
        KeychainHelper.delete(providerID)
        UserDefaults.standard.removeObject(forKey: "credential.\(providerID)")
        if providerID == "openai" {
            discoveredCodexModels = []
            discoveredCodexAccountID = nil
            codexModelsLastUpdated = nil
            codexModelsRefreshError = nil
            UserDefaults.standard.removeObject(forKey: Self.codexModelsCacheKey)
        }
        credentialVersion += 1
    }

    func isAuthenticated(provider: AIProvider) -> Bool {
        credential(for: provider.id) != nil
    }

    /// Returns a usable credential, refreshing OAuth tokens that expire within 5 minutes.
    func validCredential(for providerID: String) async throws -> AICredential {
        guard let credential = credential(for: providerID) else {
            throw ProviderError.notAuthenticated
        }
        guard case .oauth = credential else { return credential }
        let api = providers.first { $0.id == providerID }?.api
        let renewed = try await oauth.refreshIfNeeded(credential, providerID: providerID, api: api)
        if renewed != credential {
            setCredential(renewed, for: providerID)
        }
        return renewed
    }

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: "aiProviders")
        }
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
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

    private static func writeLog(_ message: String) {
#if DEBUG
        FileHandle.standardError.write(Data("[PiMobile][Models] \(message)\n".utf8))
#endif
    }
}

private struct CodexModelsCache: Codable {
    let accountID: String?
    let models: [AIModelDef]
    let updatedAt: Date
}

private struct CodexModelsResponse: Decodable {
    let models: [CodexModelRecord]
}

private struct CodexModelRecord: Decodable {
    let slug: String
    let displayName: String
    let visibility: String
    let priority: Int

    private enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case visibility
        case priority
    }
}
