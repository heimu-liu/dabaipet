import AppKit
import DabaiPetCore
import QuartzCore

@MainActor
final class PetRollController {
    /// Idle content coordinates, in points, with positive y upwards.
    struct Geometry {
        let bodyBounds: CGRect
        let anchor: CGPoint
        let rollingBodyWidth: CGFloat
    }

    enum StartResult { case started, alreadyRolling, noSpace, unavailable }
    enum Outcome: Equatable { case completed(CGRect), interrupted(CGRect) }

    private let panel: PetFloatingPanel
    // A nil elapsed time requests the compact, idle presentation.
    private let render: (CGPoint, MotionPose, TimeInterval?) -> Void
    private let didEnd: (Outcome) -> Void
    private var active: Roll?
    var isRolling: Bool { active != nil }

    @MainActor private final class Driver: NSObject {
        weak var owner: PetRollController?
        @objc func tick() { owner?.tick(self) }
    }

    @MainActor private final class Roll {
        let plan: ScreenGeometry.RollPlan
        let geometry: Geometry
        let screen: NSScreen
        let visible: CGRect
        let link: CADisplayLink
        let driver: Driver
        var watchdog: Timer?
        let started = CACurrentMediaTime()
        var lastIdleOrigin: CGPoint
        var finishing = false

        init(_ plan: ScreenGeometry.RollPlan, _ geometry: Geometry, _ screen: NSScreen, _ link: CADisplayLink, _ driver: Driver) {
            self.plan = plan
            self.geometry = geometry
            self.screen = screen
            visible = screen.visibleFrame
            self.link = link
            self.driver = driver
            lastIdleOrigin = plan.startFrame.origin
        }
    }

    init(panel: PetFloatingPanel, render: @escaping (CGPoint, MotionPose, TimeInterval?) -> Void,
         didEnd: @escaping (Outcome) -> Void) {
        self.panel = panel
        self.render = render
        self.didEnd = didEnd
    }

    /// Each accepted start yields exactly one outcome, with the actual compact
    /// panel frame suitable for persistence. A rejected start has no completion.
    @discardableResult
    func start(geometry: Geometry, preferredDirection: RollDirection, reducedMotion: Bool) -> StartResult {
        guard active == nil else { return .alreadyRolling }
        guard panel.isVisible, let screen = panel.screen, let canvas = panel.contentView else { return .unavailable }
        guard let plan = ScreenGeometry.wideRollFrame(startFrame: panel.frame, visibleFrame: screen.visibleFrame,
            bodyBounds: geometry.bodyBounds, anchor: geometry.anchor, preferredDirection: preferredDirection,
            reducedMotion: reducedMotion, rollingBodyWidth: geometry.rollingBodyWidth),
              plan.startFrame != plan.endFrame else { return .noSpace }
        guard panel.beginRollPassThrough(onOrderOut: { [weak self] in self?.cancel() }) else { return .unavailable }
        let driver = Driver()
        driver.owner = self
        let link = canvas.displayLink(target: driver, selector: #selector(Driver.tick))
        let run = Roll(plan, geometry, screen, link, driver)
        active = run
        // AppKit rounds frame coordinates. Expand outwards before rounding so
        // fractional painted edges are still covered by the actual window.
        panel.setFrame(plan.wideFrame.integral.intersection(run.visible), display: false)
        if active === run {
            present(run, at: 0)
            if active === run {
                link.add(to: .main, forMode: .common)
                // The view may stop receiving vsync when the display sleeps.
                // Release the wide window even if no further frame arrives.
                let watchdog = Timer(timeInterval: MotionEngine.rollDuration + 1, repeats: false) { [weak self, weak run] _ in
                    MainActor.assumeIsolated {
                        if let self, let run, self.active === run { self.cancel() }
                    }
                }
                run.watchdog = watchdog
                RunLoop.main.add(watchdog, forMode: .common)
            }
        }
        return .started
    }

    private func tick(_ driver: Driver) {
        guard let run = active, run.driver === driver, !run.finishing else { return }
        guard panel.isVisible, run.screen.visibleFrame == run.visible else { cancel(); return }
        let time = min(CACurrentMediaTime() - run.started, MotionEngine.rollDuration)
        present(run, at: time)
        // Rendering can synchronously cancel this action and start another one.
        if time == MotionEngine.rollDuration && active === run { finish(run, completed: true) }
    }

    private func present(_ run: Roll, at time: TimeInterval) {
        let plan = run.plan
        let pose = plan.pose(at: time)
        let worldPivot = CGPoint(x: plan.wideFrame.minX + plan.anchorInCanvas.x,
                                 y: plan.wideFrame.minY + plan.anchorInCanvas.y)
        let anchor = CGPoint(x: worldPivot.x - panel.frame.minX, y: worldPivot.y - panel.frame.minY)
        run.lastIdleOrigin = CGPoint(x: worldPivot.x + pose.offsetX - run.geometry.anchor.x,
                                     y: worldPivot.y + pose.offsetY - run.geometry.anchor.y)
        render(anchor, pose, time)
    }

    func cancel() {
        if let run = active, !run.finishing { finish(run, completed: false) }
    }

    private func finish(_ run: Roll, completed: Bool) {
        run.finishing = true
        run.watchdog?.invalidate()
        run.link.invalidate()
        let destination = completed ? run.plan.endFrame : CGRect(origin: run.lastIdleOrigin, size: run.plan.startFrame.size)
        let compact = ScreenGeometry.clampedFrame(destination, to: run.screen.visibleFrame)
        panel.setFrame(compact, display: false)
        render(run.geometry.anchor, MotionPose(), nil)
        panel.endRollPassThrough()
        let actual = panel.frame
        active = nil
        didEnd(completed ? .completed(actual) : .interrupted(actual))
    }

    isolated deinit { cancel() }
}
