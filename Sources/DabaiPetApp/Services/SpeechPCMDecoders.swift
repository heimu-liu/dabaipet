import AVFoundation
import CoreMedia
import Speech
import Synchronization

@MainActor final class LegacyPCMDecoder: SpeechPCMDecoder {
    private let locale: Locale
    private var continueAfterSegment = false
    func awaitUtterance() { continueAfterSegment = true }
    private var segmented: LegacyConversationRecognition?
    private var recognition: SFSpeechRecognitionTask?
    private var feeder: Task<Void, Never>?
    private var endEvents: (() -> Void)?

    init(locale: Locale) { self.locale = locale }

    func run(_ input: SpeechPCM, ready: @MainActor () throws -> Void,
             partial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw VoicePermissionCoordinator.Failure.noRecognizer }
        if continueAfterSegment {
            let session = LegacyConversationRecognition(recognizer)
            segmented = session
            defer { session.cancel(); segmented = nil }
            return try await session.run(input, ready: ready, partial: partial)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let (events, sink) = AsyncThrowingStream<(String, Bool), any Error>.makeStream()
        endEvents = { sink.finish() }
        defer { cancel() }
        recognition = recognizer.recognitionTask(with: request) { @Sendable result, error in
            if let result {
                sink.yield((result.bestTranscription.formattedString, result.isFinal))
                if result.isFinal { sink.finish(); return }
            }
            if let error { sink.finish(throwing: error) }
        }
        try Task.checkCancellation()
        try ready()
        feeder = Task {
            do {
                for try await packet in input {
                    try Task.checkCancellation()
                    request.append(packet.buffer)
                }
                if !Task.isCancelled { request.endAudio() }
            } catch { sink.finish(throwing: error) }
        }
        for try await (text, final) in events {
            try Task.checkCancellation()
            if final { return text }
            partial(text)
        }
        throw CancellationError()
    }

    func cancel() {
        segmented?.cancel()
        feeder?.cancel()
        feeder = nil
        endEvents?()
        endEvents = nil
        recognition?.cancel()
        recognition = nil
    }
}

/// A transcriber may replace a volatile time range or finalize it more than once.
struct SpeechSegments {
    private var segments: [(range: CMTimeRange, text: String, final: Bool)] = []
    func transcript(requiringFinal: Bool) throws -> String {
        guard !requiringFinal || segments.allSatisfy(\.final) else {
            throw VoicePermissionCoordinator.Failure.unconfirmedTranscript
        }
        return segments.map(\.text).joined()
    }

    mutating func replace(_ range: CMTimeRange, with text: String, final: Bool = true) -> String {
        segments.removeAll { $0.range.start == range.start || !$0.range.intersection(range).isEmpty }
        segments.append((range, text, final))
        segments.sort { $0.range.start < $1.range.start }
        return segments.map(\.text).joined()
    }
}

@MainActor final class AnalyzerPCMDecoder: SpeechPCMDecoder {
    private let locale: Locale
    private var finalRequired = false
    func awaitUtterance() { finalRequired = true }
    private var analyzer: SpeechAnalyzer?
    private var feeder: Task<Void, Never>?
    private var analysis: Task<Void, Never>?
    private var endInputs: (() -> Void)?
    private var reader: Task<Void, Never>?

    init(locale: Locale) { self.locale = locale }

    func run(_ input: SpeechPCM, ready: @MainActor () throws -> Void,
             partial: @escaping @MainActor (String) -> Void) async throws -> String {
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw VoicePermissionCoordinator.Failure.noRecognizer
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        defer { cancel() }
        try await analyzer.prepareToAnalyze(in: target)
        try Task.checkCancellation()

        let (converted, writer) = SpeechPCM.makeStream(bufferingPolicy: .bufferingOldest(64))
        let (outcome, result) = AsyncThrowingStream<String, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        endInputs = { writer.finish(); result.finish() }
        let reading = Task {
            var segments = SpeechSegments()
            do {
                for try await item in module.results {
                    try Task.checkCancellation()
                    partial(segments.replace(item.range, with: String(item.text.characters), final: item.isFinal))
                }
                try Task.checkCancellation()
                result.yield(try segments.transcript(requiringFinal: finalRequired))
                result.finish()
            } catch { result.finish(throwing: error) }
        }
        reader = reading
        analysis = Task {
            do {
                let last = try await analyzer.analyzeSequence(converted)
                try Task.checkCancellation()
                if let last { try await analyzer.finalizeAndFinish(through: last) }
                else { result.finish(throwing: VoicePermissionCoordinator.Failure.noSpeech) }
            } catch { result.finish(throwing: error) }
        }
        try ready()
        feeder = Task {
            do { try await Self.convert(input, to: target, into: writer); writer.finish() }
            catch { writer.finish(throwing: error); result.finish(throwing: error) }
        }
        for try await text in outcome { return text }
        throw CancellationError()
    }

    func cancel() {
        endInputs?()
        endInputs = nil
        reader?.cancel()
        reader = nil
        feeder?.cancel()
        feeder = nil
        analysis?.cancel()
        analysis = nil
        if let analyzer {
            self.analyzer = nil
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    @concurrent private static func convert(_ input: SpeechPCM, to target: AVAudioFormat,
                                            into output: SpeechPCM.Continuation) async throws {
        var source: AVAudioFormat?
        var converter: AVAudioConverter?
        func send(_ packet: AnalyzerInput) throws {
            switch output.yield(packet) {
            case .enqueued: break
            case .terminated: throw CancellationError()
            default: throw VoicePermissionCoordinator.Failure.captureFailed
            }
        }
        for try await packet in input {
            try Task.checkCancellation()
            let format = packet.buffer.format
            guard MicrophoneCapture.valid(format), source == nil || source == format else {
                throw VoicePermissionCoordinator.Failure.noInput
            }
            if source == nil {
                source = format
                if format != target {
                    guard let resampler = AVAudioConverter(from: format, to: target) else {
                        throw VoicePermissionCoordinator.Failure.captureFailed
                    }
                    converter = resampler
                }
            }
            if let converter { try convertPacket(packet, using: converter, output: send) }
            else { try send(packet) }
        }
        if let converter {
            try Task.checkCancellation()
            try convertPacket(nil, using: converter, output: send)
        }
    }

    nonisolated private static func convertPacket(_ packet: AnalyzerInput?, using converter: AVAudioConverter,
                                                  output: (AnalyzerInput) throws -> Void) throws {
        let target = converter.outputFormat
        let frames = Double(packet?.buffer.frameLength ?? 1024)
        let capacity = ceil(frames * target.sampleRate / converter.inputFormat.sampleRate) + 128
        guard capacity.isFinite, capacity > 0, capacity < Double(UInt32.max) else {
            throw VoicePermissionCoordinator.Failure.captureFailed
        }
        let supplied = Mutex(false)
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: UInt32(capacity)) else {
                throw VoicePermissionCoordinator.Failure.captureFailed
            }
            var error: NSError?
            let state = converter.convert(to: buffer, error: &error) { _, status in
                guard let packet else { status.pointee = .endOfStream; return nil }
                let first = supplied.withLock { used in defer { used = true }; return !used }
                status.pointee = first ? .haveData : .noDataNow
                return first ? packet.buffer : nil
            }
            if let error { throw error }
            if state == .error { throw VoicePermissionCoordinator.Failure.captureFailed }
            if buffer.frameLength > 0 { try output(AnalyzerInput(buffer: buffer)) }
            if state != .haveData || buffer.frameLength == 0 { return }
        }
    }
}
