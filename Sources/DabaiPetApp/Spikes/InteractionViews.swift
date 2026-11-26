import AppKit

final class ProbeBodyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ProbeBodyView: NSView {
    weak var session: InteractionSession?
    var center = CGPoint(x: ProbeShape.idleSize.width / 2, y: ProbeShape.idleSize.height / 2)
    var angle = 0.0
    var poked = false
    private var downPoint: CGPoint?
    private var downTime = 0.0
    private var initialOrigin = CGPoint.zero
    private var peakDistance = 0.0
    private var lastX = 0.0
    private var lastTime = 0.0
    private var peakVX = 0.0

    var holdingBody: Bool { downPoint != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.clear(dirtyRect)
        c.saveGState()
        defer { c.restoreGState() }
        c.translateBy(x: center.x, y: center.y)
        c.rotate(by: angle)
        c.setLineWidth(1.2)
        for (i, e) in ProbeShape.ellipses.enumerated() {
            c.setFillColor(i == 4 && poked ? NSColor.systemPink.cgColor : NSColor.white.cgColor)
            c.setStrokeColor(NSColor(calibratedWhite: 0.50, alpha: 1).cgColor)
            c.addEllipse(in: e)
            c.drawPath(using: .fillStroke)
        }
        c.setFillColor(NSColor.black.cgColor)
        c.setStrokeColor(NSColor.black.cgColor)
        c.move(to: CGPoint(x: -9, y: 41))
        c.addLine(to: CGPoint(x: 9, y: 41))
        c.strokePath()
        for x in [-12, 6] { c.fillEllipse(in: CGRect(x: x, y: 38, width: 6, height: 6)) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, session?.rolling == false else { return }
        downPoint = NSEvent.mouseLocation
        downTime = event.timestamp
        lastTime = downTime
        lastX = NSEvent.mouseLocation.x
        peakDistance = 0
        peakVX = 0
        initialOrigin = window.frame.origin
        window.ignoresMouseEvents = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint, let window else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y
        peakDistance = max(peakDistance, hypot(dx, dy))
        if event.timestamp > lastTime {
            peakVX = max(peakVX, abs((p.x - lastX) / (event.timestamp - lastTime)))
        }
        lastX = p.x
        lastTime = event.timestamp
        guard peakDistance >= 3,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? window.screen else { return }
        let destination = CGRect(x: initialOrigin.x + dx, y: initialOrigin.y + dy,
                                 width: window.frame.width, height: window.frame.height)
        window.setFrameOrigin(probeClamp(destination, to: screen.visibleFrame).origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard let downPoint else { return }
        let p = NSEvent.mouseLocation
        let distance = max(peakDistance, hypot(p.x - downPoint.x, p.y - downPoint.y))
        let elapsed = event.timestamp - downTime
        self.downPoint = nil
        let click = distance < 3 && elapsed < 0.25
        if click {
            poked = true
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.poked = false
                self?.needsDisplay = true
            }
        }
        session?.record(click ? "poke" : "dragEnded", ["peakDisplacementPt": distance,
                        "elapsedSeconds": elapsed, "peakHorizontalSpeedPtPerSec": peakVX])
        session?.refreshHit()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = session?.makeMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

final class ProbeEditor: NSTextView {
    var observed: ((String) -> Void)?
    var sent: (() -> Void)?
    var escaped: (() -> Void)?
    private var confirmingComposition = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let previouslyMarked = hasMarkedText()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if !previouslyMarked && hasMarkedText() { observed?("compositionBegan") }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let previouslyMarked = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        if previouslyMarked && !hasMarkedText() { observed?("compositionCommitted") }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            escaped?()
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        confirmingComposition = isReturn && hasMarkedText()
        defer { confirmingComposition = false }
        if confirmingComposition { observed?("returnWithMarkedText") }
        // Give the input method the original key. It may finish composition before
        // AppKit invokes insertNewline, so keep the pre-dispatch marked state too.
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        guard !confirmingComposition && !hasMarkedText() else {
            if hasMarkedText() { unmarkText() }
            return
        }
        guard !string.isEmpty else { return }
        sent?()
        string = ""
    }

    override func cancelOperation(_ sender: Any?) { escaped?() }
}

final class ProbeChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
