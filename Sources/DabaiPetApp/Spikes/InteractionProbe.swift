import AppKit

@MainActor enum InteractionProbe {
    static func run(_ arguments: [String]) throws {
        var auto = false
        var out: URL?
        var args = arguments.makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--auto" where !auto: auto = true
            case "--out" where out == nil:
                guard let path = args.next(), !path.isEmpty, !path.hasPrefix("--") else {
                    throw ProbeError.message("--out requires a file path")
                }
                out = URL(fileURLWithPath: path)
            default: throw ProbeError.message("Expected [--auto] [--out FILE]")
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let session = InteractionSession(auto: auto, output: out)
        try session.run()
    }
}

private enum ProbeError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): message } }
}

@MainActor final class InteractionSession: NSObject {
    private let auto: Bool
    private let output: URL?
    private let screens = NSScreen.screens
    private var screenIndex = 0
    private let body = ProbeBodyView()
    private let panel = ProbeBodyPanel(contentRect: CGRect(origin: .zero, size: ProbeShape.idleSize),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var chat: ProbeChatPanel?
    private var previousApp: NSRunningApplication?
    private var status: NSStatusItem?
    private var monitors = [Any]()
    private var hitTimer: Timer?
    private var lastHit = 0.0
    private var events = [[String: Any]]()
    private var rollResults = [[String: Any]]()
    private var activeRoll: ProbeRoll?
    private var rollScreen = ""
    private var rollStart = 0.0
    private var observedFrames = 0
    private var maxAngleDegrees = 0.0
    private var framesContained = true
    private var displayLink: CADisplayLink?
    private var watchdog: Timer?
    private var expandedFrame = CGRect.zero
    private var finishing = false
    var rolling: Bool { activeRoll != nil }

    init(auto: Bool, output: URL?) { self.auto = auto; self.output = output }

    private func screenID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
    }

