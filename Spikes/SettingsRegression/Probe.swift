import AppKit
import DabaiPetCore
import DabaiPetUI
import SwiftUI

private actor DelayedTransport: LLMTransport {
    var inFlight = false
    var completed = false
    var delayMs: UInt64 = 450

    func reset(delay: UInt64 = 450) {
        inFlight = false
        completed = false
        delayMs = delay
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        inFlight = true
        try await Task.sleep(for: .milliseconds(delayMs))
        try Task.checkCancellation()
        completed = true
        return (Data(#"{"data":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main @MainActor enum SettingsRegression {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                print("Settings regression failed:", error)
                exit(1)
            }
        }
        app.run()
    }

    static func run() async throws {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            let suffix = detail.isEmpty ? "" : " (\(detail))"
            print("\(ok ? "PASS" : "FAIL") \(name)\(suffix)")
            fflush(nil)
            if !ok { failures += 1 }
        }
        func tick(_ ms: UInt64 = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }

        let suite = "com.dabaipet.settings-regression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = InMemorySecretStore()
        let transport = DelayedTransport()
        let controller = try PetController(
            preferences: PreferencesStore(defaults: defaults),
            settingsConnectionActions: .configured(store: store, transport: transport)
        )
        let delegate = AppDelegate(controller: controller)
        defer { delegate.shutdown() }
        delegate.start()
        await tick()

        func findSecureField(in view: NSView) -> NSSecureTextField? {
            if let f = view as? NSSecureTextField { return f }
            return view.subviews.lazy.compactMap { findSecureField(in: $0) }.first
        }
        // Window-local events for the default 520 x 420 settings form.
        func clickWindow(_ point: CGPoint, in window: NSWindow) {
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: kind, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1
                )!
                NSApp.postEvent(event, atStart: false)
            }
        }
        func allText(in view: NSView) -> [String] {
            var list: [String] = []
            if let tf = view as? NSTextField, !(tf is NSSecureTextField) { list.append(tf.stringValue) }
            for sub in view.subviews { list.append(contentsOf: allText(in: sub)) }
            return list
        }
        func enterSecure(_ text: String, in window: NSWindow, root: NSView) async {
            guard let field = findSecureField(in: root) else { return }
            window.makeFirstResponder(field)
            await tick(60)
            if let editor = window.firstResponder as? NSTextView {
                editor.selectAll(nil)
                editor.insertText(text, replacementRange: editor.selectedRange())
            } else {
                field.stringValue = text
            }
            await tick(100)
        }
        func renderBytes(of view: BaymaxLayerView) -> [UInt8] {
            let size = view.bounds.size
            let w = max(1, Int(ceil(size.width)))
            let h = max(1, Int(ceil(size.height)))
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            pixels.withUnsafeMutableBytes { buf in
                if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                       bytesPerRow: w * 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    view.renderArtwork(in: ctx)
                }
            }
            return pixels
        }

        // 1. Right-click submenu "互动开关" -> "静音语音播报"
        let overlay = controller.panel.contentView!.subviews.compactMap { $0 as? PetInputOverlayView }.first!
        let center = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        let rightEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: overlay.convert(center, to: nil),
                                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: controller.panel.windowNumber, context: nil,
                                            eventNumber: 1, clickCount: 1, pressure: 1)!
        let bodyMenu = overlay.menu(for: rightEvent)
        let actionsSubmenu = bodyMenu?.item(withTitle: "互动开关")?.submenu
        let muteItem = actionsSubmenu?.item(withTitle: "静音语音播报")
        print("OBS right-click-actions-items=\(actionsSubmenu?.items.map(\.title) ?? [])")
        check("right-click actions submenu contains 静音语音播报", muteItem != nil)
        if let actionsSubmenu, let muteItem {
            let statusMenu = delegate.statusItem!.menu!
            let statusMuteIdx = statusMenu.indexOfItem(withTitle: "静音播报")
            let statusMuteItem = statusMenu.item(at: statusMuteIdx)!
            check("initial mute off in right-click", muteItem.state == .off && !controller.isSpeechMuted)

            actionsSubmenu.performActionForItem(at: actionsSubmenu.index(of: muteItem))
            delegate.menuNeedsUpdate(statusMenu)
            check("right-click toggle enables mute everywhere",
                  controller.isSpeechMuted && muteItem.state == .on && statusMuteItem.state == .on &&
                  PreferencesStore(defaults: defaults).loadPreferences().isSpeechMuted)

            statusMenu.performActionForItem(at: statusMuteIdx)
            delegate.menuNeedsUpdate(statusMenu)
            check("menu bar toggle syncs back to right-click item",
                  !controller.isSpeechMuted && muteItem.state == .off && statusMuteItem.state == .off &&
                  !PreferencesStore(defaults: defaults).loadPreferences().isSpeechMuted)
        }

        // 2. Settings: same-endpoint Model edit vs endpoint/provider change
        let statusMenu = delegate.statusItem!.menu!
        statusMenu.performActionForItem(at: statusMenu.indexOfItem(withTitle: "设置…"))
        await tick(150)
        let settingsWindow = NSApp.windows.first { $0.title == "大白设置" }!
        let host = settingsWindow.contentViewController as! NSHostingController<SettingsView>
        let binding = host.rootView.connection
        let endpointA = "http://127.0.0.1:22459/" + UUID().uuidString
        let endpointB = endpointA + "/other"
        let draftKey = "sk-fixture-keep-" + UUID().uuidString

        binding.wrappedValue = .init(provider: .openAICompatible, baseURL: endpointA, model: "gpt-4o-mini")
        await tick(150)
        host.view.layoutSubtreeIfNeeded()

        await enterSecure(draftKey, in: settingsWindow, root: host.view)
        let entered = findSecureField(in: host.view)?.stringValue ?? ""
        print("OBS before-model-edit secureFieldLen=\(entered.count)")
        check("fixture typed draft key into SecureField", entered == draftKey)

        // Edit ONLY model on same provider + baseURL
        binding.wrappedValue.model = "deepseek-chat"
        await tick(150)
        let afterModelEdit = findSecureField(in: host.view)?.stringValue ?? ""
        print("OBS after-model-edit secureFieldLen=\(afterModelEdit.count)")
        check("same-endpoint model edit preserves unsaved apiKey", afterModelEdit == draftKey)

        // Save key after model edit and verify it persists to store and clears field
        clickWindow(CGPoint(x: 64, y: 162), in: settingsWindow)
        await tick(200)
        let configA = LLMConfig(provider: .openAICompatible, baseURL: URL(string: endpointA)!, model: "deepseek-chat")
        let accountA = try ConnectionServices.account(for: configA)
        let stored = await store.read(account: accountA)
        let afterSave = findSecureField(in: host.view)?.stringValue ?? ""
        print("OBS save-after-model storedMatch=\(stored == draftKey) afterSaveLen=\(afterSave.count)")
        check("save after model edit persists key and clears field", stored == draftKey && afterSave.isEmpty)

        // Endpoint change MUST still clear unsaved apiKey (T3.2 contract)
        await enterSecure("sk-fixture-clear-" + UUID().uuidString, in: settingsWindow, root: host.view)
        binding.wrappedValue.baseURL = endpointB
        await tick(150)
        let afterEndpointChange = findSecureField(in: host.view)?.stringValue ?? ""
        print("OBS after-endpoint-change secureFieldLen=\(afterEndpointChange.count)")
        check("endpoint change still clears unsaved apiKey", afterEndpointChange.isEmpty)

        // Provider change MUST still clear unsaved apiKey
        await enterSecure("sk-fixture-provider", in: settingsWindow, root: host.view)
        binding.wrappedValue.provider = .anthropic
        await tick(150)
        let afterProviderChange = findSecureField(in: host.view)?.stringValue ?? ""
        check("provider change still clears unsaved apiKey", afterProviderChange.isEmpty)

        // 3. Settings: closing window (red X) clears draft & cancels in-flight test
        binding.wrappedValue = .init(provider: .openAICompatible, baseURL: endpointA, model: "deepseek-chat")
        await tick(150)
        await transport.reset(delay: 450)
        let closeDraft = "sk-fixture-close-" + UUID().uuidString
        await enterSecure(closeDraft, in: settingsWindow, root: host.view)
        clickWindow(CGPoint(x: 150, y: 162), in: settingsWindow)
        await tick(100)
        let startedBeforeClose = await transport.inFlight
        settingsWindow.close()
        await tick(600)
        let completedAfterClose = await transport.completed
        statusMenu.performActionForItem(at: statusMenu.indexOfItem(withTitle: "设置…"))
        await tick(150)
        let afterCloseKey = findSecureField(in: host.view)?.stringValue ?? ""
        let textsAfterReopen = allText(in: host.view)
        let hasStaleStatus = textsAfterReopen.contains { $0.contains("正在处理") || $0.contains("连接成功") || $0.contains("连接失败") }
        print("OBS window-close started=\(startedBeforeClose) completedAfterClose=\(completedAfterClose) afterCloseKeyLen=\(afterCloseKey.count) hasStaleStatus=\(hasStaleStatus)")
        check("closing settings window clears unsaved apiKey draft", afterCloseKey.isEmpty)
        check("closing settings window cancels in-flight test and clears status",
              startedBeforeClose && !completedAfterClose && !hasStaleStatus)

        // 4. Dynamic Light <-> Dark appearance switch updates rendered artwork pixels
        let panel = controller.panel
        panel.appearance = NSAppearance(named: .aqua)
        await tick(150)
        let lightView = panel.contentView as! BaymaxLayerView
        let lightPixels = renderBytes(of: lightView)

        panel.appearance = NSAppearance(named: .darkAqua)
        await tick(150)
        let darkView = panel.contentView as! BaymaxLayerView
        let darkPixels = renderBytes(of: darkView)
        let diffLightToDark = zip(lightPixels, darkPixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }

        panel.appearance = NSAppearance(named: .aqua)
        await tick(150)
        let restoredView = panel.contentView as! BaymaxLayerView
        let restoredPixels = renderBytes(of: restoredView)
        let diffDarkToLight = zip(darkPixels, restoredPixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        let diffLightVsRestored = zip(lightPixels, restoredPixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }

        print("OBS appearance-pixels lightApp=\(lightView.desktopAppearance) darkApp=\(darkView.desktopAppearance) diffL2D=\(diffLightToDark) diffD2L=\(diffDarkToLight) diffRestore=\(diffLightVsRestored)")
        check("dynamic Light->Dark updates rendered artwork pixels",
              lightView.desktopAppearance == .light && darkView.desktopAppearance == .dark && diffLightToDark > 0)
        check("dynamic Dark->Light restores rendered artwork pixels",
              restoredView.desktopAppearance == .light && diffDarkToLight > 0 && diffLightVsRestored == 0)
        check("overlay remains attached after appearance switch",
              restoredView.subviews.contains { $0 is PetInputOverlayView })

        print("SUMMARY failures=\(failures)")
        fflush(nil)
        if failures > 0 { throw NSError(domain: "SettingsRegression", code: failures) }
    }
}
