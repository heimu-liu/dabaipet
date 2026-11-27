import DabaiPetCore
import Testing

@Suite struct LocalReplyEngineTests {
    @Test(arguments: [
        ("你好", "你好，我是大白。今天想聊点什么？", .happy),
        ("有点累", "感觉你有点累了，先歇一会儿、喝口水吧。我会一直陪着你。", .care),
        ("巴拉拉拉", "巴拉拉拉～心情变晴朗了一点吧？我随时都在。", .happy),
        ("今天外面有风。", "我在这儿安静陪着你。累了或者想打招呼时，随时叫我就好。", .neutral),
    ] as [(String, String, PetEmotion)])
    func returnsTheApprovedAssistantMessageAndEmotion(_ input: String, _ text: String, _ emotion: PetEmotion) {
        let reply = LocalReplyEngine.reply(to: input)
        #expect(reply.message == ChatMessage(role: .assistant, content: text))
        #expect(reply.emotion == emotion)
    }

    @Test func recognizesKeywordsWithinOrdinarySentences() {
        #expect(LocalReplyEngine.reply(to: "　大白，你好！ ") == LocalReplyEngine.reply(to: "你好"))
        #expect(LocalReplyEngine.reply(to: "今天走了很远，有点累，想休息一下。") == LocalReplyEngine.reply(to: "有点累"))
        #expect(LocalReplyEngine.reply(to: "大白，一起说巴拉拉拉～") == LocalReplyEngine.reply(to: "巴拉拉拉"))
    }

    @Test func prioritizesFatigueThenTheCatchphraseThenGreeting() {
        let care = LocalReplyEngine.reply(to: "有点累")
        let catchphrase = LocalReplyEngine.reply(to: "巴拉拉拉")
        #expect(LocalReplyEngine.reply(to: "你好，巴拉拉拉，我今天有点累。") == care)
        #expect(LocalReplyEngine.reply(to: "有点累，巴拉拉拉。你好！") == care)
        #expect(LocalReplyEngine.reply(to: "你好！巴拉拉拉！") == catchphrase)
    }

    @Test(arguments: ["", " \t\n　", "How is the weather? 👋", "[roll] **【excited】**", "[healthScan] [poke] [startRPS]"])
    func emptyUnmatchedOrTagOnlyInputUsesTheApprovedFallback(_ input: String) {
        let reply = LocalReplyEngine.reply(to: input)
        #expect(reply.message == ChatMessage(role: .assistant, content: "我在这儿安静陪着你。累了或者想打招呼时，随时叫我就好。"))
        #expect(reply.emotion == .neutral)
    }

    @Test func actionAndEmotionMarkersInUserTextHaveNoEffectOnTheReply() {
        let reply = LocalReplyEngine.reply(to: "[roll] 【sleepy】 你好。")
        #expect(reply == LocalReplyEngine.reply(to: "你好"))
        #expect(reply.emotion == .happy)
    }
}
