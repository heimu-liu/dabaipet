import AppKit
import DabaiPetCore
import QuartzCore

private extension RGBA {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

private func ellipse(_ rect: CGRect) -> CGPath { CGPath(ellipseIn: rect, transform: nil) }

private func star(at center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<10 {
        let angle = CGFloat.pi * (0.5 + CGFloat(i) / 5)
        let r = i.isMultiple(of: 2) ? radius : radius * 0.43
        let p = CGPoint(x: center.x + cos(angle)*r, y: center.y + sin(angle)*r)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// Render the Core token's two-center radial gradient once per part, in y-up
/// local coordinates. CA composites the cached fill and its vector outline.
private final class ShadedPart: CALayer {
    init(path: CGPath, layout: BaymaxLayout, appearance: DesktopAppearance) {
        super.init()
        let spec = DesignTokens.bodyGradient(for: appearance)
        let rect = path.boundingBoxOfPath
        let rim = layout.bodyStrokeWidth
        let box = rect.insetBy(dx: -rim, dy: -rim).integral
        let density = 3
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Int(box.width)*density, height: Int(box.height)*density,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(density), y: CGFloat(density))
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.addPath(path)
        ctx.clip()
        func center(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x*rect.width, y: rect.minY + p.y*rect.height)
        }
        let gradient = CGGradient(colorsSpace: space, colors: [spec.startColor.cg, spec.endColor.cg] as CFArray,
                                  locations: [0, 1])!
        let radius = max(rect.width, rect.height)
        ctx.drawRadialGradient(gradient, startCenter: center(spec.startCenterNormalized),
                               startRadius: radius * spec.startRadiusFraction, endCenter: center(spec.endCenterNormalized),
                               endRadius: radius * spec.endRadiusFraction, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        frame = box
        contents = ctx.makeImage()
        contentsScale = CGFloat(density)
        let outline = CAShapeLayer()
        var translation = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        outline.path = path.copy(using: &translation)
        outline.fillColor = nil
        outline.strokeColor = DesignTokens.palette(for: appearance).stroke.cg
        outline.lineWidth = rim
        outline.frame = bounds
        addSublayer(outline)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }
}

/// All anchors and hit-test points are in non-flipped content coordinates.
@MainActor public final class BaymaxLayerView: NSView {
    public let geometry: BaymaxLayout
    public let desktopAppearance: DesktopAppearance
    public let paintBounds: CGRect
    public var anchor: CGPoint { geometry.anchor }
    public var rollingBodyWidth: CGFloat { geometry.rollingBodyWidth }

    private let scene = CALayer()
    private let figure = CALayer()
    private let ground = CAGradientLayer()
    private let feet = CALayer()
    private let arms = CALayer()
    private let tuckedArms = CALayer()
    private let eyes = CALayer()
    private let blush = CALayer()
    private let stars = CALayer()
    private let halo = CAShapeLayer()
    private let portGlow = CAGradientLayer()
    private let face = CALayer()
    private let thinkingDots = CALayer()
    private let happyEyes = CAShapeLayer()
    private var pose = MotionPose()
    private var pivot: CGPoint
    private var dragged = false
    private var tucked = false
    private var idleReduced: Bool?
    private var blinkTimer: Timer?
    private var random = MotionEngine.BlinkGenerator(seed: 0)
    private var link: CADisplayLink?
    private var tickFrame: ((TimeInterval) -> Bool)?
    private var finished: (() -> Void)?
    private var began = 0.0
    @MainActor private final class TickTarget: NSObject {
        weak var view: BaymaxLayerView?
        @objc func tick(_ sender: CADisplayLink) { view?.tick(sender) }
    }

    public init(scale: BaymaxScale = .standard, appearance: DesktopAppearance = .light) {
        let g = BaymaxGeometry.layout(scale: scale)
        geometry = g
        desktopAppearance = appearance
        pivot = g.anchor
        let starPath = CGMutablePath()
        for (i, c) in g.dizzyStarCenters.enumerated() {
            starPath.addPath(star(at: c, radius: (i == 0 ? 3.8 : 3.0) * g.scale))
        }
        // Reserve raster antialiasing as well as the farthest tips. This local
        // rectangle is passed unchanged to ScreenGeometry for the whole roll.
        let widestHalo = g.torsoRect.insetBy(dx: -9.9*g.scale, dy: -7.9*g.scale)
        paintBounds = g.bodyPaintBounds.union(g.groundShadowRect).union(widestHalo).union(starPath.boundingBoxOfPath)
            .insetBy(dx: -1, dy: -1)
        super.init(frame: CGRect(origin: .zero, size: g.idleWindowSize))
        let host = CALayer()
        layer = host
        wantsLayer = true
        configure(scene)
        host.addSublayer(scene)
        configure(figure)
        figure.anchorPoint = CGPoint(x: g.anchor.x / bounds.width, y: g.anchor.y / bounds.height)
        figure.position = g.anchor
        let palette = DesignTokens.palette(for: appearance)
        let shadow = palette.groundShadow.cg
        ground.type = .radial
        ground.colors = [shadow, shadow.copy(alpha: shadow.alpha*0.6)!, shadow.copy(alpha: 0)!]
        ground.locations = [0, 0.6, 1]
        ground.startPoint = CGPoint(x: 0.5, y: 0.5)
        ground.endPoint = CGPoint(x: 1, y: 1)
        ground.frame = g.groundShadowRect
        scene.addSublayer(ground)
        scene.addSublayer(figure)

        let aura = g.torsoRect.insetBy(dx: -6*g.scale, dy: -4*g.scale)
        configure(halo)
        halo.path = ellipse(aura)
        halo.fillColor = palette.accentHeal.cg.copy(alpha: 0.08)
        halo.strokeColor = palette.accentHeal.cg.copy(alpha: 0.48)
        halo.lineWidth = 1.8 * g.scale
        figure.addSublayer(halo)
        for group in [feet, arms, tuckedArms] {
            configure(group)
            figure.addSublayer(group)
        }
        func part(_ path: CGPath, in parent: CALayer) {
            parent.addSublayer(ShadedPart(path: path, layout: g, appearance: appearance))
        }
        part(g.makeLeftFootPath(), in: feet)
        part(g.makeRightFootPath(), in: feet)
        part(g.makeLeftArmPath(), in: arms)
        part(g.makeRightArmPath(), in: arms)
        part(g.makeLeftArmPath(rotationDegrees: 0), in: tuckedArms)
        part(g.makeRightArmPath(rotationDegrees: 0), in: tuckedArms)
        part(g.makeTorsoPath(), in: figure)
        configure(face)
        face.anchorPoint = CGPoint(x: g.headRect.midX / bounds.width, y: g.headRect.midY / bounds.height)
        face.position = CGPoint(x: g.headRect.midX, y: g.headRect.midY)
        figure.addSublayer(face)
        part(g.makeHeadPath(), in: face)
        configure(thinkingDots)
        figure.addSublayer(thinkingDots)
        for offset in -1...1 {
            let center = CGPoint(x: g.headRect.midX + CGFloat(offset) * 5 * g.scale,
                                 y: min(bounds.maxY - 2 * g.scale, g.headRect.maxY + 4 * g.scale))
            let dot = CGRect(x: center.x - 1.4*g.scale, y: center.y - 1.4*g.scale,
                             width: 2.8*g.scale, height: 2.8*g.scale)
            _ = shape(ellipse(dot), color: palette.eye.cg, in: thinkingDots)
        }

        portGlow.frame = g.chestPortRect.insetBy(dx: -5*g.scale, dy: -5*g.scale)
        portGlow.type = .radial
        portGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        portGlow.endPoint = CGPoint(x: 1, y: 1)
        portGlow.colors = [palette.careGlow.cg, palette.careGlow.cg.copy(alpha: 0)!]
        figure.addSublayer(portGlow)
        let port = shape(g.makeChestPortPath(), color: nil, in: figure)
        port.strokeColor = palette.chestPort.cg
        port.lineWidth = DesignTokens.strokes.scaledWidth(DesignTokens.strokes.chestPortStrokeWidthAt1x, scale: g.scale)
        configure(blush)
        face.addSublayer(blush)
        let cheeks = g.makeBlushPaths()
        _ = shape(cheeks.left, color: palette.blush.cg, in: blush)
        _ = shape(cheeks.right, color: palette.blush.cg, in: blush)
        let e = g.eyeGeometry(openness: 1)
        let bridge = shape(e.makeBridgePath(), color: nil, in: face)
        bridge.strokeColor = palette.eye.cg
        bridge.lineWidth = e.bridgeLineWidth
        configure(eyes)
        eyes.anchorPoint = CGPoint(x: 0.5, y: g.headRect.midY / bounds.height)
        eyes.position = CGPoint(x: bounds.midX, y: g.headRect.midY)
        face.addSublayer(eyes)
        _ = shape(e.makeLeftEyePath(), color: palette.eye.cg, in: eyes)
        _ = shape(e.makeRightEyePath(), color: palette.eye.cg, in: eyes)
        let arcs = CGMutablePath()
        for rect in [e.leftEyeRect, e.rightEyeRect] {
            arcs.move(to: CGPoint(x: rect.minX, y: rect.midY))
            arcs.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                              control: CGPoint(x: rect.midX, y: rect.maxY + g.scale))
        }
        configure(happyEyes)
        happyEyes.path = arcs
        happyEyes.strokeColor = palette.eye.cg
        happyEyes.lineWidth = 1.7*g.scale
        happyEyes.lineCap = .round
        happyEyes.fillColor = nil
        face.addSublayer(happyEyes)
        configure(stars)
        figure.addSublayer(stars)
        _ = shape(starPath, color: palette.dizzyStar.cg, in: stars)
        render(pose: MotionPose())
    }

    required init?(coder: NSCoder) { nil }

    private func configure(_ layer: CALayer) {
        layer.bounds = CGRect(origin: .zero, size: geometry.idleWindowSize)
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.contentsScale = 2
    }

    private func shape(_ path: CGPath, color: CGColor?, in parent: CALayer) -> CAShapeLayer {
        let s = CAShapeLayer()
        configure(s)
        s.path = path
        s.fillColor = color
        parent.addSublayer(s)
        return s
    }

    /// Feed the T1.4c callback's pose, elapsed time and unshifted canvas anchor.
    /// A nil elapsed time from that controller maps to the idle state.
    public func render(pose: MotionPose, at canvasAnchor: CGPoint? = nil, state: PetState = .idle, elapsed: TimeInterval = 0) {
        stopAnimations()
        apply(pose, at: canvasAnchor ?? anchor, state: state, elapsed: elapsed)
    }

    private func apply(_ p: MotionPose, at a: CGPoint, state: PetState, elapsed: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        pose = p
        pivot = a
        let angle = p.rotationDegrees * .pi / 180
        figure.position = CGPoint(x: a.x + p.offsetX, y: a.y + p.offsetY)
        figure.setAffineTransform(CGAffineTransform(rotationAngle: angle).scaledBy(x: p.scaleX, y: p.scaleY))
        dragged = state == .dragging
        if case .rolling = state { tucked = elapsed < DesignTokens.motion.rollBrakeEnd } else { tucked = false }
        arms.isHidden = tucked
        tuckedArms.isHidden = !tucked
        feet.position.y = dragged ? -2 * geometry.scale : 0
        let emotion: PetEmotion
        if case let .speaking(value) = state { emotion = value } else { emotion = .neutral }
        let cheerful = emotion == .happy || emotion == .excited
        blush.isHidden = state != .poked && !cheerful
        happyEyes.isHidden = !cheerful
        eyes.isHidden = cheerful
        eyes.setAffineTransform(CGAffineTransform(scaleX: 1, y: emotion == .sleepy ? 0.42 : 1))
        portGlow.isHidden = emotion != .care
        thinkingDots.isHidden = state != .thinking
        halo.isHidden = state != .listening && state != .healthReminder
        if !halo.isHidden {
            let pulse = (1 - cos(2 * .pi * elapsed / 1.8)) / 2
            halo.opacity = Float(0.5 + 0.5*pulse)
            let extra = 3 * geometry.scale * pulse
            halo.path = ellipse(geometry.torsoRect.insetBy(dx: -6*geometry.scale-extra, dy: -4*geometry.scale-extra))
        }
        // The shadow stays horizontal under the rolling silhouette. Constrain
        // it to the same projected box used to plan the wide window at edges.
        let shadow = geometry.groundShadowRect
        let shrink = dragged ? DesignTokens.motion.dragShadowScale : 1
        var rect = CGRect(x: a.x + p.offsetX - shadow.width*shrink/2,
                          y: a.y - anchor.y + shadow.minY, width: shadow.width*shrink, height: shadow.height*shrink)
        if case .rolling = state {
            stars.isHidden = elapsed < DesignTokens.motion.dizzyStart || elapsed >= MotionEngine.rollDuration
            let box = paintBounds.offsetBy(dx: -anchor.x, dy: -anchor.y).applying(figure.affineTransform())
                .offsetBy(dx: figure.position.x, dy: figure.position.y).insetBy(dx: 1, dy: 1)
            rect = ScreenGeometry.clampedFrame(rect, to: box)
        } else {
            stars.isHidden = emotion != .dizzy
        }
        ground.frame = rect
        ground.opacity = dragged ? Float(DesignTokens.motion.dragShadowOpacityMultiplier) : 1
    }

    public func containsBodyPoint(_ point: CGPoint, outwardMargin: CGFloat = 0) -> Bool {
        var current = pose
        if idleReduced != nil, let visible = figure.presentation() {
            let affine = visible.affineTransform()
            current.offsetY += visible.position.y - figure.position.y
            current.scaleX = affine.a
            current.scaleY = affine.d
        }
        if !tucked && !dragged {
            return geometry.containsBodyPoint(point, pose: current, atCanvasAnchor: pivot, outwardMargin: outwardMargin)
        }
        let g = geometry
        let path = CGMutablePath()
        let footDrop = CGAffineTransform(translationX: 0, y: feet.position.y)
        path.addPath(g.makeLeftFootPath(), transform: footDrop)
        path.addPath(g.makeRightFootPath(), transform: footDrop)
        path.addPath(g.makeLeftArmPath(rotationDegrees: tucked ? 0 : nil))
        path.addPath(g.makeRightArmPath(rotationDegrees: tucked ? 0 : nil))
        path.addPath(g.makeTorsoPath())
        path.addPath(g.makeHeadPath())
        var transform = CGAffineTransform(translationX: pivot.x + current.offsetX, y: pivot.y + current.offsetY)
            .rotated(by: current.rotationDegrees * .pi / 180).scaledBy(x: current.scaleX, y: current.scaleY)
            .translatedBy(x: -anchor.x, y: -anchor.y)
        guard let world = path.copy(using: &transform) else { return false }
        return world.contains(point) || (outwardMargin > 0 && world.copy(strokingWithWidth: outwardMargin*2,
            lineCap: .round, lineJoin: .round, miterLimit: 4).contains(point))
    }

    /// Call on entry to visible, unpaused idle. No per-frame application timer.
    public func startIdle(reducedMotion: Bool, blinkSeed: UInt64? = nil) {
        guard idleReduced != reducedMotion else { return }
        render(pose: MotionPose())
        idleReduced = reducedMotion
        random = .init(seed: blinkSeed ?? UInt64.random(in: .min ... .max))
        let peak = MotionEngine.breathPeak(reducedMotion: reducedMotion)
        let breath = CABasicAnimation(keyPath: "transform")
        breath.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        breath.toValue = NSValue(caTransform3D: CATransform3DMakeScale(peak.scaleX, peak.scaleY, 1))
        breath.duration = DesignTokens.motion.breathPeriod/2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        figure.add(breath, forKey: "breathing")
        scheduleBlink()
    }

    /// A compositor-only beat over idle breathing. The model pose stays at rest.
    public func playTypingBeat() {
        guard idleReduced == false else { return }
        let beat = CAKeyframeAnimation(keyPath: "position.y")
        beat.isAdditive = true
        beat.values = [0, 2 * geometry.scale, 0]
        beat.keyTimes = [0, 0.42, 1]
        beat.duration = 0.24
        beat.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut)]
        figure.add(beat, forKey: "typingBeat")
    }

    public func stopTypingBeat() {
        figure.removeAnimation(forKey: "typingBeat")
    }

    private func scheduleBlink() {
        let timer = Timer(timeInterval: MotionEngine.nextBlinkInterval(using: &random), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.idleReduced != nil else { return }
                let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
                blink.values = (0...8).map { step in
                    let open = MotionEngine.blinkOpenness(at: MotionEngine.blinkDuration*Double(step)/8)
                    return self.geometry.eyeGeometry(openness: open).leftEyeRect.height /
                        self.geometry.eyeGeometry(openness: 1).leftEyeRect.height
                }
                blink.duration = MotionEngine.blinkDuration
                self.eyes.add(blink, forKey: "blink")
                self.scheduleBlink()
            }
        }
        blinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Short active actions own a display link only until the final frame.
    /// Rolling has its own window-synchronized driver in PetRollController.
    public func animatePoke(didFinish: @escaping () -> Void) {
        animate(didFinish: didFinish) { [weak self] t in
            guard let self else { return true }
            self.apply(MotionEngine.poke(at: t), at: self.anchor, state: .poked, elapsed: t)
            return t >= MotionEngine.pokeDuration
        }
    }

    public func animateDragRelease(from p: MotionPose, didFinish: @escaping () -> Void) {
        animate(didFinish: didFinish) { [weak self] t in
            guard let self else { return true }
            self.apply(MotionEngine.dragRelease(from: p, at: t), at: self.anchor, state: .idle, elapsed: t)
            return t >= MotionEngine.dragReleaseDuration
        }
    }

    public func showHealthScan(reducedMotion: Bool) {
        render(pose: MotionPose(), state: .healthReminder)
        guard !reducedMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.5
        pulse.toValue = 1
        pulse.duration = DesignTokens.motion.pokeBubbleDuration / 2
        pulse.autoreverses = true
        halo.add(pulse, forKey: "healthScan")
    }

    public func showSpeaking(_ emotion: PetEmotion, reducedMotion: Bool) {
        render(pose: MotionPose(), state: .speaking(emotion: emotion))
        guard emotion == .excited, !reducedMotion else { return }
        let hop = CAKeyframeAnimation(keyPath: "position.y")
        hop.isAdditive = true
        hop.values = [0, 2 * geometry.scale, 0]
        hop.duration = 0.28
        figure.add(hop, forKey: "excited")
    }

    public func startThinking(reducedMotion: Bool) {
        render(pose: MotionPose(), state: .thinking)
        guard !reducedMotion else { return }
        let sway = CABasicAnimation(keyPath: "transform.rotation.z")
        sway.fromValue = -4 * Double.pi / 180
        sway.toValue = 4 * Double.pi / 180
        sway.duration = 0.65
        sway.autoreverses = true
        sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        face.add(sway, forKey: "thinking")
        for (index, dot) in (thinkingDots.sublayers ?? []).enumerated() {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.45
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timeOffset = Double(index) * 0.18
            dot.add(pulse, forKey: "thinking")
        }
    }

    public func startListening(reducedMotion: Bool = false) {
        if reducedMotion {
            render(pose: MotionPose(), state: .listening)
            return
        }
        animate(didFinish: {}) { [weak self] t in
            guard let self else { return true }
            self.apply(MotionPose(), at: self.anchor, state: .listening, elapsed: t)
            return false
        }
    }

    private func animate(didFinish: @escaping () -> Void, frame: @escaping (TimeInterval) -> Bool) {
        stopAnimations()
        began = CACurrentMediaTime()
        tickFrame = frame
        finished = didFinish
        _ = frame(0)
        let target = TickTarget()
        target.view = self
        let link = displayLink(target: target, selector: #selector(TickTarget.tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    private func tick(_ sender: CADisplayLink) {
        guard sender === link, tickFrame?(CACurrentMediaTime() - began) == true else { return }
        let completion = finished
        render(pose: MotionPose())
        completion?()
    }

    public func stopAnimations() {
        figure.removeAnimation(forKey: "excited")
        face.removeAnimation(forKey: "thinking")
        thinkingDots.sublayers?.forEach { $0.removeAnimation(forKey: "thinking") }
        halo.removeAnimation(forKey: "healthScan")
        link?.invalidate()
        link = nil
        tickFrame = nil
        finished = nil
        if idleReduced != nil {
            stopTypingBeat()
            idleReduced = nil
            blinkTimer?.invalidate()
            blinkTimer = nil
            figure.removeAnimation(forKey: "breathing")
            eyes.removeAnimation(forKey: "blink")
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimations() }
    }

    isolated deinit { blinkTimer?.invalidate(); link?.invalidate() }

    /// Draw the installed artwork tree at its current model pose into a y-up context.
    public func renderArtwork(in context: CGContext) { scene.render(in: context) }
}
