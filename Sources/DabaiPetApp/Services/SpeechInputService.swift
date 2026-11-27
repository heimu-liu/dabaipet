import AVFoundation
import Foundation

@MainActor protocol SpeechPCMDecoder: AnyObject {
    func run(_ input: SpeechPCM, ready: @MainActor () throws -> Void,
             partial: @escaping @MainActor (String) -> Void) async throws -> String
    func cancel()
    func awaitUtterance()
}

extension SpeechPCMDecoder {
    func awaitUtterance() {}
}

@MainActor final class SpeechInputService: ConversationalVoiceInput {
    private typealias Failure = VoicePermissionCoordinator.Failure
    private let makeCapture: @MainActor () -> any SpeechPCMCapture
    private let makeDecoder: @MainActor (VoicePermissionCoordinator.Route) -> any SpeechPCMDecoder
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleepUntil: @MainActor (ContinuousClock.Instant) async throws -> Void

    private var id: UUID?
    private var capture: (any SpeechPCMCapture)?
    private var decoder: (any SpeechPCMDecoder)?
    private var sink: SpeechPCM.Continuation?
    private var work: Task<Void, Never>?
    private var cutoff: Task<Void, Never>?
    private var quiet: Task<Void, Never>?
    private var completion: VoiceInputSessionCompletion?
    private var intentDeadline: ContinuousClock.Instant?
    private var quietDeadline: ContinuousClock.Instant?
    private var captureChanged: (@MainActor (Bool) -> Void)?
    private var text = ""
    private var finishing = false
    private var capturing = false
    private var conversationTurn = false
    private var acousticInput: SpeechPCM.Continuation?
    private var relay: Task<Void, Never>?

    func awaitUtterance() { conversationTurn = true }

