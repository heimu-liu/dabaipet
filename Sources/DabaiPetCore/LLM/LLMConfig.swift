import Foundation

public enum LLMProvider: String, Codable, Sendable {
    case local, openAICompatible, anthropic
}

public struct LLMConfig: Codable, Equatable, Sendable {
    public var provider: LLMProvider
    public var baseURL: URL
    public var model: String
    public var maxTokens: Int
    public var timeoutSeconds: TimeInterval

    public init(provider: LLMProvider, baseURL: URL, model: String, maxTokens: Int = 256,
                timeoutSeconds: TimeInterval = 20) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
    }
}
