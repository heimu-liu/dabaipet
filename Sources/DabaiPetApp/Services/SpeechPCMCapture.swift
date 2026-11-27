import AVFoundation
import Speech
import os

// AnalyzerInput owns a PCM buffer and is Sendable in the Speech SDK. Only independently
// owned buffers cross the tap callback boundary.
typealias SpeechPCM = AsyncThrowingStream<AnalyzerInput, any Error>

@MainActor protocol SpeechPCMCapture: AnyObject {
    func start(into sink: SpeechPCM.Continuation, changed: @escaping @MainActor () -> Void) throws
    func stop()
}

@MainActor final class MicrophoneCapture: SpeechPCMCapture {
    private static let log = Logger(subsystem: "com.dabaipet.app", category: "speech-input")
    private let engine = AVAudioEngine()
    private var tapped: AVAudioInputNode?
    private var observation: NSObjectProtocol?

    func start(into sink: SpeechPCM.Continuation, changed: @escaping @MainActor () -> Void) throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard Self.valid(node.inputFormat(forBus: 0)), Self.valid(format) else {
            throw VoicePermissionCoordinator.Failure.noInput
        }
        observation = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                             object: engine, queue: nil) { @Sendable _ in
            Task { @MainActor in changed() }
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.tap(into: sink, expectedFormat: format))
        tapped = node
        engine.prepare()
        try engine.start()
        Self.log.notice("capture-started uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public)")
    }

    func stop() {
        Self.log.notice("capture-stop-requested uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public)")
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil
        if let tapped { tapped.removeTap(onBus: 0) }
        tapped = nil
        engine.stop()
        Self.log.notice("capture-released uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public)")
    }

    nonisolated static func valid(_ format: AVAudioFormat) -> Bool {
        format.channelCount > 0 && format.sampleRate.isFinite && format.sampleRate > 0 &&
        format.commonFormat != .otherFormat && format.streamDescription.pointee.mBytesPerFrame > 0
    }

    nonisolated static func tap(into sink: SpeechPCM.Continuation, expectedFormat: AVAudioFormat? = nil) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in
            guard buffer.frameLength > 0 else { return }
            let format = buffer.format
            if let expectedFormat, format.sampleRate != expectedFormat.sampleRate ||
                format.channelCount != expectedFormat.channelCount || format.commonFormat != expectedFormat.commonFormat ||
                format.isInterleaved != expectedFormat.isInterleaved {
                sink.finish(throwing: VoicePermissionCoordinator.Failure.noInput)
                return
            }
            guard let copy = ownedCopy(of: buffer) else {
                sink.finish(throwing: VoicePermissionCoordinator.Failure.captureFailed)
                return
            }
            if case .dropped = sink.yield(AnalyzerInput(buffer: copy)) {
                sink.finish(throwing: VoicePermissionCoordinator.Failure.captureFailed)
            }
        }
    }

    nonisolated private static func ownedCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard valid(buffer.format),
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for (from, to) in zip(source, target) {
            guard from.mDataByteSize >= to.mDataByteSize, let src = from.mData, let dst = to.mData else { return nil }
            memcpy(dst, src, Int(to.mDataByteSize))
        }
        return copy
    }
}
