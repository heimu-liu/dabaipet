import AppKit
import Darwin
import QuartzCore
import SwiftUI
import Synchronization

private enum Scene: String {
    case empty, canvas, layer
    case layerLimited = "layer-limited"
}

private enum Shape {
    static let size = CGSize(width: 192, height: 192)
    static let oval = CGRect(x: 42, y: 32, width: 108, height: 128)
    static let period = 2.2
    static let amplitude = 0.045
    static let color = NSColor(srgbRed: 0.34, green: 0.62, blue: 0.75, alpha: 1)
}

// Canvas rendering can be called independently of SwiftUI body evaluation.
private final class FrameCount: Sendable {
    private struct Readings {
        var count = 0
        var first = 0.0
        var last = 0.0
    }
    private let readings = Mutex(Readings())

    func record(_ now: Double) {
        readings.withLock {
            if $0.count == 0 { $0.first = now }
            $0.last = now
            $0.count += 1
        }
    }

    var result: (count: Int, fps: Double) {
        readings.withLock {
            ($0.count, $0.last > $0.first ? Double($0.count - 1) / ($0.last - $0.first) : 0)
        }
    }
}

private struct CanvasBreath: View {
    let origin: Date
    let frames: FrameCount

    var body: some View {
        TimelineView(.periodic(from: origin, by: 1.0 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSince(origin)
                .truncatingRemainder(dividingBy: Shape.period) / Shape.period
            let scale = 1 + Shape.amplitude * (1 - abs(2 * phase - 1))
            Canvas { context, _ in
                let oval = Shape.oval
                let inset = oval.height * (1 - scale) / 2
                context.fill(Path(ellipseIn: oval.insetBy(dx: 0, dy: inset)),
                             with: .color(Color(nsColor: Shape.color)))
                frames.record(CACurrentMediaTime())
            }
        }
    }
}

@MainActor
private struct LayerBreath: NSViewRepresentable {
    let oval: CAShapeLayer
    let limitTo15Hz: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: CGRect(origin: .zero, size: Shape.size))
        view.wantsLayer = true
        oval.frame = Shape.oval
        oval.path = CGPath(ellipseIn: oval.bounds, transform: nil)
        oval.fillColor = Shape.color.cgColor
        view.layer?.addSublayer(oval)
        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = 1.0
        animation.toValue = 1 + Shape.amplitude
        animation.duration = Shape.period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        if limitTo15Hz {
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 15, preferred: 15)
        }
        oval.add(animation, forKey: "breathing")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
enum PerformanceProbe {
    private static var window: NSWindow?
    private static var stopSignal: DispatchSourceSignal?

    static func run(_ arguments: [String]) throws {
        guard arguments.count == 3, let scene = Scene(rawValue: arguments[0]),
              arguments[1].hasPrefix("/"), UUID(uuidString: arguments[2]) != nil else {
            throw NSError(domain: "DabaiPet.S4", code: Int(EX_USAGE), userInfo: [
                NSLocalizedDescriptionKey: "Expected --spike-s4 empty|canvas|layer|layer-limited ABSOLUTE_OUTPUT_DIR RUN_UUID"
            ])
        }
        let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let token = arguments[2]
        let frames = FrameCount()
        let oval = CAShapeLayer()
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        let panel = NSWindow(contentRect: CGRect(origin: .zero, size: Shape.size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 0.15, alpha: 0.88)
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let content: AnyView
        switch scene {
        case .empty: content = AnyView(Color.clear)
        case .canvas: content = AnyView(CanvasBreath(origin: Date(), frames: frames))
        case .layer, .layerLimited:
            content = AnyView(LayerBreath(oval: oval, limitTo15Hz: scene == .layerLimited))
        }
        panel.contentView = NSHostingView(rootView: content.frame(width: Shape.size.width,
                                                                  height: Shape.size.height))
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - Shape.size.width - 24, y: area.minY + 24))
        }
        window = panel
        let writeState: @MainActor (String) -> Void = { filename in
            let reading = frames.result
            let data: [String: Any] = [
                "scene": scene.rawValue, "token": token, "pid": getpid(), "windowID": panel.windowNumber,
                "visible": panel.isVisible, "unoccluded": panel.occlusionState.contains(.visible),
                "backingScale": panel.backingScaleFactor, "frame": NSStringFromRect(panel.frame),
                "canvasDrawCount": reading.count, "canvasMeasuredFPS": reading.fps,
                "breathingLayerAttached": oval.superlayer != nil && oval.animation(forKey: "breathing") != nil,
                "layerPreferredFrameRate": oval.animation(forKey: "breathing")?.preferredFrameRateRange.preferred ?? 0
            ]
            do {
                try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent(filename), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("S4: \(error)\n".utf8))
                exit(EX_IOERR)
            }
        }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            writeState("finished.json")
            NSApp.terminate(nil)
        }
        stopSignal = source
        source.resume()
        DispatchQueue.main.async {
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { writeState("ready.json") }
        }
        // A runner interrupted before it learns our PID cannot leave a permanent window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { NSApp.terminate(nil) }
    }
}
