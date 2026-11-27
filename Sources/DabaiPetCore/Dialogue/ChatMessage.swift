/// A dialogue message shared by presentation and provider request code.
public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    /// Selects up to `maxTurns` recent adjacent user/assistant pairs in chronological order.
    /// Unpaired messages are skipped. A nonpositive limit produces empty history.
    public static func recentHistory(_ messages: [ChatMessage], maxTurns: Int) -> [ChatMessage] {
        var newestFirst: [ChatMessage] = []
        var index = messages.count - 1

        while index > 0, newestFirst.count / 2 < maxTurns {
            let assistant = messages[index]
            let user = messages[index - 1]
            index -= 1
            guard user.role == .user, assistant.role == .assistant else { continue }
            newestFirst.append(assistant)
            newestFirst.append(user)
            index -= 1
        }

        return Array(newestFirst.reversed())
    }

    /// Adds current input once after the complete history, outside the history turn budget.
    public static func requestMessages(history: [ChatMessage], pendingUserInput: String,
                                       maxHistoryTurns: Int) -> [ChatMessage] {
        var messages = recentHistory(history, maxTurns: maxHistoryTurns)
        messages.append(ChatMessage(role: .user, content: pendingUserInput))
        return messages
    }
}
