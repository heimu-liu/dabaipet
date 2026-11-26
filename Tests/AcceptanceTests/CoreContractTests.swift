import DabaiPetCore
import Foundation
import Testing

@Suite struct CoreContractTests {
    @Test func emotionWireValuesExcludePhysicalActions() {
        let emotions = Set(PetEmotion.allCases.map(\.rawValue))
        #expect(emotions == ["neutral", "happy", "care", "dizzy", "sleepy", "excited"])
        for action in [PetAction.roll, .poke, .healthScan, .startRPS] {
            #expect(PetEmotion(rawValue: action.rawValue) == nil)
        }
    }

    @Test func gamePhasesCarryTheLockedMoveAndAllowUnrecognizedGestures() {
        #expect(Set(RPSMove.allCases) == [.rock, .paper, .scissors])
        for move in RPSMove.allCases {
            let phase = RPSPhase.countdown(remaining: 3, lockedBaymaxMove: move)
            guard case let .playingRPS(.countdown(remaining, locked)) = PetState.playingRPS(phase: phase) else {
                Issue.record("missing countdown state")
                return
            }
            #expect(remaining == 3)
            #expect(locked == move)
            let result = RPSPhase.result(player: nil, baymax: locked, outcome: .unrecognized)
            #expect(PetEvent.rpsPhaseAdvanced(result) != .rpsEnded)
        }
    }

    @Test func interactionsExposeTypedStateEventAndEffectPayloads() {
        for direction in [RollDirection.left, .right] {
            let state = PetState.rolling(direction: direction)
            guard case let .rolling(actual) = state else {
                Issue.record("lost rolling state")
                return
            }
            #expect(PetEvent.rollRequested(direction: actual) == .rollRequested(direction: direction))
            #expect(PetEffect.startRollWindowAnimation(direction: actual) == .startRollWindowAnimation(direction: direction))
        }
        let states: [PetState] = [.idle, .dragging, .poked, .listening, .thinking, .speaking(emotion: .care),
                                  .healthReminder, .playingRPS(phase: .preparing)]
        #expect(Set(states.indices.filter { states[$0] == .idle }) == [0])
        let events: [PetEvent] = [.dragBegan, .dragEnded, .pokeTriggered, .rollCompleted, .pokeAnimationCompleted,
                                  .listenStarted, .llmRequestStarted, .llmReplyReceived(emotion: .care), .llmFailed,
                                  .speakingFinished, .healthReminderDue, .healthReminderDismissed,
                                  .rpsStarted(lockedBaymaxMove: .rock), .rpsPhaseAdvanced(.sampling(lockedBaymaxMove: .rock)),
                                  .rpsEnded, .appWillTerminate]
        for (index, event) in events.enumerated() {
            #expect(!events.dropFirst(index + 1).contains(event))
        }
    }

    @Test func stopEffectsCanBeIssuedIndependently() {
        let effects: [PetEffect] = [.stopMicrophone, .stopTTS, .stopCamera]
        for (index, effect) in effects.enumerated() {
            #expect(!effects.dropFirst(index + 1).contains(effect))
        }
        #expect(PetEvent.listenStopped(transcript: nil) != .listenStopped(transcript: "你好"))
        #expect(PetEffect.enqueueDeferredHealthReminder != .showTransientBubble(text: "休息一下"))
    }

    @Test func restingPoseHasAnIdentityTransform() {
        let pose = MotionPose()
        #expect(pose.offsetX == 0 && pose.offsetY == 0)
        #expect(pose.rotationDegrees == 0)
        #expect(pose.scaleX == 1 && pose.scaleY == 1)
    }

    @Test func configurationPersistsOnlyConnectionSettings() throws {
        let config = LLMConfig(provider: .openAICompatible, baseURL: URL(string: "http://localhost:11434")!, model: "local")
        #expect(config.timeoutSeconds == 20)
        #expect((250...300).contains(config.maxTokens))
        let data = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["provider", "baseURL", "model", "maxTokens", "timeoutSeconds"])
        #expect(try JSONDecoder().decode(LLMConfig.self, from: data) == config)
    }

    @Test func secretsAreIsolatedReplaceableAndRemovable() async throws {
        let store: any SecretStore = InMemorySecretStore()
        #expect(try await store.read(account: "one") == nil)
        try await store.save("first", account: "one")
        try await store.save("another", account: "two")
        try await store.save("replacement", account: "one")
        #expect(try await store.read(account: "one") == "replacement")
        try await store.delete(account: "one")
        #expect(try await store.read(account: "one") == nil)
        #expect(try await store.read(account: "two") == "another")
    }
}
