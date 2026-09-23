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
        if let provider = providers.first(where: { $0.id == id }),
           !provider.models.contains(where: { $0.id == activeModelID }) {
            activeModelID = provider.models.first?.id ?? activeModelID
        }
    }

    // MARK: Credentials (Keychain)

    func credential(for providerID: String) -> AICredential? {
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
        if let data = try? JSONEncoder().encode(credential),
           let json = String(data: data, encoding: .utf8) {
            if KeychainHelper.set(json, for: providerID) != errSecSuccess {
                UserDefaults.standard.set(data, forKey: "credential.\(providerID)")
            } else {
                UserDefaults.standard.removeObject(forKey: "credential.\(providerID)")
            }
        }
        credentialVersion += 1
    }

    func deleteCredential(for providerID: String) {
        KeychainHelper.delete(providerID)
        UserDefaults.standard.removeObject(forKey: "credential.\(providerID)")
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
}
