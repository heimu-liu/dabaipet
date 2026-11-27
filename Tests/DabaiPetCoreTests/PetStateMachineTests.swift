import DabaiPetCore
import Testing

@Suite struct PetStateMachineTests {
    private static let completionEvents: [PetEvent] = [
        .dragEnded, .rollCompleted, .pokeAnimationCompleted, .listenStopped(transcript: "过期转写"),
        .llmReplyReceived(emotion: .happy), .llmFailed, .speakingFinished, .healthReminderDismissed,
        .rpsPhaseAdvanced(.sampling(lockedBaymaxMove: .rock)), .rpsEnded,
    ]

    private static let startEvents: [PetEvent] = [
        .dragBegan, .pokeTriggered, .rollRequested(direction: .left), .listenStarted,
        .llmRequestStarted, .healthReminderDue, .rpsStarted(lockedBaymaxMove: .rock),
    ]

    private static let gameStart = PetEvent.rpsStarted(lockedBaymaxMove: .rock)
    private static let countdownOne = PetEvent.rpsPhaseAdvanced(.countdown(remaining: 1, lockedBaymaxMove: .rock))
    private static let sampling = PetEvent.rpsPhaseAdvanced(.sampling(lockedBaymaxMove: .rock))
    private static let gameResult = PetEvent.rpsPhaseAdvanced(.result(player: nil, baymax: .rock, outcome: .unrecognized))
    private static let gamePaths: [[PetEvent]] = [
        [gameStart], [gameStart, countdownOne], [gameStart, countdownOne, sampling],
        [gameStart, countdownOne, sampling, gameResult],
    ]
    private static let activePaths: [[PetEvent]] = [
        [.dragBegan], [.rollRequested(direction: .right)], [.pokeTriggered], [.listenStarted],
        [.llmRequestStarted], [.llmRequestStarted, .llmReplyReceived(emotion: .care)],
    ] + gamePaths

    @Test func startsIdleAndIgnoresUnmatchedCompletions() {
        var machine = PetStateMachine()
        #expect(machine.state == .idle)
        for event in Self.completionEvents {
            #expect(machine.handle(event).isEmpty)
            #expect(machine.state == .idle)
        }
    }

    @Test(arguments: [RollDirection.left, .right])
    func rollCompletesOnceAndPreservesItsDirection(_ direction: RollDirection) {
        var machine = PetStateMachine()
        #expect(machine.handle(.rollRequested(direction: direction)) == [.startRollWindowAnimation(direction: direction)])
        #expect(machine.state == .rolling(direction: direction))
        #expect(machine.handle(.rollRequested(direction: direction == .left ? .right : .left)).isEmpty)
        #expect(machine.handle(.pokeAnimationCompleted).isEmpty)
        #expect(machine.handle(.healthReminderDue) == [.enqueueDeferredHealthReminder])
        #expect(machine.state == .rolling(direction: direction))
        #expect(machine.handle(.rollCompleted).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.rollCompleted).isEmpty)
    }

    @Test func pokeAndDragIgnoreDuplicateAndInterruptedCallbacks() {
        var machine = PetStateMachine()
        #expect(machine.handle(.pokeTriggered) == [.showTransientBubble(text: "巴拉拉拉～")])
        #expect(machine.state == .poked)
        #expect(machine.handle(.pokeTriggered).isEmpty)
        #expect(machine.handle(.pokeAnimationCompleted).isEmpty)
        #expect(machine.state == .idle)

        _ = machine.handle(.rollRequested(direction: .left))
        #expect(machine.handle(.dragBegan).isEmpty)
        #expect(machine.state == .dragging)
        #expect(machine.handle(.dragBegan).isEmpty)
        #expect(machine.handle(.rollCompleted).isEmpty)
        #expect(machine.handle(.pokeTriggered).isEmpty)
        #expect(machine.state == .dragging)
        #expect(machine.handle(.dragEnded).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.dragEnded).isEmpty)
    }

    @Test(arguments: [
        (nil, .idle), ("", .idle), (" \t\n　", .idle), ("你好", .thinking), (" 你好 ", .thinking),
    ] as [(String?, PetState)])
    func stoppingListeningReleasesMicAndRoutesTranscripts(_ transcript: String?, _ expectedState: PetState) {
        var machine = PetStateMachine()
        #expect(machine.handle(.listenStarted) == [.stopTTS])
        #expect(machine.state == .listening)
        #expect(machine.handle(.listenStarted).isEmpty)
        #expect(machine.handle(.listenStopped(transcript: transcript)) == [.stopMicrophone])
        #expect(machine.state == expectedState)
        #expect(machine.handle(.listenStopped(transcript: "重复转写")).isEmpty)
        #expect(machine.state == expectedState)
    }

