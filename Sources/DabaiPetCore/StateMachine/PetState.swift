public enum PetEmotion: String, Codable, Equatable, CaseIterable, Sendable {
    case neutral, happy, care, dizzy, sleepy, excited
}

public enum PetAction: String, Codable, Equatable, Sendable {
    case roll, poke, healthScan, startRPS // 仅允许用户主动触发，严禁由 LLM 文本标签触发
}

public enum RollDirection: Equatable, Sendable {
    case left, right
}

public enum RPSMove: String, Codable, Equatable, CaseIterable, Sendable {
    case rock, paper, scissors
}

public enum RPSPhase: Equatable, Sendable {
    case preparing
    case countdown(remaining: Int, lockedBaymaxMove: RPSMove)
    case sampling(lockedBaymaxMove: RPSMove)
    case result(player: RPSMove?, baymax: RPSMove, outcome: RPSOutcome)
}

public enum RPSOutcome: String, Equatable, Sendable {
    case playerWin, baymaxWin, draw, unrecognized
}

public enum PetState: Equatable, Sendable {
    case idle
    case dragging
    case rolling(direction: RollDirection)
    case poked
    case listening
    case thinking
    case speaking(emotion: PetEmotion)
    case healthReminder
    case playingRPS(phase: RPSPhase)
}

public enum PetEvent: Equatable, Sendable {
    case dragBegan
    case dragEnded
    case pokeTriggered
    case rollRequested(direction: RollDirection)
    case rollCompleted
    case pokeAnimationCompleted
    case listenStarted
    case listenStopped(transcript: String?)
    case llmRequestStarted
    case llmReplyReceived(emotion: PetEmotion)
    case llmFailed
    case speakingFinished
    case healthReminderDue
    case healthReminderDismissed
    case rpsStarted(lockedBaymaxMove: RPSMove)
    case rpsPhaseAdvanced(RPSPhase)
    case rpsEnded
    case appWillTerminate
}

public enum PetEffect: Equatable, Sendable {
    case stopMicrophone
    case stopTTS
    case stopCamera
    case startRollWindowAnimation(direction: RollDirection)
    case showTransientBubble(text: String)
    case enqueueDeferredHealthReminder
}
