import AppKit
import DabaiPetCore
import DabaiPetUI

@MainActor
private final class BellyVoiceButton: NSButton {
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHiddenOrHasHiddenAncestor, window?.isVisible == true, let action else { return false }
        return sendAction(action, to: target)
    }
}

@MainActor
final class PetInputOverlayView: NSView {
    enum Input: Equatable {
        case dragBegan
        case dragChanged(horizontalVelocity: CGFloat) // Signed screen points per second.
        case dragEnded(cancelled: Bool)
        case poke, rollRequested, chatRequested, healthScanRequested, toggleSpeechMute, toggleHealthReminder, settingsRequested, toggleTypingCompanion, closeRequested
    }

    enum BellyVoiceState { case hidden, idle, preparing, listening, finishing }

    private final class Press {
        let start: CGPoint
        let startTime: TimeInterval
        let windowOrigin: CGPoint
        let screen: NSScreen
        var previous: CGPoint
        var previousTime: TimeInterval
        var dragging = false
        let beganInBellyVoice: Bool
        var allowsBellyVoice: Bool

        init(at point: CGPoint, time: TimeInterval, origin: CGPoint, screen: NSScreen,
             beganInBellyVoice: Bool, allowsBellyVoice: Bool) {
            start = point
            previous = point
            startTime = time
            previousTime = time
            windowOrigin = origin
            self.screen = screen
            self.beganInBellyVoice = beganInBellyVoice
            self.allowsBellyVoice = allowsBellyVoice
        }
    }

