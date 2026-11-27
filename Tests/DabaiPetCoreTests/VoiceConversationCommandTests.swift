import DabaiPetCore
import Testing

@Suite struct VoiceConversationCommandTests {
    @Test(arguments: [
        "拜拜", "大白拜拜", "拜拜大白",
        "大白，拜拜！", "拜拜，大白。", "大白、拜拜", "大白。\n拜拜。",
        "拜拜，", "大白, 拜拜!", "拜拜。。。",
        "　大 白 ， 拜 拜！\n", "\t拜拜\u{00A0}大白。",
    ])
    func acceptsOnlyClearFarewellsWithNaturalFormatting(_ text: String) {
        #expect(VoiceConversationCommand.isGoodbye(text))
    }

    @Test(arguments: [
        "", "　\n", "，！。", "拜拜是什么意思", "我还没说拜拜", "他说了拜拜",
        "“拜拜”", "他说：大白拜拜", "我没说，大白拜拜。", "「大白，拜拜」",
        "拜拜？", "拜拜?", "大白，拜拜吗？", "大白？拜拜。", "拜拜啊？",
        "先别拜拜", "等一下再拜拜", "大白拜拜，下次见", "再见", "拜拜了",
        "大白拜，拜", "拜，拜", "拜拜拜拜", "Bye bye", "拜拜👋",
    ])
    func leavesMentionedNegatedQuestionedAndExtendedTextInConversation(_ text: String) {
        #expect(!VoiceConversationCommand.isGoodbye(text))
    }
}
