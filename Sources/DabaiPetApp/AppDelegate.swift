import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum DynamicItem: Int {
        case visibility = 1
        case mute
    }

    private let controller: PetController
    private(set) var statusItem: NSStatusItem?

    init(controller: PetController) {
        self.controller = controller
    }

    func start() {
        guard statusItem == nil else { return }
        controller.show()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.makeIcon()
        item.button?.toolTip = "大白"
        item.button?.setAccessibilityLabel("大白")
        item.menu = makeMenu()
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    func shutdown() {
        controller.shutdown()
        guard let item = statusItem else { return }
        item.menu?.delegate = nil
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: DynamicItem.visibility.rawValue)?.title = visibilityTitle
        menu.item(withTag: DynamicItem.mute.rawValue)?.state = muteState
    }

    private var visibilityTitle: String {
        controller.isVisible ? "隐藏大白" : "显示大白"
    }

    private var muteState: NSControl.StateValue {
        controller.isSpeechMuted ? .on : .off
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let visibility = menu.addItem(withTitle: visibilityTitle, action: #selector(toggleVisibility(_:)), keyEquivalent: "")
        visibility.target = self
        visibility.tag = DynamicItem.visibility.rawValue

        let reset = menu.addItem(withTitle: "归位到右下角", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self

        let mute = menu.addItem(withTitle: "静音播报", action: #selector(toggleMute(_:)), keyEquivalent: "")
        mute.target = self
        mute.tag = DynamicItem.mute.rawValue
        mute.state = muteState

        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出大白", action: #selector(quitPet), keyEquivalent: "")
        quit.target = self
        return menu
    }

    @objc private func toggleVisibility(_ item: NSMenuItem) {
        controller.toggleVisibility()
        item.title = visibilityTitle
    }

    @objc private func resetPosition() {
        controller.resetPosition()
    }

    @objc private func toggleMute(_ item: NSMenuItem) {
        controller.toggleSpeechMute()
        item.state = muteState
    }

    @objc private func openSettings() { controller.showSettings() }

    @objc private func quitPet() {
        controller.quit()
    }

    private static func makeIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }

            context.setFillColor(gray: 0, alpha: 1)
            context.fillEllipse(in: CGRect(x: 1, y: 3.5, width: 16, height: 11))
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 5.5, y: 8.5, width: 7, height: 1))
            context.fillEllipse(in: CGRect(x: 4, y: 7.5, width: 3, height: 3))
            context.fillEllipse(in: CGRect(x: 11, y: 7.5, width: 3, height: 3))
            return true
        }
        image.isTemplate = true
        return image
    }
}
