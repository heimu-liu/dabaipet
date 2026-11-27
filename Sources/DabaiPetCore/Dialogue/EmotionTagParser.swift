import Foundation

public enum EmotionTagParser {
    public struct Result: Equatable, Sendable {
        public let text: String
        /// The first recognized tag, including explicit `neutral`, or nil if none was found.
        public let emotion: PetEmotion?
    }

    private static let brackets: [Character: Character] = ["[": "]", "［": "］", "【": "】"]
    private static let chineseLabels: [String: PetEmotion] = [
        "中性": .neutral, "平静": .neutral, "开心": .happy,
        "关心": .care, "关怀": .care, "眩晕": .dizzy, "头晕": .dizzy,
        "困倦": .sleepy, "兴奋": .excited,
    ]
    private static let labelLocale = Locale(identifier: "en_US_POSIX")

    /// Removes recognized emotion markers and their immediately enclosing `**` pairs.
    /// All text outside those markers is returned verbatim.
    public static func parse(_ text: String) -> Result {
        var opening: (index: String.Index, close: Character)?
        var keptFrom = text.startIndex
        var cleaned = ""
        var firstEmotion: PetEmotion?

        for index in text.indices {
            let character = text[index]
            if let close = brackets[character] {
                opening = (index, close)
                continue
            }
            guard let tag = opening, character == tag.close else { continue }
            opening = nil

            let label = text[text.index(after: tag.index)..<index]
                .trimmingCharacters(in: .whitespaces)
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: labelLocale)
            guard let emotion = PetEmotion(rawValue: label) ?? chineseLabels[label] else { continue }

            var start = tag.index
            var end = text.index(after: index)
            if text[keptFrom..<start].hasSuffix("**"), text[end...].hasPrefix("**") {
                start = text.index(start, offsetBy: -2)
                end = text.index(end, offsetBy: 2)
            }
            cleaned.append(contentsOf: text[keptFrom..<start])
            keptFrom = end
            firstEmotion = firstEmotion ?? emotion
        }

        guard let firstEmotion else { return Result(text: text, emotion: nil) }
        cleaned.append(contentsOf: text[keptFrom...])
        return Result(text: cleaned, emotion: firstEmotion)
    }
}
