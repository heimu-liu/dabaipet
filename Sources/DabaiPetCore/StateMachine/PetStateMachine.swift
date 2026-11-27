/// Deterministic interaction state for one application lifetime.
public struct PetStateMachine: Sendable {
    public private(set) var state: PetState = .idle
    private var hasTerminated = false

    public init() {}

    /// Dispatch serially and execute the returned effects in order before starting
    /// work for the new state. Scope asynchronous callbacks to their originating activity.
    public mutating func handle(_ event: PetEvent) -> [PetEffect] {
        guard !hasTerminated else { return [] }

        let previousState = state
        let effect = apply(event)
        if hasTerminated {
            return [.stopMicrophone, .stopTTS, .stopCamera]
        }

        var effects: [PetEffect] = []
        if previousState != state {
            if state == .listening {
                effects.append(.stopTTS)
            } else if case .speaking = previousState, event != .speakingFinished {
                effects.append(.stopTTS)
            }
            if previousState == .listening {
                effects.append(.stopMicrophone)
            }
            switch (previousState, state) {
            case (.playingRPS, .playingRPS):
                break
            case (.playingRPS, _):
                effects.append(.stopCamera)
            default:
                break
            }
        }
        if let effect {
            effects.append(effect)
        }
        return effects
    }

    private mutating func apply(_ event: PetEvent) -> PetEffect? {
        switch event {
        case .dragBegan:
            state = .dragging
        case .dragEnded:
            guard state == .dragging else { return nil }
            state = .idle
        case .pokeTriggered:
            guard state == .idle else { return nil }
            state = .poked
            return .showTransientBubble(text: "巴拉拉拉～")
        case .rollRequested(let direction):
            guard state == .idle else { return nil }
            state = .rolling(direction: direction)
            return .startRollWindowAnimation(direction: direction)
        case .rollCompleted:
            guard case .rolling = state else { return nil }
            state = .idle
        case .pokeAnimationCompleted:
            guard state == .poked else { return nil }
            state = .idle
        case .listenStarted:
            guard acceptsConversationInput else { return nil }
            state = .listening
        case .listenStopped(let transcript):
            guard state == .listening else { return nil }
            let hasSpeech = transcript?.contains { !$0.isWhitespace } == true
            state = hasSpeech ? .thinking : .idle
        case .llmRequestStarted:
            guard acceptsConversationInput else { return nil }
            state = .thinking
        case .llmReplyReceived(let emotion):
            guard state == .thinking else { return nil }
            state = .speaking(emotion: emotion)
        case .llmFailed:
            guard state == .thinking else { return nil }
            state = .idle
        case .speakingFinished:
            guard case .speaking = state else { return nil }
            state = .idle
        case .healthReminderDue:
            switch state {
            case .idle:
                state = .healthReminder
                return .showTransientBubble(text: "休息一下")
            case .healthReminder:
                return nil
            default:
                return .enqueueDeferredHealthReminder
            }
        case .healthReminderDismissed:
            guard state == .healthReminder else { return nil }
            state = .idle
        case .rpsStarted(let lockedBaymaxMove):
            guard state == .idle else { return nil }
            // The controller sends this after game setup, with the move already locked.
            state = .playingRPS(phase: .countdown(remaining: 3, lockedBaymaxMove: lockedBaymaxMove))
        case .rpsPhaseAdvanced(let phase):
            guard case .playingRPS(let current) = state, Self.canAdvance(from: current, to: phase) else { return nil }
            state = .playingRPS(phase: phase)
        case .rpsEnded:
            guard case .playingRPS = state else { return nil }
            state = .idle
        case .appWillTerminate:
            state = .idle
            hasTerminated = true
        }
        return nil
    }

    private var acceptsConversationInput: Bool {
        switch state {
        case .idle, .poked, .healthReminder, .listening, .thinking, .speaking:
            return true
        case .dragging, .rolling, .playingRPS:
            return false
        }
    }

    private static func canAdvance(from current: RPSPhase, to next: RPSPhase) -> Bool {
        switch (current, next) {
        case let (.countdown(remaining, locked), .countdown(tick, proposedMove)):
            return tick > 0 && tick < remaining && proposedMove == locked
        case let (.countdown(1, locked), .sampling(proposedMove)),
             let (.sampling(locked), .result(_, proposedMove, _)):
            return proposedMove == locked
        default:
            return false
        }
    }
}
