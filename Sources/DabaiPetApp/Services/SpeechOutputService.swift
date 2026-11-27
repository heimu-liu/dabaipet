import AVFAudio
import Foundation

/// Owns at most one native utterance, with no audio resources before playback.
@MainActor
final class SpeechOutputService: PetSession {
    enum End: Equatable, Sendable {
        case finished
        case cancelled
    }

    private struct Playback {
        let id: UUID
        let synthesizer: AVSpeechSynthesizer
        let delegate: PlaybackDelegate
        let onEnd: @MainActor (End) -> Void
    }

    private let makeSynthesizer: () -> AVSpeechSynthesizer
    private let chooseVoice: () -> AVSpeechSynthesisVoice?
    private var playback: Playback?

    init(makeSynthesizer: @escaping @MainActor () -> AVSpeechSynthesizer = { AVSpeechSynthesizer() },
         chooseVoice: @escaping @MainActor () -> AVSpeechSynthesisVoice? = {
             mandarinVoice(available: AVSpeechSynthesisVoice.speechVoices())
         }) {
        self.makeSynthesizer = makeSynthesizer
        self.chooseVoice = chooseVoice
    }

    static func mandarinVoice(
        available: [AVSpeechSynthesisVoice],
        fallback: () -> AVSpeechSynthesisVoice? = { AVSpeechSynthesisVoice(language: "zh-CN") }
    ) -> AVSpeechSynthesisVoice? {
        let preferred = available.filter {
            $0.language == "zh-CN" && $0.identifier.hasPrefix("com.apple.voice.") && $0.identifier.hasSuffix(".Tingting")
        }.max { $0.quality.rawValue < $1.quality.rawValue }
        return preferred ?? fallback()
    }

    /// Replaces current speech when accepted. The completion belongs to this utterance alone.
    func speak(_ text: String, onEnd: @escaping @MainActor (End) -> Void) -> Bool {
        guard text.contains(where: { !$0.isWhitespace }), let voice = chooseVoice() else { return false }
        stop()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9

        let id = UUID()
        let delegate = PlaybackDelegate { [weak self] end in self?.finish(id, end: end) }
        let synthesizer = makeSynthesizer()
        playback = Playback(id: id, synthesizer: synthesizer, delegate: delegate, onEnd: onEnd)
        synthesizer.delegate = delegate
        synthesizer.speak(utterance)
        return true
    }

    /// Owner-driven stops are synchronous and leave state transitions to the owner.
    func stop() {
        guard let playback else { return }
        self.playback = nil
        playback.synthesizer.delegate = nil
        playback.synthesizer.stopSpeaking(at: .immediate)
    }

    private func finish(_ id: UUID, end: End) {
        guard let playback, playback.id == id else { return }
        self.playback = nil
        playback.synthesizer.delegate = nil
        playback.onEnd(end)
    }

    // A delegate is scoped to a single synthesizer and utterance. Only the result
    // crosses to the main actor, so delayed callbacks cannot identify new speech.
    private final class PlaybackDelegate: NSObject, AVSpeechSynthesizerDelegate {
        let onEnd: @MainActor @Sendable (End) -> Void

        init(onEnd: @escaping @MainActor @Sendable (End) -> Void) {
            self.onEnd = onEnd
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor [onEnd] in onEnd(.finished) }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor [onEnd] in onEnd(.cancelled) }
        }
    }
}