    @Test func conversationOnlyAcceptsRepliesAndFailuresWhileThinking() {
        var machine = PetStateMachine()
        #expect(machine.handle(.llmRequestStarted).isEmpty)
        #expect(machine.state == .thinking)
        #expect(machine.handle(.llmRequestStarted).isEmpty)
        #expect(machine.handle(.speakingFinished).isEmpty)
        #expect(machine.state == .thinking)
        #expect(machine.handle(.llmReplyReceived(emotion: .care)).isEmpty)
        #expect(machine.state == .speaking(emotion: .care))
        #expect(machine.handle(.llmReplyReceived(emotion: .excited)).isEmpty)
        #expect(machine.handle(.llmFailed).isEmpty)
        #expect(machine.state == .speaking(emotion: .care))
        #expect(machine.handle(.speakingFinished).isEmpty)
        #expect(machine.state == .idle)

        _ = machine.handle(.llmRequestStarted)
        #expect(machine.handle(.llmFailed).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.llmReplyReceived(emotion: .happy)).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func switchingBetweenRecordingAndConversationStopsThePreviousResource() {
        var machine = PetStateMachine()
        _ = machine.handle(.llmRequestStarted)
        _ = machine.handle(.llmReplyReceived(emotion: .happy))
        #expect(machine.handle(.listenStarted) == [.stopTTS])
        #expect(machine.state == .listening)
        #expect(machine.handle(.speakingFinished).isEmpty)
        #expect(machine.handle(.llmRequestStarted) == [.stopMicrophone])
        #expect(machine.state == .thinking)
        #expect(machine.handle(.listenStopped(transcript: "过期转写")).isEmpty)
        #expect(machine.handle(.listenStarted) == [.stopTTS])
        #expect(machine.state == .listening)
        #expect(machine.handle(.llmReplyReceived(emotion: .care)).isEmpty)
        #expect(machine.handle(.dragBegan) == [.stopMicrophone])
        #expect(machine.state == .dragging)
        #expect(machine.handle(.listenStopped(transcript: "过期转写")).isEmpty)
        #expect(machine.state == .dragging)
    }

    @Test func draggingOrSubmittingTextInterruptsSpeech() {
        var machine = PetStateMachine()
        _ = machine.handle(.llmRequestStarted)
        _ = machine.handle(.llmReplyReceived(emotion: .happy))
        #expect(machine.handle(.llmRequestStarted) == [.stopTTS])
        #expect(machine.state == .thinking)
        #expect(machine.handle(.speakingFinished).isEmpty)
        _ = machine.handle(.llmReplyReceived(emotion: .happy))
        #expect(machine.handle(.dragBegan) == [.stopTTS])
        #expect(machine.state == .dragging)
        #expect(machine.handle(.speakingFinished).isEmpty)
        #expect(machine.state == .dragging)
    }

    @Test(arguments: [[.dragBegan], [.rollRequested(direction: .right)], [gameStart]] as [[PetEvent]])
    func startedDragRollAndGameKeepTheirStateWhenOtherActionsAreRequested(_ path: [PetEvent]) throws {
        var machine = PetStateMachine()
        for event in path { _ = machine.handle(event) }
        let busyState = machine.state
        try #require(busyState != .idle)
        for event: PetEvent in [
            .pokeTriggered, .rollRequested(direction: .left), .listenStarted,
            .llmRequestStarted, .rpsStarted(lockedBaymaxMove: .paper),
        ] {
            #expect(machine.handle(event).isEmpty)
            #expect(machine.state == busyState)
        }
    }

    @Test(arguments: activePaths)
    func reminderDueDefersWithoutInterruptingBusyStates(_ path: [PetEvent]) throws {
        var machine = PetStateMachine()
        for event in path { _ = machine.handle(event) }
        let busyState = machine.state
        try #require(busyState != .idle)
        #expect(machine.handle(.healthReminderDue) == [.enqueueDeferredHealthReminder])
        #expect(machine.handle(.healthReminderDismissed).isEmpty)
        #expect(machine.state == busyState)
    }

    @Test func idleReminderShowsOnceAndCanBeDismissed() {
        var machine = PetStateMachine()
        _ = machine.handle(.listenStarted)
        #expect(machine.handle(.healthReminderDue) == [.enqueueDeferredHealthReminder])
        _ = machine.handle(.listenStopped(transcript: nil))
        #expect(machine.state == .idle)
        #expect(machine.handle(.healthReminderDue) == [.showTransientBubble(text: "休息一下")])
        #expect(machine.state == .healthReminder)
        #expect(machine.handle(.healthReminderDue).isEmpty)
        #expect(machine.handle(.healthReminderDismissed).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.healthReminderDismissed).isEmpty)
    }

