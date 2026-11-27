import AppKit
import Combine
import DabaiPetCore
import DabaiPetUI
import Observation
import SwiftUI

/// An active service owns its hardware queue and supplies its own teardown.
@MainActor protocol PetSession: AnyObject {
    func stop()
}

@MainActor @Observable
private final class SettingsFormState {
    var companion: PetPreferences
    var connection: SettingsView.Connection

    init(store: PreferencesStore) {
        companion = store.loadPreferences()
        let stored = store.loadConnection()
        connection = SettingsView.Connection(provider: stored.provider.flatMap(LLMProvider.init(rawValue:)) ?? .local,
                                             baseURL: stored.baseURL, model: stored.model)
    }
}

/// One main-actor owner for the window, reducer and actions of a running pet.
@MainActor
final class PetController: NSObject {
    private let preferences: PreferencesStore
    private let settingsForm: SettingsFormState
    private let llmClient: LLMClient
    private var replyTask: Task<Void, Never>?
    private var replyID: UUID?
    // Visible turns before a configuration change belong to the former service.
    private var historyStart = 0
    private let settingsConnectionActions: SettingsView.ConnectionActions
    private let voicePermissions: VoicePermissionCoordinator
    private let makeVoiceInput: (@MainActor () -> any VoiceInputSession)?
    // The conversation token survives multiple recognition turns and playback sessions.
    // Only the belly start action creates one; stopping invalidates all queued continuations.
    private var conversationID: UUID?
    private var conversationRoute: VoicePermissionCoordinator.Route?
    private var nextTurn: Task<Void, Never>?
    private var voiceAttempt: UUID?
    private enum DialogueSource { case chat, belly }
    private enum VoicePhase { case idle, permission, preparing, listening, finishing }
    private var dialogueSource: DialogueSource = .chat
    private var voicePhase: VoicePhase = .idle {
        didSet { updateVoiceControls() }
    }
    private let makeSpeechOutput: @MainActor () -> SpeechOutputService
    private lazy var speechOutput = makeSpeechOutput()
    let panel: PetFloatingPanel
    private var view: BaymaxLayerView
    private let monitor: PetAnimationSystemMonitor
    private let typingMonitor: TypingCompanionMonitor
    private let healthMonitor: HealthReminderMonitor
    private let conversation = ChatBubbleView.Transcript()
    private var manualScanPending = false
    private var input: PetInputOverlayView!
    private var roll: PetRollController!
    private var machine = PetStateMachine()
    private var system = PetAnimationSystemState()
    private var pending: [PetEvent] = []
    private var delivering = false
    private var generation: UInt64 = 0
    private var dragPose = MotionPose()
    private var shown = false
    private var ended = false
    private var settingsWindow: SettingsWindowController?
    private var appearanceObservation: NSKeyValueObservation?
    private let settingsClosed = PassthroughSubject<Void, Never>()
    private(set) var chatPanel: ChatPanelController?
    private var bubble: NSPanel?
    private var bubbleTimer: Timer?
    var state: PetState { machine.state }
    var isVisible: Bool { panel.isVisible }
    var companionPreferences: PetPreferences { settingsForm.companion }
    var isSpeechMuted: Bool { companionPreferences.isSpeechMuted }

    var microphoneSession: (any PetSession)?
    var cameraSession: (any PetSession)?
    var speechSession: (any PetSession)?

