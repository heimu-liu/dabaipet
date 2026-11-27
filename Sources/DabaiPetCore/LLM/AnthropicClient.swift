import Foundation

struct AnthropicClient: LLMWireFormat {
    let replyPath = "messages"

    func authenticate(_ request: inout URLRequest, key: String?) throws {
        guard let key else { throw LLMClientError.missingAPIKey }
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    func body(model: String, system: String, messages: [ChatMessage], maxTokens: Int) throws -> Data {
        struct Body: Encodable {
            let model: String
            let system: String?
            let messages: [ChatMessage]
            let max_tokens: Int
            let stream = false
        }
        return try JSONEncoder().encode(Body(model: model, system: system.isEmpty ? nil : system,
                                             messages: messages, max_tokens: maxTokens))
    }

    func text(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let type: String
            let role: ChatMessage.Role
            let content: [Block]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.type == "message", response.role == .assistant else { throw LLMClientError.invalidResponse }
        return try response.content.filter { $0.type == "text" }.map {
            guard let text = $0.text else { throw LLMClientError.invalidResponse }
            return text
        }.joined(separator: "\n")
    }
}
