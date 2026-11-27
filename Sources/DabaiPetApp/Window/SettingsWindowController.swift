import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(content: NSViewController? = nil) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "大白设置"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 360, height: 240)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        if let content { installContent(content) }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    /// Accepts an AppKit controller or an NSHostingController for SettingsView.
    func installContent(_ controller: NSViewController) {
        guard let window, window.contentViewController !== controller else { return }
        let frame = window.frame
        window.contentViewController = controller
        window.setFrame(frame, display: window.isVisible)
    }

    func present() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        // Both settings commands explicitly request keyboard focus from another app.
        NSApp.activate(ignoringOtherApps: true)
    }

    // The chat and pet are floating panels. Settings needs their level when
    // focused, and can return to normal stacking when the user switches away.
    func windowDidBecomeKey(_ notification: Notification) { window?.level = .floating }
    func windowDidResignKey(_ notification: Notification) { window?.level = .normal }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
