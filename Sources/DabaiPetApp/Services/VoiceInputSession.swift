import Foundation

enum VoiceInputLimits {
    static let maximumDuration: Duration = .seconds(30)
}

typealias VoiceInputSessionCompletion = @MainActor (Result<String, VoicePermissionCoordinator.Failure>) -> Void

/// Construction is inert. The controller registers the session after beginListening() stops TTS.
@MainActor protocol VoiceInputSession: PetSession {
    /// A legacy route must require on-device recognition. Report setup and stream failures with Failure.recognition(_:).
    func start(route: VoicePermissionCoordinator.Route, completion: @escaping VoiceInputSessionCompletion) throws
    /// End input and deliver the final result. stop() cancels and releases all capture resources.
    func finish()
}

/// A live capture may release the hardware before recognition has returned its final text.
@MainActor protocol LiveVoiceInputSession: VoiceInputSession {
    func configure(deadline: ContinuousClock.Instant, captureChanged: @escaping @MainActor (Bool) -> Void)
}

/// Keep the capture open while awaiting the first words of an explicitly started conversation.
@MainActor protocol ConversationalVoiceInput: LiveVoiceInputSession {
    func awaitUtterance()
}
