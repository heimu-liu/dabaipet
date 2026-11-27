import AppKit
import DabaiPetCore
import DabaiPetUI
import SwiftUI

private final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            close()
            return
        }
        super.sendEvent(event)
    }
}

private final class ChatFieldEditor: NSTextView {
    private(set) var confirmingCandidate = false

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && event.isARepeat { return }
        // The input method may replace the marked range before insertNewline
        // arrives. Keep the state from the beginning of this key dispatch.
        confirmingCandidate = isReturn && hasMarkedText()
        defer { confirmingCandidate = false }
        super.keyDown(with: event)
    }
}

@MainActor
final class ChatPanelController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Called after the native editor's submission is displayed as a user message.
    var onSend: ((String) -> Void)?
    /// Called when the native clear button clears the displayed conversation.
    var onClear: (() -> Void)?

    var onClose: (() -> Void)?
    var onVoice: (() -> Void)? { didSet { voiceButton.isHidden = onVoice == nil } }
    private lazy var voiceButton = button(symbol: "mic", label: "开始语音输入", action: #selector(toggleVoice))
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private weak var anchorWindow: NSWindow?
    private let entry = NSTextField()
    private let editor = ChatFieldEditor()
    private let mode = NSTextField(labelWithString: "本地模式")
    private let messages = NSView()
    private let transcript: ChatBubbleView.Transcript

    init(transcript: ChatBubbleView.Transcript = .init()) {
        self.transcript = transcript
        let bounds = CGRect(origin: .zero, size: DesignTokens.chatPanelSize)
        let panel = ChatPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "和大白聊聊"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        let glass = NSView(frame: bounds)
        let material = NSHostingView(rootView: RoundedRectangle(cornerRadius: DesignTokens.chatPanelCornerRadius)
            .fill(.ultraThinMaterial))
        material.frame = glass.bounds
        material.autoresizingMask = [.width, .height]
        glass.addSubview(material)
        panel.contentView = glass

        mode.font = .systemFont(ofSize: 12, weight: .medium)
        mode.textColor = .secondaryLabelColor
        let clear = button(symbol: "trash", label: "清空对话", action: #selector(clearConversation))
        let close = button(symbol: "xmark", label: "关闭聊天", action: #selector(closeChat))
        voiceButton.isHidden = true
        let header = NSStackView(views: [mode, NSView(), clear, close])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        installMessageView(NSHostingView(rootView: ChatBubbleView(transcript: transcript)))

        editor.isFieldEditor = true
        editor.isRichText = false
        entry.delegate = self
        entry.placeholderString = "输入消息…"
        entry.setAccessibilityLabel("聊天输入框")
        entry.bezelStyle = .roundedBezel
        entry.font = .systemFont(ofSize: 14)
        panel.initialFirstResponder = entry

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        let inputRow = NSStackView(views: [entry, voiceButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 6
        let composer = NSStackView(views: [statusLabel, inputRow])
        composer.orientation = .vertical
        composer.alignment = .leading
        composer.spacing = 4
        inputRow.widthAnchor.constraint(equalTo: composer.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(lessThanOrEqualTo: composer.widthAnchor).isActive = true
        for child in [header, messages, composer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 12),
                child.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -12)
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: glass.topAnchor, constant: 8),
            messages.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            messages.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            composer.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func button(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                              target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    /// Replaces only the message area, preserving the native editor.
    func installMessageView(_ content: NSView) {
        messages.subviews.forEach { $0.removeFromSuperview() }
        content.frame = messages.bounds
        content.autoresizingMask = [.width, .height]
        messages.addSubview(content)
    }

    /// Replaces the displayed conversation with messages in chronological order.
    func setMessages(_ messages: [ChatMessage]) { transcript.messages = messages }

    func appendMessage(_ message: ChatMessage) { transcript.messages.append(message) }

    /// Clears the displayed conversation. The native clear button also calls `onClear`.
    func clearMessages() { transcript.messages.removeAll() }

    func setModeTitle(_ title: String) { mode.stringValue = title }

    func show(anchoredTo pet: NSWindow) {
        guard let window, pet.screen != nil else { return }
        if anchorWindow !== pet {
            stopFollowing()
            anchorWindow = pet
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                center.addObserver(self, selector: #selector(positionPanel), name: name, object: pet)
            }
            center.addObserver(self, selector: #selector(positionPanel),
                               name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        }
        positionPanel()
        window.makeKeyAndOrderFront(nil)
        if window.firstResponder !== editor { window.makeFirstResponder(entry) }
    }

    @objc private func positionPanel() {
        guard let pet = anchorWindow, let screen = pet.screen, let window else { return }
        let frame = ScreenGeometry.chatPanelFrame(petFrame: pet.frame, visibleFrame: screen.visibleFrame)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    private func stopFollowing() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        if let anchorWindow {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: anchorWindow)
            }
        }
        anchorWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        // A reusable field editor can retain preedit text even after its panel
        // closes. Keep the committed draft and end only the marked range.
        if editor.hasMarkedText() {
            editor.insertText("", replacementRange: editor.markedRange())
            editor.inputContext?.discardMarkedText()
            entry.stringValue = editor.string
        }
        stopFollowing()
        onClose?()
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === entry ? editor : nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if editor.confirmingCandidate || textView.hasMarkedText() {
            if textView.hasMarkedText() { textView.unmarkText() }
            return true
        }
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        textView.string = ""
        entry.stringValue = ""
        appendMessage(ChatMessage(role: .user, content: text))
        onSend?(text)
        return true
    }

    @objc private func clearConversation() {
        clearMessages()
        onClear?()
    }

    func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    func setVoiceStatus(_ text: String?, buttonLabel: String = "开始语音输入", symbol: String = "mic", enabled: Bool = true) {
        setStatus(text)
        voiceButton.isEnabled = enabled
        voiceButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: buttonLabel)
        voiceButton.toolTip = buttonLabel
        voiceButton.setAccessibilityLabel(buttonLabel)
        voiceButton.wantsLayer = true
        voiceButton.layer?.removeAnimation(forKey: "recording")
        let recording = symbol == "stop.circle"
        let palette = DesignTokens.palette(for: voiceButton.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
        let color = palette.accentHeal
        voiceButton.contentTintColor = recording ? NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1) : .secondaryLabelColor
        if recording && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.60
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            voiceButton.layer?.add(pulse, forKey: "recording")
        }
    }

    @objc private func toggleVoice() { onVoice?() }

    @objc private func closeChat() { close() }
}
