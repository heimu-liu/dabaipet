// build.py prepends the production probe's private scene definitions verbatim.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let schedule = try JSONDecoder().decode([String].self, from: Data(contentsOf: folder.appendingPathComponent("schedule.json")))
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: CGRect(origin: .zero, size: Shape.size),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.isOpaque = false
window.backgroundColor = NSColor(white: 0.15, alpha: 0.88)
window.hasShadow = false
window.level = .floating
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
let area = NSScreen.main!.visibleFrame
window.setFrameOrigin(NSPoint(x: area.maxX - Shape.size.width - 24, y: area.minY + 24))
var oval: CAShapeLayer?
var scene = "empty"
var tick = 0

@MainActor func install(_ candidate: Bool) {
    oval?.removeAllAnimations()
    oval?.removeFromSuperlayer()
    oval = nil
    let content: AnyView
    if candidate {
        let shape = CAShapeLayer()
        oval = shape
        content = AnyView(LayerBreath(oval: shape, limitTo15Hz: true))
        scene = "layer-limited"
    } else {
        content = AnyView(Color.clear)
        scene = "empty"
    }
    window.contentView = NSHostingView(rootView: content.frame(width: Shape.size.width, height: Shape.size.height))
    window.displayIfNeeded()
    CATransaction.flush()
}

@MainActor func state(_ name: String) {
    let wid = CGWindowID(window.windowNumber)
    let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.first ?? [:]
    let screen = window.screen
    let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let cfg = CGDisplayCopyDisplayMode(id)
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let rate = oval?.animation(forKey: "breathing")?.preferredFrameRateRange
    let bg = window.backgroundColor.usingColorSpace(.genericGray)
    let record: [String: Any] = [
        "wall": Date().timeIntervalSince1970, "uptime": ProcessInfo.processInfo.systemUptime,
        "pid": getpid(), "windowID": Int(wid), "cgPID": info[kCGWindowOwnerPID as String] ?? -1,
        "cgID": info[kCGWindowNumber as String] ?? -1, "cgBounds": info[kCGWindowBounds as String] ?? [:],
        "cgOnscreen": info[kCGWindowIsOnscreen as String] ?? false, "cgAlpha": info[kCGWindowAlpha as String] ?? -1,
        "visible": window.isVisible, "unoccluded": window.occlusionState.contains(.visible),
        "asleep": CGDisplayIsAsleep(id) != 0, "locked": session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
        "displayID": id, "frame": NSStringFromRect(window.frame), "backingScale": window.backingScaleFactor,
        "displayMode": [Double(cfg?.pixelWidth ?? 0), Double(cfg?.pixelHeight ?? 0), cfg?.refreshRate ?? -1],
        "opaque": window.isOpaque, "bgWhite": bg?.whiteComponent ?? -1, "bgAlpha": bg?.alphaComponent ?? -1,
        "level": window.level.rawValue, "hasShadow": window.hasShadow, "styleMask": window.styleMask.rawValue,
        "collectionBehavior": window.collectionBehavior.rawValue, "ignoresMouse": window.ignoresMouseEvents,
        "scene": scene, "shapeAttached": oval?.superlayer != nil, "rate": [rate?.minimum ?? 0, rate?.maximum ?? 0, rate?.preferred ?? 0],
        "presentationScaleY": oval?.presentation()?.transform.m22 ?? 0
    ]
    do {
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: folder.appendingPathComponent(name), options: .atomic)
    } catch { exit(EX_IOERR) }
}

install(false)
window.orderFrontRegardless()
var observers: [NSObjectProtocol] = []
var eventCount = 0
for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification,
             NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
             NSApplication.didChangeScreenParametersNotification] {
    let subject: AnyObject = name == NSApplication.didChangeScreenParametersNotification ? app : window
    let observer = NotificationCenter.default.addObserver(forName: name, object: subject, queue: .main) { _ in
        MainActor.assumeIsolated {
            eventCount += 1
            state("event-\(eventCount)-\(name.rawValue).json")
        }
    }
    observers.append(observer)
}
signal(SIGUSR1, SIG_IGN)
let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
source.setEventHandler {
    let i = tick / 2
    guard i < schedule.count else { app.terminate(nil); return }
    if tick.isMultiple(of: 2) {
        install(schedule[i] == "C")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state("p\(i)-begin.json") }
    } else {
        state("p\(i)-end.json")
    }
    tick += 1
}
source.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state("ready.json") }
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { app.terminate(nil) }
app.run()
