import DabaiPetCore
import Foundation
import Testing

private actor CredentialTransport: LLMTransport {
    var auth: [String?] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        auth.append(request.value(forHTTPHeaderField: "Authorization"))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"data":[]}"#.utf8), response)
    }
}

struct ConnectionServicesTests {
    private func config(_ url: String, _ provider: LLMProvider = .openAICompatible) -> LLMConfig {
        .init(provider: provider, baseURL: URL(string: url)!, model: "fixture")
    }

    @Test func endpointScopedWireCredentials() async throws {
        let store = InMemorySecretStore()
        let service = ConnectionServices(store: store)
        let wire = CredentialTransport()
        let client = LLMClient(transport: wire, apiKey: service.key(for:))
        let original = config("https://sample.invalid/proxy/v1/")
        try await service.save(key: "fixture-A", config: original)
        try await client.testConnection(config: config("https://SAMPLE.invalid:443/proxy"))
        #expect(await wire.auth == ["Bearer fixture-A"])

        let others = [config("http://sample.invalid/proxy"), config("https://sample.invalid:8443/proxy"),
                      config("https://sample.invalid/Proxy"), config("https://different.invalid/proxy"),
                      config("https://sample.invalid/proxy", .anthropic)]
        for selection in others {
            await #expect(throws: LLMClientError.missingAPIKey) { try await client.testConnection(config: selection) }
        }
        #expect(await wire.auth.count == 1)
        try await service.save(key: "fixture-B", config: others[0])
        try await client.testConnection(config: others[0])
        try await client.testConnection(config: config("http://localhost:11434/v1"))
        #expect(await wire.auth == ["Bearer fixture-A", "Bearer fixture-B", nil])
        #expect(try await service.key(for: original) == "fixture-A")
    }
}
