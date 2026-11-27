import Foundation

struct OpenAICompatibleClient: LLMWireFormat {
    let replyPath = "chat/completions"

    func authenticate(_ request: inout URLRequest, key: String?) {
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
    }

    func body(model: String, system: String, messages: [ChatMessage], maxTokens: Int) throws -> Data {
        struct Message: Encodable { let role: String; let content: String }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let max_tokens: Int
            let stream = false
        }
        var wireMessages = messages.map { Message(role: $0.role.rawValue, content: $0.content) }
        if !system.isEmpty { wireMessages.insert(Message(role: "system", content: system), at: 0) }
        return try JSONEncoder().encode(Body(model: model, messages: wireMessages, max_tokens: maxTokens))
    }

    func text(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable { let message: ChatMessage }
            let choices: [Choice]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let message = response.choices.first?.message, message.role == .assistant else { throw LLMClientError.invalidResponse }
        return message.content
    }
}
