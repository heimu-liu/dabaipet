import DabaiPetCore
import Testing

@Suite struct EmotionTagParserTests {
    @Test(arguments: [
        ("[happy]你好", "你好", .happy),
        ("你好【Happy】", "你好", .happy),
        ("**[Happy]**你好", "你好", .happy),
        ("前面**【cArE】**后面", "前面后面", .care),
        ("前面［ＥＸＣＩＴＥＤ］后面", "前面后面", .excited),
        ("ok[  SlEePy\t]", "ok", .sleepy),
        ("［Dizzy］", "", .dizzy),
        ("【NEUTRAL】", "", .neutral),
        ("[中性]", "", .neutral),
        ("[平静]", "", .neutral),
        ("[开心]", "", .happy),
        ("【关心】", "", .care),
        ("［关怀］", "", .care),
        ("**[眩晕]**", "", .dizzy),
        ("[头晕]", "", .dizzy),
        ("【困倦】", "", .sleepy),
        ("［兴奋］", "", .excited),
    ] as [(String, String, PetEmotion)])
    func recognizesBilingualTagsAndRemovesTheirOwnWrappers(_ input: String, _ text: String, _ emotion: PetEmotion) {
        let reply = EmotionTagParser.parse(input)
        #expect(reply.text == text)
        #expect(reply.emotion == emotion)
    }

    @Test func stripsAllConsecutiveAndSeparatedTagsAndUsesFirstRecognizedEmotion() {
        let reply = EmotionTagParser.parse("[未知]【NEUTRAL】[开心]**[CARE]****［困倦］**打个招呼[兴奋]好呀【Dizzy】")
        #expect(reply.text == "[未知]打个招呼好呀")
        #expect(reply.emotion == .neutral)
    }

    @Test func preservesWhitespaceUnicodeAndOrdinaryFormattingAroundTags() {
        let input = "　**我在**[care]\n  Zoe\u{0308} 👋🏽 ［资料］ 【说明】\t[HAPPY]。 "
        let expected = "　**我在**\n  Zoe\u{0308} 👋🏽 ［资料］ 【说明】\t。 "
        let reply = EmotionTagParser.parse(input)
        #expect(Array(reply.text.utf8) == Array(expected.utf8))
        #expect(reply.emotion == .care)
    }

    @Test(arguments: [
        "", " \n　", "普通正文 See you 👋", "**这段强调**", "【未知】 **[Neutrality]** []", "[happy】［care]【sleepy］",
        "[happy", "dizzy]", "[\nHappy\n]", "[happy-ish]", "happy 开心 困倦（不带标签）",
    ])
    func leavesUnrecognizedTextVerbatim(_ input: String) {
        let reply = EmotionTagParser.parse(input)
        #expect(reply.text == input)
        #expect(reply.emotion == nil)
    }

    @Test(arguments: [PetAction.roll, .poke, .healthScan, .startRPS])
    func preservesActionWordsAsText(_ action: PetAction) {
        let literal = "[\(action.rawValue)] **【\(action.rawValue.uppercased())】**"
        let actionOnly = EmotionTagParser.parse(literal)
        #expect(actionOnly.text == literal)
        #expect(actionOnly.emotion == nil)

        let mixed = EmotionTagParser.parse("\(literal)［开心］！")
        #expect(mixed.text == "\(literal)！")
        #expect(mixed.emotion == .happy)
    }
}
