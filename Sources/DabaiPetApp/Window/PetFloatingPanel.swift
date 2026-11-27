import AppKit

@MainActor
final class PetFloatingPanel: NSPanel {
    /// The rendering geometry receives a point in content-view coordinates and
    /// an outward margin in points (0 on entry, 2 while tracking the body).
    typealias BodyHitTest = @MainActor (_ point: CGPoint, _ outwardMargin: CGFloat) -> Bool

    private let bodyHitTest: BodyHitTest
    private let pointerLocation: @MainActor () -> CGPoint
    private var monitors: [Any] = []
    private var pendingHit: Timer?
    private var lastHit: TimeInterval = -.infinity
    private var dragCaptured = false
    private var interruptRoll: (() -> Void)?
    var isMonitoringPointer: Bool { monitors.count == 2 }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
         bodyHitTest: @escaping BodyHitTest) {
        self.pointerLocation = pointerLocation
        self.bodyHitTest = bodyHitTest
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        if place == .out {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        startMonitoring()
    }

    override func close() {
        stopMonitoring()
        super.close()
    }

    isolated deinit {
        pendingHit?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
    }

    /// The overlay locks on mouseDown, and unlocks on mouseUp or cancellation.
    func setDragCapture(_ captured: Bool) {
        guard isMonitoringPointer, interruptRoll == nil, captured != dragCaptured else { return }
        dragCaptured = captured
        cancelPendingHit()
        if captured {
            ignoresMouseEvents = false
        } else {
            refreshHit()
        }
    }

    // The wide canvas passes through input until its idle geometry is restored.
    func beginRollPassThrough(onOrderOut: @escaping () -> Void) -> Bool {
        guard isMonitoringPointer, !dragCaptured, interruptRoll == nil else { return false }
        interruptRoll = onOrderOut
        cancelPendingHit()
        ignoresMouseEvents = true
        return true
    }

    func endRollPassThrough() {
        interruptRoll = nil
        refreshHit()
    }

    /// Also call after moving/resizing the pet or changing its body geometry.
    /// A trailing sample handles the final move even if the pointer then stops.
    func requestHitTest() {
        guard isMonitoringPointer, !dragCaptured, interruptRoll == nil, pendingHit == nil else { return }
        let remaining = 1.0 / 60 - (ProcessInfo.processInfo.systemUptime - lastHit)
        if remaining <= 0 {
            refreshHit()
            return
        }
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pendingHit = nil
                self?.refreshHit()
            }
        }
        pendingHit = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startMonitoring() {
        guard isVisible, !isMonitoringPointer else { return }
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.requestHitTest()
        }) else { return }
        guard let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.requestHitTest()
            return event
        }) else {
            NSEvent.removeMonitor(global)
            return
        }
        monitors = [global, local]
        refreshHit()
    }

    private func stopMonitoring() {
        cancelPendingHit()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        dragCaptured = false
        ignoresMouseEvents = true
        let interrupt = interruptRoll
        interruptRoll = nil
        interrupt?()
    }

    private func cancelPendingHit() {
        pendingHit?.invalidate()
        pendingHit = nil
    }

    /// Content coordinates. Enter on the silhouette; retain its 2 pt fringe
    /// for both window routing and gestures until the pointer leaves it.
    func hitsInteractiveBody(at point: CGPoint) -> Bool {
        guard isMonitoringPointer, interruptRoll == nil, contentView?.bounds.contains(point) == true else { return false }
        return bodyHitTest(point, ignoresMouseEvents ? 0 : 2)
    }

    private func refreshHit() {
        guard isMonitoringPointer, !dragCaptured, interruptRoll == nil else { return }
        lastHit = ProcessInfo.processInfo.systemUptime
        guard let view = contentView else {
            ignoresMouseEvents = true
            return
        }
        let point = view.convert(convertPoint(fromScreen: pointerLocation()), from: nil)
        let hit = hitsInteractiveBody(at: point)
        if ignoresMouseEvents == hit { ignoresMouseEvents = !hit }
    }
}
