public protocol SecretStore: Sendable {
    func read(account: String) async throws -> String?
    func save(_ secret: String, account: String) async throws
    func delete(account: String) async throws
}

/// Ephemeral implementation for tests. Production storage is provided by the App target.
public actor InMemorySecretStore: SecretStore {
    private var secrets: [String: String] = [:]

    public init() {}

    public func read(account: String) -> String? { secrets[account] }

    public func save(_ secret: String, account: String) { secrets[account] = secret }

    public func delete(account: String) { secrets.removeValue(forKey: account) }
}