    private static var targetScreen: NSScreen? {
        NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) != 0
        } ?? NSScreen.main
    }

    init(preferences: PreferencesStore = PreferencesStore(),
         pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
         systemSources: PetAnimationSystemMonitor.Sources = .init(),
         typingMonitor: TypingCompanionMonitor = TypingCompanionMonitor(),
         healthMonitor: HealthReminderMonitor = HealthReminderMonitor(),
         settingsConnectionActions: SettingsView.ConnectionActions = .init(),
         llmClient: LLMClient = ConnectionServices(store: KeychainStore()).client,
         voicePermissions: VoicePermissionCoordinator = .init(),
         makeVoiceInput: (@MainActor () -> any VoiceInputSession)? = nil,
         makeSpeechOutput: @escaping @MainActor () -> SpeechOutputService = { SpeechOutputService() }) throws {
        self.llmClient = llmClient
        self.voicePermissions = voicePermissions
        self.makeVoiceInput = makeVoiceInput
        self.healthMonitor = healthMonitor
        self.typingMonitor = typingMonitor
        self.preferences = preferences
        self.settingsConnectionActions = settingsConnectionActions
        self.makeSpeechOutput = makeSpeechOutput
        let settingsForm = SettingsFormState(store: preferences)
        self.settingsForm = settingsForm
        let prefs = settingsForm.companion
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let view = BaymaxLayerView(scale: BaymaxScale(rawValue: prefs.scale.rawValue) ?? .standard,
                                   appearance: dark ? .dark : .light)
        self.view = view
        let size = view.geometry.idleWindowSize
        guard let area = Self.targetScreen?.visibleFrame,
              let origin = preferences.restoredWindowOrigin(for: size, in: area) else {
            throw NSError(domain: "DabaiPet", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到可放置大白的显示区域。"])
        }
        weak var hitPanel: PetFloatingPanel?
        let hit: PetFloatingPanel.BodyHitTest = { p, margin in
            (hitPanel?.contentView as? BaymaxLayerView)?.containsBodyPoint(p, outwardMargin: margin) ?? false
        }
        panel = PetFloatingPanel(contentRect: CGRect(origin: origin, size: size),
                                 pointerLocation: pointerLocation, bodyHitTest: hit)
        hitPanel = panel
        monitor = PetAnimationSystemMonitor(window: panel, sources: systemSources)
        super.init()
        panel.contentView = view
        input = PetInputOverlayView(frame: view.bounds, bodyHitTest: hit, clampFrame: { proposed, visible in
            ScreenGeometry.clampedFrame(proposed, to: Self.targetScreen?.visibleFrame ?? visible).origin
        }, mouseLocation: pointerLocation) { [weak self] event in self?.receive(event) }
        if makeVoiceInput != nil {
            input.onBellyVoice = { [weak self] in self?.toggleVoiceInput(from: .belly) }
        }
        appearanceObservation = panel.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // Wait until AppKit has propagated the window appearance to its views.
            Task { @MainActor [weak self] in
                guard let self, self.shown, !self.ended, self.state == .idle,
                      self.resolvedAppearance != self.view.desktopAppearance else { return }
                self.updateIdle()
            }
        }
        input.speechMuted = prefs.isSpeechMuted
        input.remindersEnabled = prefs.healthReminderInterval != .off
        input.typingEnabled = prefs.isTypingCompanionEnabled
        input.autoresizingMask = [.width, .height]
        view.addSubview(input)
        roll = PetRollController(panel: panel, render: { [weak self] anchor, pose, elapsed in
            guard let self else { return }
            self.view.render(pose: pose, at: anchor, state: elapsed == nil ? .idle : self.state, elapsed: elapsed ?? 0)
        }, didEnd: { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .completed(let frame), .interrupted(let frame): self.preferences.saveWindowOrigin(frame.origin)
            }
            if case .rolling = self.state { self.send(.rollCompleted) }
        })
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(shutdown), name: NSApplication.willTerminateNotification, object: NSApp)
        nc.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    }

    func show() {
        guard !ended, !shown else { return }
        shown = true
        panel.orderFrontRegardless()
        monitor.start { [weak self] next in self?.systemChanged(next) }
    }

    func hide() {
        guard !ended, shown else { return }
        shown = false
        endDialogue()
        monitor.stop()
        manualScanPending = false
        healthMonitor.stop()
        typingMonitor.stop()
        settle()
        chatPanel?.close()
        panel.orderOut(nil)
    }

    func showSettings() {
        guard !ended else { return }
        if settingsWindow == nil {
            let settings = SettingsWindowController(content: NSHostingController(rootView: makeSettingsForm()))
            settings.onClose = { [weak self] in self?.settingsClosed.send(()) }
            settingsWindow = settings
        }
        settingsWindow?.present()
    }

    func toggleVisibility() {
        if shown { hide() } else { show() }
    }

    func toggleSpeechMute() {
        guard !ended else { return }
        var values = companionPreferences
        values.isSpeechMuted.toggle()
        applyPreferences(values)
    }

    /// Start audio for the current reply after the reducer has entered speaking.
    /// False leaves presentation and completion to the caller, for example when muted.
    func speakReply(_ text: String) -> Bool {
        guard shown, !ended, !delivering, !isSpeechMuted, microphoneSession == nil,
              case .speaking = state else { return false }
        let output = speechOutput
        let owner = conversationID
        if speechSession !== output { perform(.stopTTS) }
        guard output.speak(text, onEnd: { [weak self, weak output] end in
            guard let self, let output, self.speechSession === output else { return }
            self.speechSession = nil
            self.send(.speakingFinished)
            if let owner, self.conversationID == owner {
                self.scheduleListening(after: end == .finished ? .zero : .milliseconds(600))
            }
        }) else { return false }
        speechSession = output
        return true
    }

    /// Call after microphone permission is ready and before starting capture.
    /// On success, the reducer has synchronously stopped the previous speech session.
    func beginListening() -> Bool {
        guard shown, !ended, !delivering, state != .listening else { return false }
        send(.listenStarted)
        return !ended && state == .listening
    }

    private var voiceAvailable: Bool {
        guard shown, !ended, makeVoiceInput != nil,
              system.pauseReasons.intersection([.screenLocked, .systemSleeping]).isEmpty else { return false }
        switch state {
        case .dragging, .rolling, .playingRPS: return false
        default: return true
        }
    }

    private func updateBellyControl() {
        input.isVoiceConversationActive = conversationID != nil
        let display: PetInputOverlayView.BellyVoiceState
        if voiceAvailable {
            switch voicePhase {
            case .idle: display = .idle
            case .permission, .preparing: display = .preparing
            case .listening: display = .listening
            case .finishing: display = .finishing
            }
        } else { display = .hidden }
        if input.bellyVoiceState != display { input.bellyVoiceState = display }
    }

    private func updateVoiceControls() {
        updateBellyControl()
        guard let chat = chatPanel else { return }
        if conversationID != nil {
            chat.setVoiceStatus(nil, buttonLabel: "请先结束肚子语音对话", enabled: false)
            return
        }
        switch voicePhase {
        case .idle: chat.setVoiceStatus(nil)
        case .permission: chat.setVoiceStatus("正在检查语音权限…", buttonLabel: "取消语音输入", symbol: "xmark.circle")
        case .preparing: chat.setVoiceStatus("正在准备语音输入…", buttonLabel: "取消语音输入", symbol: "xmark.circle")
        case .listening: chat.setVoiceStatus("正在听…", buttonLabel: "结束语音输入", symbol: "stop.circle")
        case .finishing: chat.setVoiceStatus("正在完成识别…", buttonLabel: "正在完成识别", symbol: "ellipsis.circle", enabled: false)
        }
    }

    private func toggleVoiceInput(from source: DialogueSource) {
        if conversationID != nil {
            if source == .belly { endDialogue() }
            return
        }
        guard voiceAvailable, source == .belly || chatPanel?.window?.isVisible == true else { return }
        if voicePermissions.isPending { voicePermissions.cancel(); return }
        if let session = microphoneSession as? any VoiceInputSession {
            guard voicePhase != .finishing else { return }
            voicePhase = .finishing
            session.finish()
            return
        }
        endDialogue()
        dialogueSource = source
        if source == .belly { conversationID = UUID() }
        requestVoiceInput(legacyOnly: false)
    }

    private func requestVoiceInput(legacyOnly: Bool, deadline: ContinuousClock.Instant? = nil) {
        guard voiceAvailable else { return }
        let id = UUID()
        voiceAttempt = id
        voicePhase = .permission
        voicePermissions.requestFromUser(legacyOnly: legacyOnly) { [weak self] result in
            guard let self, voiceAttempt == id, voiceAvailable else { return }
            switch result {
            case .failure(let error):
                endDialogue()
                showVoiceFailure(error)
            case .success(let route):
                self.conversationRoute = self.conversationID == nil ? nil : route
                self.startRecognition(id: id, route: route, deadline: deadline)
            }
        }
    }

    private func startRecognition(id: UUID, route: VoicePermissionCoordinator.Route, deadline: ContinuousClock.Instant?) {
        let cutoff = deadline ?? ContinuousClock.now.advanced(by: VoiceInputLimits.maximumDuration)
        guard let makeVoiceInput, ContinuousClock.now < cutoff, beginListening() else {
            endDialogue()
            showVoiceNotice("这次语音输入已结束，请重新点麦。")
            return
        }
        let session = makeVoiceInput()
        microphoneSession = session
        if conversationID != nil { (session as? any ConversationalVoiceInput)?.awaitUtterance() }
        if let live = session as? any LiveVoiceInputSession {
            voicePhase = .preparing
            live.configure(deadline: cutoff) { [weak self] capturing in
                guard let self, voiceAttempt == id else { return }
                voicePhase = capturing ? .listening : .finishing
            }
        } else { voicePhase = .listening }
        let completed: VoiceInputSessionCompletion = { [weak self] outcome in
            self?.voiceCompleted(id: id, route: route, deadline: cutoff, result: outcome)
        }
        do { try session.start(route: route, completion: completed) }
        catch { completed(.failure(.recognition(error))) }
    }

    private func scheduleListening(after delay: Duration = .zero, notice: String? = nil) {
        guard let owner = conversationID else { return }
        nextTurn?.cancel()
        nextTurn = Task { [weak self] in
            do { try await Task.sleep(for: delay); try Task.checkCancellation() } catch { return }
            guard let self, conversationID == owner, voiceAvailable, microphoneSession == nil,
                  speechSession == nil, voiceAttempt == nil, state == .idle else { return }
            nextTurn = nil
            guard let route = conversationRoute else {
                requestVoiceInput(legacyOnly: false)
                return
            }
            do { try voicePermissions.validateForNextTurn(route) }
            catch {
                endDialogue()
                showVoiceFailure(.recognition(error))
                return
            }
            let id = UUID()
            voiceAttempt = id
            startRecognition(id: id, route: route, deadline: nil)
            if let notice, conversationID == owner { showBubble(notice) }
        }
    }

    private func voiceCompleted(id: UUID, route: VoicePermissionCoordinator.Route, deadline: ContinuousClock.Instant,
                                result: Result<String, VoicePermissionCoordinator.Failure>) {
        guard voiceAttempt == id, state == .listening, voiceAvailable else { return }
        switch result {
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if conversationID != nil, VoiceConversationCommand.isGoodbye(text) {
                endDialogue()
                showVoiceNotice("语音对话已结束。")
                return
            }
            send(.listenStopped(transcript: text))
            guard !text.isEmpty else {
                if conversationID != nil { scheduleListening(after: .seconds(1)) }
                else { showVoiceFailure(.noSpeech) }
                return
            }
            conversation.messages.append(.init(role: .user, content: text))
            reply(to: text)
        case .failure(let error):
            let canRetry = voicePhase != .finishing && ContinuousClock.now < deadline
            send(.listenStopped(transcript: nil))
            if case .analyzer = route, error == .noRecognizer, canRetry {
                requestVoiceInput(legacyOnly: true, deadline: deadline)
            } else if conversationID != nil && error == .unconfirmedTranscript {
                showBubble(error.message)
                scheduleListening(after: .seconds(1), notice: error.message)
            } else if conversationID != nil && error == .noSpeech {
                scheduleListening(after: .seconds(1))
            } else {
                endDialogue()
                showVoiceFailure(error)
            }
        }
    }

    private func showVoiceFailure(_ error: VoicePermissionCoordinator.Failure) {
        guard dialogueSource == .belly else { chatPanel?.setVoiceStatus(error.message); return }
        let text: String
        switch error {
        case .denied(let kind):
            let name = kind == .microphone ? "麦克风" : "语音识别"
            text = "请在「隐私与安全性」中允许大白使用" + name + "。"
        case .restricted: text = "语音权限受限，请联系设备管理员。"
        case .noInput: text = "请连接麦克风，再点一下。"
        case .noRecognizer: text = "请检查中文语音资源，再点一下。"
        case .unconfirmedTranscript: text = error.message
        case .captureFailed: text = "这次没听清，请再点一下。"
        case .noSpeech: text = "没有听到语音，再点一下试试。"
        case .cancelled: text = "已取消语音输入。"
        }
        showVoiceNotice(text)
    }

    private func showVoiceNotice(_ text: String) {
        chatPanel?.setVoiceStatus(text)
        if dialogueSource == .belly, voiceAvailable { showBubble(text) }
    }

    private func cancelVoiceInput() {
        voiceAttempt = nil
        voicePermissions.cancel()
        if state == .listening { send(.listenStopped(transcript: nil)) }
        voicePhase = .idle
    }

    private func makeSettingsForm() -> SettingsView {
        SettingsView(connection: Binding(get: { [settingsForm] in settingsForm.connection }, set: { [weak self] value in
            guard let self, !self.ended else { return }
            guard self.settingsForm.connection != value else { return }
            if self.conversationID == nil { self.endDialogue() }
            else if self.state == .thinking { self.resetTurn(); self.scheduleListening() }
            self.historyStart = self.conversation.messages.count
            self.settingsForm.connection = value
            self.updateChatMode()
            if value.baseURL.isEmpty || value.validatedBaseURL != nil {
                self.preferences.saveConnection(provider: value.provider.rawValue, baseURL: value.baseURL, model: value.model)
            }
        }), companion: Binding(get: { [settingsForm] in
            let value = settingsForm.companion
            return SettingsView.Companion(scale: value.scale.rawValue, isSpeechMuted: value.isSpeechMuted,
                                          healthReminderMinutes: value.healthReminderInterval.rawValue,
                                          isTypingCompanionEnabled: value.isTypingCompanionEnabled)
        }, set: { [weak self] value in
            guard let self, !self.ended else { return }
            var updated = self.companionPreferences
            if let scale = PetPreferences.Scale(rawValue: value.scale) { updated.scale = scale }
            if let interval = PetPreferences.HealthReminderInterval(rawValue: value.healthReminderMinutes) {
                updated.healthReminderInterval = interval
            }
            updated.isSpeechMuted = value.isSpeechMuted
            updated.isTypingCompanionEnabled = value.isTypingCompanionEnabled
            self.applyPreferences(updated)
        }), connectionActions: settingsConnectionActions, windowClosed: settingsClosed.eraseToAnyPublisher())
    }

    private func applyPreferences(_ updated: PetPreferences) {
        let previous = companionPreferences
        guard updated != previous else { return }
        settingsForm.companion = updated
        if updated.isSpeechMuted != previous.isSpeechMuted {
            input.speechMuted = updated.isSpeechMuted
        }
        if updated.isSpeechMuted && !previous.isSpeechMuted {
            let hadSpeech = speechSession != nil
            perform(.stopTTS)
            if hadSpeech {
                send(.speakingFinished)
                scheduleListening()
            }
        }
        preferences.savePreferences(updated)
        if updated.isTypingCompanionEnabled != previous.isTypingCompanionEnabled {
            input.typingEnabled = updated.isTypingCompanionEnabled
            updateTypingCompanion()
        }
        if updated.healthReminderInterval != previous.healthReminderInterval {
            input.remindersEnabled = updated.healthReminderInterval != .off
            updateHealthReminders()
            if !input.remindersEnabled && state == .healthReminder { send(.healthReminderDismissed) }
        }
        if updated.scale != previous.scale { resizePet(to: updated.scale) }
    }

    private var resolvedAppearance: DesktopAppearance {
        panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private func refreshIdleAppearance() {
        let appearance = resolvedAppearance
        guard !ended, shown, state == .idle, !input.isInteractionActive,
              appearance != view.desktopAppearance else { return }
        guard let scale = BaymaxScale(rawValue: companionPreferences.scale.rawValue) else { return }
        let frame = panel.frame
        let replacement = BaymaxLayerView(scale: scale, appearance: appearance)
        input.removeFromSuperview()
        view = replacement
        panel.contentView = replacement
        panel.setFrame(frame, display: panel.isVisible)
        input.frame = replacement.bounds
        replacement.addSubview(input)
        panel.requestHitTest()
    }

    private func resizePet(to preference: PetPreferences.Scale) {
        guard let scale = BaymaxScale(rawValue: preference.rawValue), let area = Self.targetScreen?.visibleFrame else { return }
        settle()
        let oldFrame = panel.frame
        let replacement = BaymaxLayerView(scale: scale, appearance: resolvedAppearance)
        let size = replacement.geometry.idleWindowSize
        let target = ScreenGeometry.clampedFrame(CGRect(origin: CGPoint(x: oldFrame.maxX - size.width, y: oldFrame.minY),
                                                        size: size), to: area)
        input.removeFromSuperview()
        view = replacement
        panel.contentView = replacement
        panel.setFrame(target, display: panel.isVisible)
        input.frame = replacement.bounds
        replacement.addSubview(input)
        preferences.saveWindowOrigin(panel.frame.origin)
        panel.requestHitTest()
        updateDialogueArtwork()
        updateIdle()
    }

    func resetPosition() {
        guard !ended, let area = Self.targetScreen?.visibleFrame else { return }
        settle()
        let f = panel.frame
        let target = CGRect(x: area.maxX - f.width - 16, y: area.minY + 16, width: f.width, height: f.height)
        move(to: ScreenGeometry.clampedFrame(target, to: area).origin)
        updateIdle()
    }

    @objc private func screenChanged() {
        guard !ended, let area = Self.targetScreen?.visibleFrame else { return }
        settle()
        let target = ScreenGeometry.clampedFrame(panel.frame, to: area).origin
        if panel.frame.origin != target { move(to: target) }
        updateIdle()
    }

    private func move(to origin: CGPoint) {
        panel.setFrameOrigin(origin)
        preferences.saveWindowOrigin(panel.frame.origin)
        panel.requestHitTest()
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    @objc func shutdown() {
        guard !ended else { return }
        ended = true
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        invalidateConversation()
        voiceAttempt = nil
        voicePhase = .idle
        discardReply()
        voicePermissions.cancel()
        shown = false
        NotificationCenter.default.removeObserver(self)
        monitor.stop()
        manualScanPending = false
        healthMonitor.stop()
        typingMonitor.stop()
        // Gesture/roll cancellation can synchronously deliver the actual endpoint.
        if state == .dragging { preferences.saveWindowOrigin(panel.frame.origin) }
        settle()
        for effect in machine.handle(.appWillTerminate) { perform(effect) }
        pending.removeAll()
        chatPanel?.close()
        chatPanel = nil
        settingsWindow?.close()
        settingsWindow = nil
        panel.close()
    }

    private func settle() {
        input.cancelInteraction()
        roll.cancel()
        generation &+= 1
        hideBubble()
        view.render(pose: MotionPose())
        switch state {
        case .listening, .thinking: updateDialogueArtwork()
        case .poked: send(.pokeAnimationCompleted)
        case .speaking where conversationID == nil: send(.speakingFinished)
        case .speaking: updateDialogueArtwork()
        case .healthReminder: send(.healthReminderDismissed)
        default: break
        }
        panel.requestHitTest()
    }

    private func systemChanged(_ next: PetAnimationSystemState) {
        guard shown, !ended else { return }
        let changedMotion = next.reduceMotion != system.reduceMotion
        system = next
        if !next.pauseReasons.intersection([.systemSleeping, .screenLocked]).isEmpty {
            endDialogue()
        }
        updateBellyControl()
        switch state {
        case .listening, .thinking, .speaking:
            // Power and accessibility events change presentation independently of the conversation.
            updateDialogueArtwork()
        default:
            if next.shouldPauseAnimations || changedMotion { settle() }
        }
        updateIdle()
        updateHealthReminders()
    }

    private func updateHealthReminders() {
        guard shown, !ended else { return }
        let pause = system.pauseReasons
        if !pause.intersection([.systemSleeping, .screenLocked]).isEmpty { manualScanPending = false }
        let decision = healthMonitor.update(minutes: companionPreferences.healthReminderInterval.rawValue,
                                           state: conversationID != nil && state == .idle ? .listening : state, pause: pause) { [weak self] in self?.updateHealthReminders() }
        if decision == .due || (manualScanPending && state == .idle && conversationID == nil) {
            manualScanPending = false
            send(.healthReminderDue)
        }
    }

    private var animates: Bool { shown && !ended && !system.shouldPauseAnimations }

    private func updateTypingCompanion() {
        guard companionPreferences.isTypingCompanionEnabled, animates, !system.reduceMotion, state == .idle else {
            typingMonitor.stop()
            view.stopTypingBeat()
            return
        }
        typingMonitor.start { [weak self] in self?.view.playTypingBeat() }
    }

    private func updateDialogueArtwork() {
        switch state {
        case .listening:
            view.startListening(reducedMotion: !animates || system.reduceMotion)
        case .thinking:
            view.startThinking(reducedMotion: !animates || system.reduceMotion)
        case .speaking(let emotion):
            view.showSpeaking(emotion, reducedMotion: !animates || system.reduceMotion)
        default: break
        }
    }

    private func updateIdle() {
        refreshIdleAppearance()
        updateTypingCompanion()
        guard animates, state == .idle else { return }
        view.startIdle(reducedMotion: system.reduceMotion)
        panel.requestHitTest()
    }

    private func receive(_ input: PetInputOverlayView.Input) {
        guard !ended else { return }
        switch input {
        case .poke: if conversationID == nil { send(.pokeTriggered) }
        case .rollRequested: if conversationID == nil { send(.rollRequested(direction: .right)) }
        case .chatRequested:
            if chatPanel == nil {
                let chat = ChatPanelController(transcript: conversation)
                if makeVoiceInput != nil { chat.onVoice = { [weak self] in self?.toggleVoiceInput(from: .chat) } }
                chat.onSend = { [weak self] text in
                    guard let self else { return }
                    resetTurn()
                    if conversationID == nil { dialogueSource = .chat }
                    reply(to: text)
                }
                chat.onClear = { [weak self] in
                    guard let self else { return }
                    historyStart = 0
                    if conversationID == nil { endDialogue() }
                    else if state == .thinking { resetTurn(); scheduleListening() }
                }
                chat.onClose = { [weak self] in
                    guard let self, dialogueSource == .chat else { return }
                    endDialogue()
                }
                chatPanel = chat
                updateVoiceControls()
            }
            updateChatMode()
            chatPanel?.show(anchoredTo: panel)
        case .healthScanRequested:
            if state == .idle && conversationID == nil { send(.healthReminderDue) }
            else if state != .healthReminder { manualScanPending = true }
        case .toggleSpeechMute:
            toggleSpeechMute()
        case .toggleHealthReminder:
            var updated = companionPreferences
            updated.healthReminderInterval = updated.healthReminderInterval == .off ? .minutes30 : .off
            applyPreferences(updated)
        case .toggleTypingCompanion:
            var updated = companionPreferences
            updated.isTypingCompanionEnabled.toggle()
            applyPreferences(updated)
        case .settingsRequested: showSettings()
        case .closeRequested: quit()
        case .dragBegan:
            guard conversationID == nil else { return }
            cancelVoiceInput()
            dragPose = MotionPose()
            send(.dragBegan)
        case .dragChanged(let vx):
            guard state == .dragging else { return }
            dragPose = animates && !system.reduceMotion ? MotionEngine.dragging(horizontalVelocity: vx) : MotionPose()
            view.render(pose: dragPose, state: .dragging)
            panel.requestHitTest()
        case .dragEnded(let cancelled):
            if conversationID != nil { preferences.saveWindowOrigin(panel.frame.origin); return }
            if cancelled { dragPose = MotionPose() }
            preferences.saveWindowOrigin(panel.frame.origin)
            send(.dragEnded)
        }
    }

    private func reply(to text: String) {
        guard !ended, shown else { return }
        discardReply()
        chatPanel?.setStatus(nil)
        send(.llmRequestStarted)
        guard state == .thinking else {
            chatPanel?.setStatus("等大白停下来，再发一次就好。")
            return
        }

        let connection = settingsForm.connection
        if connection.provider == .local {
            let reply = LocalReplyEngine.reply(to: text)
            presentReply(reply.message.content, emotion: reply.emotion)
            return
        }
        guard let config = connection.configuration else { failReply(.invalidConfiguration); return }
        // Both entry points have already appended the submitted user message.
        let history = Array(conversation.messages.dropLast().dropFirst(historyStart))
        let id = UUID()
        replyID = id
        updateChatMode()
        replyTask = Task { [weak self, llmClient] in
            do {
                let raw = try await llmClient.reply(config: config,
                    system: "你是温和的桌面陪伴助手大白。请用简短中文回答，可用一个 [happy]、[care]、[neutral]、[sleepy]、[excited] 或 [dizzy] 标签表达心情。",
                    history: history, input: text)
                let parsed = EmotionTagParser.parse(raw)
                let body = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { throw LLMClientError.invalidResponse }
                guard let self, self.replyID == id, !Task.isCancelled else { return }
                self.presentReply(body, emotion: parsed.emotion ?? .neutral)
            } catch {
                guard let self, self.replyID == id, !Task.isCancelled else { return }
                self.failReply(error as? LLMClientError ?? .network(.unknown))
            }
        }
    }

    private func presentReply(_ text: String, emotion: PetEmotion) {
        guard shown, !ended, state == .thinking else { return }
        replyID = nil
        replyTask = nil
        conversation.messages.append(.init(role: .assistant, content: text))
        send(.llmReplyReceived(emotion: emotion))
        guard case .speaking = state else { return }
        let speaking = speakReply(text)
        if !speaking, conversationID != nil {
            send(.speakingFinished)
            scheduleListening(notice: text)
        } else {
            showBubble(text, completion: speaking ? nil : .speakingFinished)
        }
    }

    private func failReply(_ error: LLMClientError) {
        replyID = nil
        replyTask = nil
        send(.llmFailed)
        let explanation = SettingsView.message(for: error)
        chatPanel?.setStatus(explanation)
        if shown { showBubble(explanation) }
        scheduleListening(after: .seconds(1), notice: explanation)
    }

    private func discardReply() {
        replyID = nil
        replyTask?.cancel()
        replyTask = nil
    }

    private func endPendingReply() {
        discardReply()
        if state == .thinking { send(.llmFailed) }
    }

    private func invalidateConversation() {
        conversationID = nil
        conversationRoute = nil
        nextTurn?.cancel()
        nextTurn = nil
    }

    private func endDialogue() {
        invalidateConversation()
        resetTurn()
    }

    private func resetTurn() {
        nextTurn?.cancel()
        nextTurn = nil
        endPendingReply()
        cancelVoiceInput()
        if case .speaking = state { send(.speakingFinished) }
        hideBubble()
    }

    private func updateChatMode() {
        let selection = settingsForm.connection
        let title: String
        switch selection.provider {
        case .local: title = "本地模式"
        case .anthropic: title = "Claude"
        case .openAICompatible:
            let url = selection.validatedBaseURL
            if url?.host?.lowercased() == "api.deepseek.com" { title = "DeepSeek" }
            else if url?.port == 11434 { title = "Ollama" }
            else if url?.host?.lowercased() == "api.openai.com" { title = "OpenAI" }
            else { title = "OpenAI 兼容" }
        }
        chatPanel?.setModeTitle(replyID == nil ? title : title + " · 思考中…")
    }

    /// Dispatch a reducer event and apply the returned effects in order.
    func send(_ event: PetEvent) {
        guard !ended else { return }
        pending.append(event)
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        // AppKit can call back synchronously while a window is being resized.
        while !pending.isEmpty && !ended {
            let next = pending.removeFirst()
            let old = state
            let effects = machine.handle(next)
            guard state != old || !effects.isEmpty else { continue }
            if state != old {
                if old == .thinking {
                    discardReply()
                    updateChatMode()
                }
                if case .speaking = old, next == .speakingFinished { perform(.stopTTS) }
                generation &+= 1
                typingMonitor.stop()
                view.stopAnimations()
                if case .rolling = old { roll.cancel() }
                // The poke bubble outlives its shorter squash animation.
                if old != .poked || state != .idle { hideBubble() }
            }
            effects.forEach(perform)
            guard !ended else { break }
            guard state != old else { continue }
            switch state {
            case .idle where old == .dragging && animates && !system.reduceMotion && dragPose != MotionPose():
                let token = generation
                view.animateDragRelease(from: dragPose) { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.updateIdle()
                }
            case .idle:
                view.render(pose: MotionPose())
                updateIdle()
            case .poked:
                guard animates && !system.reduceMotion else { send(.pokeAnimationCompleted); continue }
                let token = generation
                view.animatePoke { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.send(.pokeAnimationCompleted)
                }
            case .listening, .thinking, .speaking:
                updateDialogueArtwork()
            case .healthReminder:
                view.showHealthScan(reducedMotion: !animates || system.reduceMotion)
            default: break
            }
            if !voiceAvailable, voicePermissions.isPending { cancelVoiceInput() }
            updateBellyControl()
            updateHealthReminders()
            panel.requestHitTest()
        }
    }

    private func perform(_ effect: PetEffect) {
        switch effect {
        case .startRollWindowAnimation(let direction):
            let geometry = PetRollController.Geometry(bodyBounds: view.paintBounds, anchor: view.anchor,
                                                       rollingBodyWidth: view.rollingBodyWidth)
            if !animates || roll.start(geometry: geometry, preferredDirection: direction,
                                       reducedMotion: system.reduceMotion) != .started { send(.rollCompleted) }
        case .showTransientBubble(let text):
            if shown { showBubble(text, completion: state == .healthReminder ? .healthReminderDismissed : nil) }
        case .stopMicrophone:
            voiceAttempt = nil
            voicePhase = .idle
            let session = microphoneSession
            microphoneSession = nil
            session?.stop()
        case .stopTTS:
            let session = speechSession
            speechSession = nil
            session?.stop()
        case .stopCamera:
            let session = cameraSession
            cameraSession = nil
            session?.stop()
        case .enqueueDeferredHealthReminder: healthMonitor.deferReminder()
        }
    }

    private func showBubble(_ text: String, completion: PetEvent? = nil) {
        guard let area = panel.screen?.visibleFrame else {
            if let completion { send(completion) }
            return
        }
        hideBubble()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.maximumNumberOfLines = 5
        label.lineBreakMode = .byTruncatingTail
        let available = max(1, min(310, area.width - 24))
        let cell = label.cell!
        let measured = cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: available, height: 120))
        label.setFrameSize(CGSize(width: ceil(min(measured.width, available)), height: ceil(min(measured.height, 120))))
        let size = CGSize(width: label.frame.width + 24, height: label.frame.height + 14)
        let pet = panel.frame
        let above = pet.maxY + 4
        let y = above + size.height <= area.maxY ? above : pet.minY - 4 - size.height
        var frame = ScreenGeometry.clampedFrame(CGRect(origin: CGPoint(x: pet.midX - size.width / 2, y: y),
                                                       size: size), to: area)
        if let chat = chatPanel?.window, chat.isVisible, frame.intersects(chat.frame) {
            let sides = [pet.minX - size.width - 4, pet.maxX + 4]
            for x in sides {
                let beside = CGRect(origin: CGPoint(x: x, y: pet.midY - size.height / 2), size: size)
                if area.contains(beside), !beside.intersects(chat.frame) {
                    frame = beside
                    break
                }
            }
        }
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = panel.collectionBehavior
        window.level = panel.level
        let plate = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        plate.material = .popover
        plate.state = .active
        plate.wantsLayer = true
        plate.layer?.cornerRadius = min(16, size.height/2)
        plate.layer?.masksToBounds = true
        label.setFrameOrigin(CGPoint(x: 12, y: 7))
        plate.addSubview(label)
        window.contentView = plate
        bubble = window
        panel.addChildWindow(window, ordered: .above)
        let timer = Timer(fire: Date(timeIntervalSinceNow: DesignTokens.motion.pokeBubbleDuration), interval: 0, repeats: false) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, self.bubble === window else { return }
                self.hideBubble()
                if let completion { self.send(completion) }
            }
        }
        bubbleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func hideBubble() {
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        if let bubble {
            panel.removeChildWindow(bubble)
            bubble.close()
            self.bubble = nil
        }
    }

    func writeSmoke(to url: URL) throws {
        let flags: [(NSWindow.CollectionBehavior, String)] = [(.canJoinAllSpaces, "canJoinAllSpaces"),
            (.fullScreenAuxiliary, "fullScreenAuxiliary"), (.stationary, "stationary"), (.ignoresCycle, "ignoresCycle")]
        let report: [String: Any] = [
            "activationPolicy": NSApp.activationPolicy() == .accessory ? "accessory" :
                NSApp.activationPolicy() == .regular ? "regular" : "prohibited",
            "isOpaque": panel.isOpaque, "hasShadow": panel.hasShadow,
            "level": panel.level == .floating ? "floating" : String(panel.level.rawValue),
            "initialState": String(describing: state),
            "collectionBehavior": flags.compactMap { panel.collectionBehavior.contains($0.0) ? $0.1 : nil },
            "microphoneSession": microphoneSession.map { String(describing: type(of: $0)) as Any } ?? NSNull(),
            "cameraSession": cameraSession.map { String(describing: type(of: $0)) as Any } ?? NSNull()
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
