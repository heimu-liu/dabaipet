import DabaiPetCore
import Foundation
import Testing

@Suite struct ChatMessageTests {
    private let userA = ChatMessage(role: .user, content: "你好")
    private let assistantA = ChatMessage(role: .assistant, content: "你好，我是大白。")
    private let userB = ChatMessage(role: .user, content: "我有点累")
    private let assistantB = ChatMessage(role: .assistant, content: "休息一下吧。")

    @Test func encodingSupportsTheTwoConversationRolesAndPreservesContent() throws {
        for message in [userA, assistantA] {
            let encoded = try JSONEncoder().encode(message)
            let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
            #expect(wire == ["role": message.role == .user ? "user" : "assistant", "content": message.content])
            #expect(try JSONDecoder().decode(ChatMessage.self, from: encoded) == message)
        }
    }

    @Test func keepsMostRecentCompleteTurnsInChronologicalOrder() {
        let messages = [userA, assistantA, userB, assistantB]
        #expect(ChatMessage.recentHistory(messages, maxTurns: 1) == [userB, assistantB])
        #expect(ChatMessage.recentHistory(messages, maxTurns: 2) == messages)
        #expect(ChatMessage.recentHistory(messages, maxTurns: Int.max) == messages)
        #expect(ChatMessage.recentHistory(messages, maxTurns: 0).isEmpty)
        #expect(ChatMessage.recentHistory(messages, maxTurns: Int.min).isEmpty)
        #expect(ChatMessage.recentHistory([], maxTurns: 2).isEmpty)
    }

    @Test func limitIsChosenByTheCallerAcrossLongerHistory() {
        let messages = (0..<32).flatMap { index in
            [ChatMessage(role: .user, content: "提问 \(index)"),
             ChatMessage(role: .assistant, content: "回复 \(index)")]
        }
        #expect(ChatMessage.recentHistory(messages, maxTurns: 32) == messages)
        #expect(ChatMessage.recentHistory(messages, maxTurns: 20) == Array(messages.suffix(40)))
    }

    @Test func keepsOnlyAdjacentPairsWhenHistoryHasOrphanedMessages() {
        let orphanAssistant = ChatMessage(role: .assistant, content: "孤立回复")
        let orphanUser = ChatMessage(role: .user, content: "未回复的问题")
        let messages = [orphanAssistant, userA, assistantA, orphanAssistant, orphanUser,
                        userB, assistantB, orphanUser]
        #expect(ChatMessage.recentHistory(messages, maxTurns: 4) == [userA, assistantA, userB, assistantB])
        #expect(ChatMessage.recentHistory(messages, maxTurns: 1) == [userB, assistantB])
        #expect(ChatMessage.recentHistory([assistantA, assistantB, userA, userB], maxTurns: 4).isEmpty)
        #expect(ChatMessage.recentHistory([orphanUser], maxTurns: 4).isEmpty)
    }

    @Test func appendsCurrentInputAfterHistoryWithoutSpendingATurnOrDuplicatingTheTail() {
        let pending = ChatMessage(role: .user, content: "讲个故事吧")
        let prior = [userA, assistantA, userB, assistantB, pending]
        #expect(ChatMessage.requestMessages(history: prior, pendingUserInput: pending.content, maxHistoryTurns: 1)
                == [userB, assistantB, pending])
        #expect(ChatMessage.requestMessages(history: prior, pendingUserInput: pending.content, maxHistoryTurns: 0)
                == [pending])
        #expect(ChatMessage.requestMessages(history: [], pendingUserInput: pending.content, maxHistoryTurns: 4)
                == [pending])
    }
}
