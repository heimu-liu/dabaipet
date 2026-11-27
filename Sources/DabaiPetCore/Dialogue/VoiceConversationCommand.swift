public enum VoiceConversationCommand {
    /// Recognizes a complete, explicit farewell from local speech recognition.
    public static func isGoodbye(_ text: String) -> Bool {
        // Questions and quotation marks remain part of the text and prevent a match.
        let punctuation = "，,、。.!！"
        let parts = text.filter { !$0.isWhitespace }.split { punctuation.contains($0) }
        switch parts {
        case ["拜拜"], ["大白拜拜"], ["拜拜大白"], ["大白", "拜拜"], ["拜拜", "大白"]:
            return true
        default:
            return false
        }
    }
}
