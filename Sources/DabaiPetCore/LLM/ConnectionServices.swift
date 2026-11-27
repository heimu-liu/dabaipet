import CryptoKit
import Foundation

extension LLMConfig {
    /// Exactly the base path used by both the wire client and credential lookup.
    func endpointComponents() throws -> URLComponents {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw LLMClientError.invalidConfiguration
        }
        parts.scheme = scheme
        parts.host = host
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        var prefix = parts.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if !prefix.hasSuffix("/v1") { prefix += "/v1" }
        parts.percentEncodedPath = prefix
        return parts
    }
}

public struct ConnectionServices: Sendable {
    public let store: any SecretStore
    public init(store: any SecretStore) { self.store = store }

    public static func account(for config: LLMConfig) throws -> String {
        guard config.provider != .local, let address = try config.endpointComponents().string else {
            throw LLMClientError.invalidConfiguration
        }
        let identity = Data((config.provider.rawValue + "\n" + address).utf8)
        return "endpoint-" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    public func save(key: String, config: LLMConfig) async throws {
        guard !key.isEmpty, key.utf8.count <= 16384,
              key.rangeOfCharacter(from: .controlCharacters) == nil else { throw LLMClientError.invalidConfiguration }
        try await store.save(key, account: Self.account(for: config))
    }

    public func key(for config: LLMConfig) async throws -> String? {
        if let key = try await store.read(account: Self.account(for: config)) { return key }
        if config.provider == .openAICompatible && config.baseURL.port == 11434 { return nil }
        throw LLMClientError.missingAPIKey
    }

    public var client: LLMClient { LLMClient(apiKey: key(for:)) }
}
