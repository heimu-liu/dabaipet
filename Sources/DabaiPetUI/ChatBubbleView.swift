import DabaiPetCore
import SwiftUI

public struct ChatBubbleView: View {
    @Observable @MainActor
    public final class Transcript {
        public var messages: [ChatMessage] = []

        public init() {}
    }

    private enum Anchor: Hashable { case latest }

    private let transcript: Transcript

    public init(transcript: Transcript) {
        self.transcript = transcript
    }

    public var body: some View {
        let messages = transcript.messages
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        ForEach(messages.indices, id: \.self) { index in
                            bubble(messages[index])
                        }
                    }
                    .padding(.vertical, 2)

                    Color.clear
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .id(Anchor.latest)
                }
            }
            .accessibilityLabel("聊天记录")
            .onChange(of: messages, initial: true) {
                proxy.scrollTo(Anchor.latest, anchor: .bottom)
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return Text(message.content)
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isUser ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .accessibilityLabel(Text(verbatim: "\(isUser ? "你" : "大白")：\(message.content)"))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .padding(isUser ? .leading : .trailing, 36)
    }
}