    private let bodyHitTest: PetFloatingPanel.BodyHitTest
    private let clampFrame: @MainActor (CGRect, CGRect) -> CGPoint
    private let mouseLocation: @MainActor () -> CGPoint
    private let onInput: @MainActor (Input) -> Void
    private var press: Press?
    var isInteractionActive: Bool { press != nil }
    var onBellyVoice: (() -> Void)? {
        didSet {
            invalidateBellyPress()
            updateBellyButton()
        }
    }
    var bellyVoiceState: BellyVoiceState = .hidden {
        didSet {
            guard bellyVoiceState != oldValue else { return }
            // An active conversation keeps the same Stop action across visible phases.
            if !isVoiceConversationActive { invalidateBellyPress() }
            updateBellyButton()
        }
    }
    var isVoiceConversationActive = false {
        didSet {
            guard isVoiceConversationActive != oldValue else { return }
            // A press begun as Stop must never become Start if the session ends.
            invalidateBellyPress()
            updateBellyButton()
        }
    }
    private lazy var bellyButton: NSButton = {
        let button = BellyVoiceButton(frame: .zero)
        button.target = self
        button.action = #selector(activateBellyVoice)
        button.title = ""
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.isHidden = true
        button.wantsLayer = true
        button.setAccessibilityRole(.button)
        return button
    }()
    var speechMuted = false {
        didSet { muteItem.state = speechMuted ? .on : .off }
    }
    private lazy var muteItem: NSMenuItem = {
        let item = NSMenuItem(title: "静音语音播报", action: #selector(toggleMute), keyEquivalent: "")
        item.target = self
        return item
    }()
    var typingEnabled = false {
        didSet { typingItem.state = typingEnabled ? .on : .off }
    }
    private lazy var typingItem: NSMenuItem = {
        let item = NSMenuItem(title: "敲键陪伴（仅节拍）", action: #selector(toggleTyping), keyEquivalent: "")
        item.target = self
        return item
    }()
    var remindersEnabled = false {
        didSet { reminderItem.state = remindersEnabled ? .on : .off }
    }
    private lazy var reminderItem: NSMenuItem = {
        let item = NSMenuItem(title: "久坐健康提醒", action: #selector(toggleReminders), keyEquivalent: "")
        item.target = self
        return item
    }()
    private lazy var bodyMenu: NSMenu = {
        let menu = NSMenu()
        for (title, action) in [("滚动一下", #selector(roll)), ("和大白聊聊…", #selector(openChat)),
                                ("健康扫描", #selector(healthScan))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        let actions = NSMenu(title: "互动开关")
        actions.addItem(muteItem)
        actions.addItem(reminderItem)
        actions.addItem(typingItem)
        menu.addItem(withTitle: actions.title, action: nil, keyEquivalent: "").submenu = actions
        menu.addItem(withTitle: "设置 API 与偏好…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭大白", action: #selector(closePet), keyEquivalent: "").target = self
        return menu
    }()

    /// Supply the same content-coordinate hit test as the panel and install
    /// this transparent view above the renderer.
    init(frame: NSRect, bodyHitTest: @escaping PetFloatingPanel.BodyHitTest,
         clampFrame: @escaping @MainActor (_ proposed: CGRect, _ visible: CGRect) -> CGPoint = { proposed, visible in
             CGPoint(x: max(visible.minX, min(proposed.minX, visible.maxX - proposed.width)),
                     y: max(visible.minY, min(proposed.minY, visible.maxY - proposed.height)))
         },
         mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
         onInput: @escaping @MainActor (Input) -> Void) {
        self.bodyHitTest = bodyHitTest
        self.clampFrame = clampFrame
        self.mouseLocation = mouseLocation
        self.onInput = onInput
        super.init(frame: frame)
        addSubview(bellyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Create the input overlay programmatically") }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateBellyButton()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateBellyButton()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBellyButton()
    }

    private func updateBellyButton() {
        // The roll controller widens the window without changing the art's idle geometry.
        guard bellyVoiceState != .hidden, press?.dragging != true,
              let art = superview as? BaymaxLayerView,
              bounds.width <= art.geometry.idleWindowSize.width + 1,
              bounds.height <= art.geometry.idleWindowSize.height + 1 else {
            invalidateBellyPress()
            bellyButton.isHidden = true
            bellyButton.setAccessibilityElement(false)
            return
        }
        let layout = art.geometry
        let diameter = max(28, 30 * layout.scale)
        let torso = layout.torsoRect
        let center = convert(CGPoint(x: torso.midX, y: torso.midY - 8 * layout.scale), from: art)
        let frame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        guard bounds.contains(frame) else {
            invalidateBellyPress()
            bellyButton.isHidden = true
            bellyButton.setAccessibilityElement(false)
            return
        }

        let symbol: String
        let label: String
        switch (isVoiceConversationActive, bellyVoiceState) {
        case (_, .hidden): return
        case (true, _): (symbol, label) = ("stop.fill", "结束语音对话")
        case (false, .idle): (symbol, label) = ("mic.fill", "开始语音输入")
        case (false, .preparing): (symbol, label) = ("stop.fill", "取消语音准备")
        case (false, .listening): (symbol, label) = ("stop.fill", "停止录音")
        case (false, .finishing): (symbol, label) = ("hourglass", "正在完成语音输入")
        }
        let listening = bellyVoiceState == .listening
        let appearance: DesktopAppearance = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let accent = DesignTokens.palette(for: appearance).accentHeal
        let ink = NSColor(srgbRed: 0.13, green: 0.20, blue: 0.28, alpha: 1)
        let fill = listening ? NSColor(srgbRed: accent.r, green: accent.g, blue: accent.b, alpha: 0.4)
                             : NSColor.white.withAlphaComponent(0.83)
        let config = NSImage.SymbolConfiguration(pointSize: max(13, 15 * layout.scale), weight: .semibold)
        bellyButton.frame = frame
        bellyButton.layer?.cornerRadius = diameter / 2
        bellyButton.layer?.backgroundColor = fill.cgColor
        bellyButton.layer?.borderWidth = 1
        bellyButton.layer?.borderColor = ink.withAlphaComponent(listening ? 0.5 : 0.28).cgColor
        bellyButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        bellyButton.contentTintColor = ink
        bellyButton.toolTip = label
        bellyButton.setAccessibilityLabel(label)
        bellyButton.isEnabled = onBellyVoice != nil && (isVoiceConversationActive || bellyVoiceState != .finishing)
        bellyButton.setAccessibilityEnabled(bellyButton.isEnabled)
        bellyButton.isHidden = false
        bellyButton.setAccessibilityElement(true)
    }

    @objc private func activateBellyVoice() {
        let frame = bellyButton.frame
        guard let panel = window as? PetFloatingPanel, panel.isVisible,
              !bellyButton.isHidden, bellyButton.isEnabled,
              hitsBody(CGPoint(x: frame.midX, y: frame.midY)) else { return }
        // AXPress can invoke Stop while the mouse is still held on the button.
        if press?.allowsBellyVoice == true { invalidateBellyPress() }
        onBellyVoice?()
    }

    private func hitsBellyButton(with event: NSEvent) -> Bool {
        guard !bellyButton.isHidden, hitsBody(with: event) else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let rect = bellyButton.frame
        return hypot(point.x - rect.midX, point.y - rect.midY) <= rect.width / 2
    }

    private func invalidateBellyPress() {
        press?.allowsBellyVoice = false
        bellyButton.highlight(false)
    }

    private func hitsBody(_ local: CGPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), let content = window?.contentView else { return false }
        let point = content.convert(local, from: self)
        if let panel = window as? PetFloatingPanel { return panel.hitsInteractiveBody(at: point) }
        return bodyHitTest(point, 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep the overlay as the mouse responder so a press on the button can
        // become a normal pet drag. The native button handles accessibility actions.
        hitsBody(convert(point, from: superview)) ? self : nil
    }

    private func hitsBody(with event: NSEvent) -> Bool {
        event.window === window && hitsBody(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        cancelInteraction()
        guard let panel = window as? PetFloatingPanel, panel.isVisible, panel.isMonitoringPointer,
              let screen = panel.screen, hitsBody(with: event) else { return }
        let onButton = hitsBellyButton(with: event)
        let canActivate = onButton && bellyButton.isEnabled
        press = Press(at: mouseLocation(), time: event.timestamp, origin: panel.frame.origin, screen: screen,
                      beganInBellyVoice: onButton, allowsBellyVoice: canActivate)
        panel.setDragCapture(true)
        if canActivate { bellyButton.highlight(true) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        if press.allowsBellyVoice && !hitsBellyButton(with: event) { invalidateBellyPress() }
        updateDrag(press, time: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = press else { return }
        if current.allowsBellyVoice && !hitsBellyButton(with: event) { invalidateBellyPress() }
        updateDrag(current, time: event.timestamp)
        guard press === current else { return } // A callback may have closed or detached the view.
        finishPress(current, cancelled: false)
    }

    private func updateDrag(_ current: Press, time: TimeInterval) {
        guard let panel = window as? PetFloatingPanel, panel.isVisible, panel.isMonitoringPointer else {
            cancelInteraction()
            return
        }
        let point = mouseLocation()
        let dx = point.x - current.start.x
        let dy = point.y - current.start.y
        let moved = point != current.previous
        let dt = time - current.previousTime
        let vx = dt > 0 ? (point.x - current.previous.x) / dt : 0
        current.previous = point
        current.previousTime = max(current.previousTime, time)
        if !current.dragging {
            guard hypot(dx, dy) >= 3 || time - current.startTime >= 0.25 else { return }
            current.dragging = true // Latch even if the pointer travels back to its starting point.
            updateBellyButton()
            onInput(.dragBegan)
            guard press === current else { return }
        } else if !moved {
            return
        }
        let proposed = CGRect(origin: current.windowOrigin, size: panel.frame.size).offsetBy(dx: dx, dy: dy)
        let origin = clampFrame(proposed, current.screen.visibleFrame)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if press === current { onInput(.dragChanged(horizontalVelocity: vx)) }
    }

    private func finishPress(_ current: Press, cancelled: Bool) {
        press = nil
        bellyButton.highlight(false)
        (window as? PetFloatingPanel)?.setDragCapture(false)
        if current.dragging {
            updateBellyButton()
            onInput(.dragEnded(cancelled: cancelled))
        } else if !cancelled {
            if current.beganInBellyVoice {
                if current.allowsBellyVoice { activateBellyVoice() }
            } else {
                onInput(.poke)
            }
        }
    }

    /// Safe to call repeatedly before hiding the pet or interrupting its gesture.
    func cancelInteraction() {
        if let press { finishPress(press, cancelled: true) }
    }

    override func cancelOperation(_ sender: Any?) { cancelInteraction() }

    override func viewDidHide() {
        super.viewDidHide()
        cancelInteraction()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            cancelInteraction()
            let center = NotificationCenter.default
            if let window {
                center.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
                center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            if let newWindow {
                center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: newWindow)
                center.addObserver(self, selector: #selector(occlusionChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowWillClose(_ note: Notification) { cancelInteraction() }
    @objc private func occlusionChanged(_ note: Notification) {
        if window?.isVisible == false { cancelInteraction() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        hitsBody(with: event) ? bodyMenu : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelInteraction()
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        if press?.allowsBellyVoice == true { invalidateBellyPress() }
        super.scrollWheel(with: event)
    }

    @objc private func healthScan() { onInput(.healthScanRequested) }
    @objc private func toggleMute() { onInput(.toggleSpeechMute) }
    @objc private func toggleReminders() { onInput(.toggleHealthReminder) }
    @objc private func toggleTyping() { onInput(.toggleTypingCompanion) }
    @objc private func roll() { onInput(.rollRequested) }
    @objc private func openChat() { onInput(.chatRequested) }
    @objc private func openSettings() { onInput(.settingsRequested) }
    @objc private func closePet() { onInput(.closeRequested) }
}
