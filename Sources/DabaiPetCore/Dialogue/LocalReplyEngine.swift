/// Deterministic replies available in local mode without configuration.
public enum LocalReplyEngine {
    public struct Reply: Equatable, Sendable {
        public let message: ChatMessage
        public let emotion: PetEmotion
    }

    private static let responses: [(keyword: String, reply: Reply)] = [
        ("有点累", Reply(message: .init(role: .assistant, content: "感觉你有点累了，先歇一会儿、喝口水吧。我会一直陪着你。"),
                        emotion: .care)),
        ("巴拉拉拉", Reply(message: .init(role: .assistant, content: "巴拉拉拉～心情变晴朗了一点吧？我随时都在。"),
                         emotion: .happy)),
        ("你好", Reply(message: .init(role: .assistant, content: "你好，我是大白。今天想聊点什么？"),
                       emotion: .happy)),
    ]

    private static let fallback = Reply(
        message: .init(role: .assistant, content: "我在这儿安静陪着你。累了或者想打招呼时，随时叫我就好。"),
        emotion: .neutral
    )

    /// Returns the first matching reply in priority order: fatigue, catchphrase, greeting.
    public static func reply(to input: String) -> Reply {
        responses.first { input.contains($0.keyword) }?.reply ?? fallback
    }
}