    func run() throws {
        guard !screens.isEmpty else { throw ProbeError.message("No connected screen") }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        body.session = self
        panel.contentView = body
        move(to: screens[0])
        panel.orderFrontRegardless()
        if auto {
            DispatchQueue.main.async { self.autoRoll() }
        } else {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "大白探针"
            item.menu = makeMenu()
            status = item
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
                self?.scheduleHit()
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
                self?.scheduleHit()
                return event
            }) { monitors.append(local) }
            refreshHit()
        }
        defer {
            monitors.forEach { NSEvent.removeMonitor($0) }
            hitTimer?.invalidate()
            displayLink?.invalidate()
            watchdog?.invalidate()
            if let status { NSStatusBar.system.removeStatusItem(status) }
            closeChat()
            panel.orderOut(nil)
        }
        NSApp.run()
        let hardware = screens.map { screen -> [String: Any] in
            ["id": screenID(screen), "name": screen.localizedName, "frame": probeRect(screen.frame),
             "visibleFrame": probeRect(screen.visibleFrame), "backingScale": screen.backingScaleFactor,
             "safeAreaTop": screen.safeAreaInsets.top, "geometry": geometry(on: screen.visibleFrame)]
        }
        let fixture = CGRect(x: -1536, y: -320, width: 1480, height: 920)
        let report: [String: Any] = [
            "mode": auto ? "automatic" : "manual", "physicalScreens": hardware,
            "syntheticNegativeOrigin": ["visibleFrame": probeRect(fixture), "geometry": geometry(on: fixture)],
            "rolls": rollResults, "observedEvents": events,
            "humanSignoff": "pending", "monitorsInstalled": monitors.count
        ]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) + Data([10])
        if let output { try bytes.write(to: output, options: .atomic) }
        FileHandle.standardOutput.write(bytes)
        let allGeometryPassed = (screens.map(\.visibleFrame) + [fixture]).allSatisfy {
            geometry(on: $0).values.allSatisfy { $0 }
        }
        if auto && (!allGeometryPassed || rollResults.count != screens.count || rollResults.contains { $0["passed"] as? Bool != true }) {
            throw ProbeError.message("A physical screen roll was incomplete or exceeded its bounds")
        }
    }

    private func geometry(on frame: CGRect) -> [String: Bool] {
        var result = [String: Bool]()
        for (label, x, y) in [("bottomLeft", frame.minX, frame.minY),
                              ("bottomRight", frame.maxX, frame.minY),
                              ("topLeft", frame.minX, frame.maxY), ("topRight", frame.maxX, frame.maxY)] {
            let rect = CGRect(origin: CGPoint(x: x, y: y), size: ProbeShape.idleSize)
            let plan = ProbeRoll(at: rect, visible: frame, reducedMotion: false)
            result[label] = plan.geometryPasses()
        }
        return result
    }

    private func move(to screen: NSScreen) {
        let visible = screen.visibleFrame
        let rect = CGRect(origin: CGPoint(x: visible.maxX - ProbeShape.idleSize.width - 16,
                                          y: visible.minY + 28), size: ProbeShape.idleSize)
        panel.setFrame(probeClamp(rect, to: visible), display: true)
    }

    func record(_ kind: String, _ details: [String: Any] = [:]) {
        var row = details
        row["event"] = kind
        row["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        events.append(row)
    }

    private func scheduleHit() {
        guard hitTimer == nil, !rolling else { return }
        let remaining = 1.0 / 60 - (ProcessInfo.processInfo.systemUptime - lastHit)
        if remaining <= 0 { refreshHit(); return }
        let timer = Timer(timeInterval: remaining, target: self, selector: #selector(refreshHit),
                          userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        hitTimer = timer
    }

    @objc func refreshHit() {
        hitTimer?.invalidate()
        hitTimer = nil
        lastHit = ProcessInfo.processInfo.systemUptime
        guard !auto, !body.holdingBody, !rolling else { return }
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let relative = CGPoint(x: local.x - body.center.x, y: local.y - body.center.y)
        let hit = ProbeShape.contains(relative, margin: panel.ignoresMouseEvents ? 0 : 2)
        if panel.ignoresMouseEvents == hit {
            panel.ignoresMouseEvents = !hit
            record(hit ? "bodyAcceptsMouse" : "transparentPassThroughEnabled")
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (label, action) in [("滚动一下", #selector(userRoll)), ("和大白聊聊…", #selector(chatNormal)),
                                ("聊天（激活应用）…", #selector(chatActivate)), ("保存并退出探针", #selector(finish))] {
            let item = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    @objc private func userRoll() {
        guard let screen = panel.screen ?? NSScreen.main, !rolling else { return }
        beginRoll(on: screen)
    }

    private func autoRoll() {
        guard screenIndex < screens.count else { finish(); return }
        let screen = screens[screenIndex]
        screenIndex += 1
        move(to: screen)
        beginRoll(on: screen)
    }

    private func beginRoll(on screen: NSScreen) {
        let plan = ProbeRoll(at: panel.frame, visible: screen.visibleFrame,
                             reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        activeRoll = plan
        rollScreen = screenID(screen)
        panel.ignoresMouseEvents = true
        panel.setFrame(plan.wide, display: false)
        expandedFrame = panel.frame
        observedFrames = 0
        maxAngleDegrees = 0
        framesContained = true
        rollStart = ProcessInfo.processInfo.systemUptime
        drawRoll(0, plan)
        panel.displayIfNeeded()
        let link = body.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let timer = Timer(timeInterval: ProbeRoll.duration + 3, target: self, selector: #selector(timeout),
                          userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    @objc private func tick() {
        guard let plan = activeRoll else { return }
        let progress = min(1, (ProcessInfo.processInfo.systemUptime - rollStart) / ProbeRoll.duration)
        drawRoll(progress, plan)
        if progress == 1 { endRoll(plan, timedOut: false) }
    }

    private func drawRoll(_ progress: Double, _ plan: ProbeRoll) {
        let p = plan.pose(progress)
        body.center = panel.convertPoint(fromScreen: p.center)
        body.angle = p.angle
        maxAngleDegrees = max(maxAngleDegrees, abs(p.angle) * 180 / .pi)
        body.needsDisplay = true
        let bounds = ProbeShape.bounds(center: body.center, radians: body.angle)
        framesContained = framesContained && body.bounds.contains(bounds) && plan.visible.contains(panel.frame)
        observedFrames += 1
    }

    @objc private func timeout() { if let activeRoll { endRoll(activeRoll, timedOut: true) } }

    private func endRoll(_ plan: ProbeRoll, timedOut: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        watchdog?.invalidate()
        watchdog = nil
        body.angle = 0
        body.center = CGPoint(x: plan.end.width / 2, y: plan.end.height / 2)
        panel.setFrame(plan.end, display: true)
        body.needsDisplay = true
        let pass = !timedOut && observedFrames >= 3 && plan.geometryPasses() && framesContained
            && (plan.reducedMotion || maxAngleDegrees >= 300)
            && expandedFrame == plan.wide && expandedFrame.width > plan.start.width
            && panel.frame == plan.end && panel.screen.map(screenID) == rollScreen
        rollResults.append(["screenID": rollScreen, "start": probeRect(plan.start),
                            "expanded": probeRect(expandedFrame), "landed": probeRect(panel.frame),
                            "samples": observedFrames, "maxAbsRotationDegrees": maxAngleDegrees, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - rollStart,
                            "framesContained": framesContained, "geometryPassed": plan.geometryPasses(),
                            "reducedMotion": plan.reducedMotion, "timedOut": timedOut, "passed": pass])
        activeRoll = nil
        if auto { DispatchQueue.main.async { self.autoRoll() } }
        else { refreshHit() }
    }

    @objc private func chatNormal() { openChat(activate: false) }
    @objc private func chatActivate() { openChat(activate: true) }

    private func openChat(activate: Bool) {
        closeChat()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = activate && front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front : nil
        let mode = activate ? "activate" : "nonactivating"
        let mask: NSWindow.StyleMask = activate ? [.titled] : [.titled, .nonactivatingPanel]
        let rect = CGRect(x: 0, y: 0, width: 300, height: 102)
        let chat = ProbeChatPanel(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
        chat.title = activate ? "大白聊天 · 激活应用" : "大白聊天 · 不激活应用"
        chat.level = .floating
        chat.hidesOnDeactivate = false
        let content = NSView(frame: rect)
        let hint = NSTextField(labelWithString: "拼音组字，回车确认。再按回车发送，Esc 关闭。")
        hint.frame = CGRect(x: 12, y: 69, width: 282, height: 22)
        hint.font = .systemFont(ofSize: 12)
        let editor = ProbeEditor(frame: CGRect(x: 12, y: 12, width: 276, height: 46))
        editor.isRichText = false
        editor.isVerticallyResizable = false
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.font = .systemFont(ofSize: 16)
        editor.observed = { [weak self] kind in self?.record(kind, ["focusMode": mode]) }
        editor.sent = { [weak self] in
            self?.record("send", ["focusMode": mode])
            hint.stringValue = "已发送。按 Esc 关闭。"
        }
        editor.escaped = { [weak self] in
            self?.record("escape", ["focusMode": mode])
            self?.closeChat()
        }
        content.addSubview(hint)
        content.addSubview(editor)
        chat.contentView = content
        let visible = (panel.screen ?? screens[0]).visibleFrame
        let y = panel.frame.maxY + chat.frame.height <= visible.maxY ? panel.frame.maxY : panel.frame.minY - chat.frame.height
        let proposed = CGRect(origin: CGPoint(x: panel.frame.midX - chat.frame.width / 2, y: y), size: chat.frame.size)
        chat.setFrame(probeClamp(proposed, to: visible), display: false)
        self.chat = chat
        if activate { NSApp.activate() }
        chat.makeKeyAndOrderFront(nil)
        chat.makeFirstResponder(editor)
        record("chatOpened", ["focusMode": mode, "key": chat.isKeyWindow, "editorFocused": chat.firstResponder === editor,
                              "appActive": NSApp.isActive])
    }

    private func closeChat() {
        guard let chat else { return }
        chat.orderOut(nil)
        self.chat = nil
        if let previousApp, NSApp.isActive { _ = previousApp.activate(options: []) }
        previousApp = nil
    }

    @objc private func finish() {
        guard !finishing else { return }
        finishing = true
        NSApp.stop(nil)
        // Wake run() even when completion came from a display link or dispatch source.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
    }
}