    init(makeCapture: @escaping @MainActor () -> any SpeechPCMCapture = { MicrophoneCapture() },
         makeDecoder: @escaping @MainActor (VoicePermissionCoordinator.Route) -> any SpeechPCMDecoder = { route in
             switch route {
             case .analyzer(let locale): return AnalyzerPCMDecoder(locale: locale)
             case .legacy(let locale): return LegacyPCMDecoder(locale: locale)
             }
         }, now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         sleepUntil: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0, tolerance: .zero)
         }) {
        self.makeCapture = makeCapture
        self.makeDecoder = makeDecoder
        self.now = now
        self.sleepUntil = sleepUntil
    }

    func configure(deadline: ContinuousClock.Instant, captureChanged: @escaping @MainActor (Bool) -> Void) {
        intentDeadline = deadline
        self.captureChanged = captureChanged
    }

    func start(route: VoicePermissionCoordinator.Route, completion: @escaping VoiceInputSessionCompletion) throws {
        guard id == nil else { throw Failure.captureFailed }
        let token = UUID()
        id = token
        self.completion = completion
        let recognizer = makeDecoder(route)
        if conversationTurn { recognizer.awaitUtterance() }
        decoder = recognizer
        let (input, writer) = SpeechPCM.makeStream(bufferingPolicy: .bufferingOldest(32))
        sink = writer
        let maximum = now().advanced(by: VoiceInputLimits.maximumDuration)
        let deadline = min(intentDeadline ?? maximum, maximum)
        let preparationFailure: Failure = conversationTurn ? .captureFailed : .noSpeech
        cutoff = alarm(at: deadline, id: token) { $0.finish(preparationOutcome: preparationFailure) }
        work = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let final = try await recognizer.run(input, ready: { [weak self] in
                    guard let self, id == token, !finishing else { throw CancellationError() }
                    guard now() < deadline else { throw preparationFailure }
                    let source = makeCapture()
                    capture = source
                    capturing = true
                    let destination: SpeechPCM.Continuation
                    if conversationTurn {
                        cutoff?.cancel() // The deadline bounds preparation only.
                        destination = observeAudio(for: token, forwardingTo: writer)
                    } else { destination = writer }
                    try source.start(into: destination) { [weak self] in
                        guard let self, capturing, id == token else { return }
                        complete(.failure(.noInput), id: token)
                    }
                    guard id == token, capturing else { throw CancellationError() }
                    captureChanged?(true)
                    if !conversationTurn { resetQuiet(id: token) }
                }, partial: { [weak self] value in
                    guard let self, id == token else { return }
                    if !conversationTurn, capturing, now() >= min(quietDeadline ?? deadline, deadline) { finish(preparationOutcome: .noSpeech) }
                    let revised = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text != revised else { return }
                    text = revised
                    if capturing && (!conversationTurn || !revised.isEmpty) { resetQuiet(id: token) }
                })
                self?.submit(final, id: token)
            } catch { self?.complete(.failure(.recognition(error)), id: token) }
        }
    }

    private func alarm(at deadline: ContinuousClock.Instant, id token: UUID,
                       perform: @escaping @MainActor (SpeechInputService) -> Void) -> Task<Void, Never> {
        let sleep = sleepUntil
        return Task { [weak self] in
            do { try await sleep(deadline); try Task.checkCancellation() } catch { return }
            guard let self, id == token else { return }
            perform(self)
        }
    }

    // Owned tap buffers are inspected off the realtime thread. A bounded relay preserves
    // packet order and drains the last packets into the recognizer before ending its input.
    private func observeAudio(for token: UUID, forwardingTo writer: SpeechPCM.Continuation) -> SpeechPCM.Continuation {
        let (audio, source) = SpeechPCM.makeStream(bufferingPolicy: .bufferingOldest(32))
        acousticInput = source
        relay = Task { [weak self] in
            do {
                for try await packet in audio {
                    try Task.checkCancellation()
                    guard let self, id == token else { break }
                    if capturing, Self.hasVoiceLevel(packet.buffer) { resetQuiet(id: token) }
                    if case .dropped = writer.yield(packet) { throw Failure.captureFailed }
                }
                writer.finish()
            } catch { writer.finish(throwing: error) }
        }
        return source
    }

    // RMS above about -42 dBFS extends the utterance even when native text revisions lag.
    static func hasVoiceLevel(_ buffer: AVAudioPCMBuffer) -> Bool {
        func exceedsFloor<T>(_ values: UnsafeBufferPointer<T>, fullScale: Double, sample: (T) -> Double) -> Bool {
            var energy = 0.0
            for value in values {
                let amplitude = sample(value)
                energy += amplitude * amplitude
            }
            return energy > Double(values.count) * fullScale * fullScale * 0.000064
        }
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            let bytes = UnsafeRawBufferPointer(start: channel.mData, count: Int(channel.mDataByteSize))
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32: if exceedsFloor(bytes.bindMemory(to: Float.self), fullScale: 1, sample: Double.init) { return true }
            case .pcmFormatFloat64: if exceedsFloor(bytes.bindMemory(to: Double.self), fullScale: 1, sample: { $0 }) { return true }
            case .pcmFormatInt16: if exceedsFloor(bytes.bindMemory(to: Int16.self), fullScale: 32768, sample: Double.init) { return true }
            case .pcmFormatInt32: if exceedsFloor(bytes.bindMemory(to: Int32.self), fullScale: 2147483648, sample: Double.init) { return true }
            default: break
            }
        }
        return false
    }

    private func resetQuiet(id token: UUID) {
        quietDeadline = now().advanced(by: .milliseconds(2500))
        guard quiet == nil else { return }
        let sleep = sleepUntil
        quiet = Task { [weak self] in
            while let deadline = self?.quietDeadline {
                do { try await sleep(deadline); try Task.checkCancellation() } catch { return }
                guard let self, id == token, capturing else { return }
                if let latest = quietDeadline, now() >= latest {
                    finish(preparationOutcome: .noSpeech)
                    return
                }
            }
        }
    }

    func finish() { finish(preparationOutcome: .cancelled) }

    private func finish(preparationOutcome: Failure) {
        guard let token = id, !finishing else { return }
        finishing = true
        let wasCapturing = capturing
        releaseCapture()
        captureChanged?(false)
        cutoff?.cancel()
        guard wasCapturing else { complete(.failure(preparationOutcome), id: token); return }
        // The device is already free. Allow a bounded interval for a recognition final.
        if conversationTurn {
            // Only a final transcript can become a conversation turn or a local stop command.
            cutoff = alarm(at: now().advanced(by: .seconds(6)), id: token) { $0.complete(.failure(.unconfirmedTranscript), id: token) }
        } else {
            cutoff = alarm(at: now().advanced(by: .seconds(2)), id: token) { $0.submit($0.text, id: token) }
        }
    }

    private func releaseCapture() {
        capturing = false
        quiet?.cancel()
        quiet = nil
        quietDeadline = nil
        let source = capture
        capture = nil
        source?.stop()
        if let acousticInput {
            acousticInput.finish()
            self.acousticInput = nil
        } else { sink?.finish() }
        sink = nil
    }

    private func submit(_ result: String, id token: UUID) {
        let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
        complete(value.isEmpty ? .failure(.noSpeech) : .success(value), id: token)
    }

    private func complete(_ result: Result<String, Failure>, id token: UUID) {
        guard id == token else { return }
        let notify = completion
        // Some recognizers finish a partial-only turn with an empty final or native no-speech.
        let partialOnly = conversationTurn && result == .failure(.noSpeech) && !text.isEmpty
        stop()
        notify?(partialOnly ? .failure(.unconfirmedTranscript) : result)
    }

    func stop() {
        id = nil
        completion = nil
        intentDeadline = nil
        captureChanged = nil
        releaseCapture()
        cutoff?.cancel()
        cutoff = nil
        work?.cancel()
        work = nil
        decoder?.cancel()
        decoder = nil
        finishing = false
        text = ""
        relay?.cancel()
        relay = nil
        conversationTurn = false
    }
}
