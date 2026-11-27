import AVFoundation
import Speech
import Synchronization

/// Native request boundaries can fall inside one continuous utterance.
@MainActor
final class LegacyConversationRecognition {
    enum Update: Sendable {
        case transcript(String, final: Bool, endTime: Double?)
        case failure(any Error)
    }

    struct Request {
        var append: (AVAudioPCMBuffer) -> Void
        var end: () -> Void
        var cancel: () -> Void
    }

    typealias Open = (@escaping @Sendable (Update) -> Void) -> Request

    private struct Event: Sendable {
        let generation: UUID
        let afterEndAudio: Bool
        let update: Update
    }

    private let open: Open
    private let events = AsyncThrowingStream<Event, any Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
    private var feeder: Task<Void, Never>?
    private var request: Request?
    private var generation: UUID?
    private var tail = LegacySegmentTail()
    private var committed = ""
    private var inputEnded = false

    init(open: @escaping Open) { self.open = open }

    convenience init(_ recognizer: SFSpeechRecognizer) {
        self.init { notify in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result {
                    let transcript = result.bestTranscription
                    let last = transcript.segments.last
                    notify(.transcript(transcript.formattedString, final: result.isFinal,
                                       endTime: last.map { $0.timestamp + $0.duration }))
                    if result.isFinal { return }
                }
                if let error { notify(.failure(error)) }
            }
            return Request(append: { request.append($0) }, end: { request.endAudio() }, cancel: { task.cancel() })
        }
    }

    func run(_ input: SpeechPCM, ready: @MainActor () throws -> Void,
             partial: @escaping @MainActor (String) -> Void) async throws -> String {
        try ready()
        feeder = Task {
            do {
                for try await packet in input {
                    try Task.checkCancellation()
                    try feed(packet.buffer)
                }
                try Task.checkCancellation()
                inputEnded = true
                endRequest()
            } catch { events.continuation.finish(throwing: error) }
        }
        var sawPartialWords = false
        for try await event in events.stream {
            try Task.checkCancellation()
            guard event.generation == generation else { continue }
            switch event.update {
            case .failure(let error): throw error
            case let .transcript(text, final, end):
                if !final {
                    sawPartialWords = sawPartialWords || text.contains { !$0.isWhitespace }
                    partial(committed + text)
                    continue
                }
                // An empty final after provisional words cannot confirm a preceding segment as the entire turn.
                if sawPartialWords && !text.contains(where: { !$0.isWhitespace }) {
                    throw VoicePermissionCoordinator.Failure.unconfirmedTranscript
                }
                sawPartialWords = false
                committed += text
                if event.afterEndAudio { return committed }
                guard let end else { throw VoicePermissionCoordinator.Failure.captureFailed }
                let suffix = try tail.after(seconds: end)
                generation = nil
                request = nil
                tail = LegacySegmentTail()
                partial(committed)
                for buffer in suffix { try feed(buffer) }
                if inputEnded { endRequest() }
            }
        }
        try Task.checkCancellation()
        return committed
    }

    private func endRequest() {
        if let request { request.end() } else { events.continuation.finish() }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) throws {
        if let request {
            try tail.append(buffer, retaining: 6)
            request.append(buffer)
            return
        }
        // Long initial silence needs one mic capture and no native recognizer restarts.
        try tail.append(buffer, retaining: 0.4)
        guard SpeechInputService.hasVoiceLevel(buffer) else { return }
        let preroll = tail.buffers
        tail = LegacySegmentTail()
        let id = UUID()
        generation = id
        let sink = events.continuation
        let ended = Mutex(false)
        let native = open { update in
            sink.yield(Event(generation: id, afterEndAudio: ended.withLock { $0 }, update: update))
        }
        request = Request(append: native.append, end: {
            ended.withLock { $0 = true }
            native.end()
        }, cancel: native.cancel)
        for packet in preroll {
            try tail.append(packet, retaining: 6)
            native.append(packet)
        }
    }

    func cancel() {
        generation = nil
        feeder?.cancel()
        request?.cancel()
        request = nil
        events.continuation.finish()
    }
}

/// Frame positions are relative to the current native request, including its preroll.
struct LegacySegmentTail {
    private(set) var buffers: [AVAudioPCMBuffer] = []
    private var endFrame: Int64 = 0
    private var firstFrame: Int64 = 0

    mutating func append(_ buffer: AVAudioPCMBuffer, retaining seconds: Double) throws {
        guard buffers.first.map({ $0.format == buffer.format }) ?? true else {
            throw VoicePermissionCoordinator.Failure.noInput
        }
        endFrame += Int64(buffer.frameLength)
        buffers.append(buffer)
        let cutoff = endFrame - Int64(seconds * buffer.format.sampleRate)
        while let first = buffers.first, firstFrame + Int64(first.frameLength) <= cutoff {
            firstFrame += Int64(first.frameLength)
            buffers.removeFirst()
        }
    }

    func after(seconds: Double) throws -> [AVAudioPCMBuffer] {
        guard let format = buffers.first?.format, seconds.isFinite, seconds > 0,
              seconds <= Double(endFrame + 1) / format.sampleRate else { throw VoicePermissionCoordinator.Failure.captureFailed }
        let cut = min(endFrame, Int64((seconds * format.sampleRate).rounded()))
        guard cut >= firstFrame else { throw VoicePermissionCoordinator.Failure.captureFailed }
        var position = firstFrame
        var suffix: [AVAudioPCMBuffer] = []
        for buffer in buffers {
            let next = position + Int64(buffer.frameLength)
            defer { position = next }
            guard next > cut else { continue }
            guard position < cut else { suffix.append(buffer); continue }
            let frames = AVAudioFrameCount(next - cut)
            guard let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw VoicePermissionCoordinator.Failure.captureFailed
            }
            part.frameLength = frames
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            let offset = Int(cut - position) * bytesPerFrame
            let size = Int(frames) * bytesPerFrame
            let from = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let to = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
            for (src, dst) in zip(from, to) {
                guard let original = src.mData, let target = dst.mData,
                      offset + size <= src.mDataByteSize, size <= dst.mDataByteSize else {
                    throw VoicePermissionCoordinator.Failure.captureFailed
                }
                memcpy(target, original.advanced(by: offset), size)
            }
            suffix.append(part)
        }
        return suffix
    }
}