    @Test func gameKeepsItsLockedMoveAndIgnoresStaleOrOutOfOrderPhases() {
        var machine = PetStateMachine()
        let countdown = PetState.playingRPS(phase: .countdown(remaining: 3, lockedBaymaxMove: .rock))
        #expect(machine.handle(Self.gameStart).isEmpty)
        #expect(machine.state == countdown)
        for event: PetEvent in [
            .rpsStarted(lockedBaymaxMove: .paper), .rpsPhaseAdvanced(.preparing),
            .rpsPhaseAdvanced(.countdown(remaining: 2, lockedBaymaxMove: .paper)),
            .rpsPhaseAdvanced(.countdown(remaining: 0, lockedBaymaxMove: .rock)),
            Self.sampling, Self.gameResult,
        ] {
            #expect(machine.handle(event).isEmpty)
            #expect(machine.state == countdown)
        }
        let countdownTwo = RPSPhase.countdown(remaining: 2, lockedBaymaxMove: .rock)
        #expect(machine.handle(.rpsPhaseAdvanced(countdownTwo)).isEmpty)
        #expect(machine.state == .playingRPS(phase: countdownTwo))
        #expect(machine.handle(Self.countdownOne).isEmpty)
        #expect(machine.handle(Self.countdownOne).isEmpty)
        #expect(machine.handle(.rpsPhaseAdvanced(countdownTwo)).isEmpty)
        #expect(machine.handle(.rpsPhaseAdvanced(.sampling(lockedBaymaxMove: .paper))).isEmpty)
        #expect(machine.state == .playingRPS(phase: .countdown(remaining: 1, lockedBaymaxMove: .rock)))
        #expect(machine.handle(Self.sampling).isEmpty)
        #expect(machine.state == .playingRPS(phase: .sampling(lockedBaymaxMove: .rock)))
        #expect(machine.handle(.rpsPhaseAdvanced(.result(player: nil, baymax: .paper, outcome: .unrecognized))).isEmpty)
        #expect(machine.state == .playingRPS(phase: .sampling(lockedBaymaxMove: .rock)))
        #expect(machine.handle(Self.gameResult).isEmpty)
        let result = PetState.playingRPS(phase: .result(player: nil, baymax: .rock, outcome: .unrecognized))
        #expect(machine.state == result)
        #expect(machine.handle(Self.gameResult).isEmpty)
        #expect(machine.handle(Self.sampling).isEmpty)
        #expect(machine.state == result)
    }

    @Test(arguments: gamePaths, [.rpsEnded, .dragBegan] as [PetEvent])
    func exitingGameStopsCameraOnce(_ path: [PetEvent], _ exit: PetEvent) {
        var machine = PetStateMachine()
        for event in path { _ = machine.handle(event) }
        guard case .playingRPS = machine.state else {
            Issue.record("Expected an active game after \(path)")
            return
        }
        #expect(machine.handle(exit) == [.stopCamera])
        #expect(machine.state == (exit == .dragBegan ? .dragging : .idle))
        #expect(machine.handle(exit).isEmpty)
        #expect(machine.handle(Self.gameResult).isEmpty)
    }

    @Test(arguments: activePaths + [[.healthReminderDue], []])
    func terminationStopsAllResourcesAndIgnoresLateOrDuplicateEvents(_ path: [PetEvent]) {
        var machine = PetStateMachine()
        for event in path { _ = machine.handle(event) }
        #expect(machine.handle(.appWillTerminate) == [.stopMicrophone, .stopTTS, .stopCamera])
        #expect(machine.state == .idle)
        for event in Self.startEvents + Self.completionEvents + [.appWillTerminate] {
            #expect(machine.handle(event).isEmpty)
            #expect(machine.state == .idle)
        }
    }

    @Test(arguments: activePaths + [[.healthReminderDue], []])
    func deviceEffectsFollowAllStateBoundaries(_ path: [PetEvent]) {
        var original = PetStateMachine()
        for event in path { _ = original.handle(event) }
        for event in Self.startEvents + Self.completionEvents + [.appWillTerminate] {
            var machine = original
            let before = machine.state
            let effects = machine.handle(event)
            if event == .appWillTerminate { continue }

            let leftListening = before == .listening && machine.state != .listening
            #expect(effects.filter { $0 == .stopMicrophone }.count == (leftListening ? 1 : 0))
            if before != .listening && machine.state == .listening {
                #expect(effects.first == .stopTTS)
            }
            let leftGame: Bool
            switch (before, machine.state) {
            case (.playingRPS, .playingRPS): leftGame = false
            case (.playingRPS, _): leftGame = true
            default: leftGame = false
            }
            #expect(effects.filter { $0 == .stopCamera }.count == (leftGame ? 1 : 0))
        }
    }
}
