import DabaiPetCore
import DabaiPetUI

extension SettingsView.ConnectionActions {
    @MainActor
    static func configured(store: any SecretStore, transport: any LLMTransport = URLSessionLLMTransport()) -> Self {
        let connections = ConnectionServices(store: store)
        let client = LLMClient(transport: transport, apiKey: connections.key(for:))
        return .init(saveKey: { config, key in try await connections.save(key: key, config: config) },
                     test: { config in try await client.testConnection(config: config) })
    }
}
