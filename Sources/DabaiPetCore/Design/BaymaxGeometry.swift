import CoreGraphics
import Foundation

/// Supported Baymax visual scale presets from UI_UX_SPEC §2.
public enum BaymaxScale: Double, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case small = 0.8
    case standard = 1.0
    case large = 1.25

    public var factor: CGFloat { CGFloat(rawValue) }
}

/// Eye and connecting bridge geometry in idle-window points (positive y upwards).
public struct BaymaxEyeGeometry: Equatable, Sendable {
    public let leftEyeRect: CGRect
    public let rightEyeRect: CGRect
    public let bridgeStart: CGPoint
    public let bridgeEnd: CGPoint
    public let bridgeLineWidth: CGFloat

    public func makeLeftEyePath() -> CGPath {
        CGPath(ellipseIn: leftEyeRect, transform: nil)
    }

    public func makeRightEyePath() -> CGPath {
        CGPath(ellipseIn: rightEyeRect, transform: nil)
    }

    public func makeBridgePath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: bridgeStart)
        path.addLine(to: bridgeEnd)
        return path.copy() ?? path
    }
}

/// Complete, scale-calibrated Baymax geometry in macOS points with origin (0, 0)
/// at the bottom-left of the idle window and +Y pointing upwards.
///
/// The exact same body paths drive both CALayer/CoreGraphics rendering and
/// PetFloatingPanel pointer hit-testing (`containsBodyPoint`).
public struct BaymaxLayout: Equatable, Sendable {
    /// Coordinate convention metadata for consumers in DabaiPetUI and DabaiPetApp.
    public static let coordinateSystemDescription = "points; origin at idle window bottom-left; +X right, +Y up"

    // MARK: - 1.0x Anchor-Local Reference Constants (UI_UX_SPEC §2.2)

    static let torsoWidthAt1x: CGFloat = 84.0
    static let torsoHeightAt1x: CGFloat = 92.0
    static let headWidthAt1x: CGFloat = 44.0
    static let headHeightAt1x: CGFloat = 31.0
    static let eyeOpenDiameterAt1x: CGFloat = 6.2
    static let eyeClosedHeightAt1x: CGFloat = 1.5
    static let eyeCenterSpacingAt1x: CGFloat = 18.0
    static let chestPortDiameterAt1x: CGFloat = 10.0

    static let armWidthAt1x: CGFloat = 18.0
    static let armHeightAt1x: CGFloat = 54.0
    static let armCornerRadiusAt1x: CGFloat = 9.0
    static let leftArmRestingDegrees: CGFloat = -10.0
    static let rightArmRestingDegrees: CGFloat = 10.0

    static let footWidthAt1x: CGFloat = 20.0
    static let footHeightAt1x: CGFloat = 16.0

    // MARK: - Public Scaled Properties

    public let scale: CGFloat
    /// Integer-rounded idle window size guaranteed to enclose all in-window poses plus safe margin.
    public let idleWindowSize: CGSize
    /// Body rotation/scale pivot in idle-window coordinates.
    public let anchor: CGPoint
    /// Scaled torso width (`84 * scale`) for `ScreenGeometry.wideRollFrame(..., rollingBodyWidth:)`.
    public let rollingBodyWidth: CGFloat
    /// Scaled body outline stroke width.
    public let bodyStrokeWidth: CGFloat
    /// Scaled safe margin around resting artwork inside the idle window.
    public let safeMargin: CGFloat

    /// Moving body bounding box (head + torso + arms + feet + stroke), excluding ground shadow.
    public let bodyPaintBounds: CGRect
    /// Exact head ellipse rect (`44 x 31` at 1x).
    public let headRect: CGRect
    /// Exact torso bounding rect (`84 x 92` at 1x).
    public let torsoRect: CGRect
    /// Left chest medical port circle rect (`10 x 10` at 1x).
    public let chestPortRect: CGRect
    /// Cheek blush ellipses inside the head.
    public let leftBlushRect: CGRect
    public let rightBlushRect: CGRect
    /// Arm shoulder rotation pivots in idle-window coordinates.
    public let leftShoulderAnchor: CGPoint
    public let rightShoulderAnchor: CGPoint
    /// Visual centers of resting arms in idle-window coordinates.
    public let leftArmVisualCenter: CGPoint
    public let rightArmVisualCenter: CGPoint
    /// Resting foot rects.
    public let leftFootRect: CGRect
    public let rightFootRect: CGRect
    /// Ground shadow ellipse rect — strictly excluded from body hit-testing.
    public let groundShadowRect: CGRect
    /// Accessory centers above head for rolling dizzy stars and thinking dots.
    public let dizzyStarCenters: [CGPoint]
    public let thinkingDotCenters: [CGPoint]

    // Private anchor-local arm capsule rect relative to shoulder pivot.
    private let armCapsuleAroundShoulder: CGRect
    private let armCornerRadius: CGFloat

    fileprivate init(scale: CGFloat) {
        self.scale = scale
        self.rollingBodyWidth = Self.torsoWidthAt1x * scale
        self.bodyStrokeWidth = DesignTokens.strokes.scaledWidth(DesignTokens.strokes.bodyStrokeWidthAt1x, scale: scale)
        self.safeMargin = DesignTokens.motion.safeCanvasMarginAt1x * scale

        let s = scale
        let localHead = CGRect(x: -22 * s, y: 41 * s, width: Self.headWidthAt1x * s, height: Self.headHeightAt1x * s)
        let localTorso = CGRect(x: -42 * s, y: -46 * s, width: Self.torsoWidthAt1x * s, height: Self.torsoHeightAt1x * s)
        let localChestPort = CGRect(x: 9 * s, y: 14 * s, width: Self.chestPortDiameterAt1x * s, height: Self.chestPortDiameterAt1x * s)
        let localLeftBlush = CGRect(x: -18.25 * s, y: 49.4 * s, width: 7.5 * s, height: 4.2 * s)
        let localRightBlush = CGRect(x: 10.75 * s, y: 49.4 * s, width: 7.5 * s, height: 4.2 * s)
        let localLeftShoulder = CGPoint(x: -31 * s, y: 26 * s)
        let localRightShoulder = CGPoint(x: 31 * s, y: 26 * s)
        let armCapsule = CGRect(x: -9 * s, y: -45 * s, width: Self.armWidthAt1x * s, height: Self.armHeightAt1x * s)
        let armRadius = Self.armCornerRadiusAt1x * s
        let localLeftFoot = CGRect(x: -23 * s, y: -58 * s, width: Self.footWidthAt1x * s, height: Self.footHeightAt1x * s)
        let localRightFoot = CGRect(x: 3 * s, y: -58 * s, width: Self.footWidthAt1x * s, height: Self.footHeightAt1x * s)
        let localShadow = CGRect(x: -36 * s, y: -68 * s, width: 72 * s, height: 10 * s)

        let localLeftArmPath = Self.makeArmPath(
            shoulder: localLeftShoulder,
            capsuleAroundShoulder: armCapsule,
            cornerRadius: armRadius,
            rotationDegrees: Self.leftArmRestingDegrees
        )
        let localRightArmPath = Self.makeArmPath(
            shoulder: localRightShoulder,
            capsuleAroundShoulder: armCapsule,
            cornerRadius: armRadius,
            rotationDegrees: Self.rightArmRestingDegrees
        )

        let localBodyTight = localHead
            .union(localTorso)
            .union(localLeftArmPath.boundingBoxOfPath)
            .union(localRightArmPath.boundingBoxOfPath)
            .union(localLeftFoot)
            .union(localRightFoot)
        let halfStroke = bodyStrokeWidth / 2
        let localBodyPaint = localBodyTight.insetBy(dx: -halfStroke, dy: -halfStroke)

        // Envelope over all in-window poses (idle, breathing, poke, drag tilt) + shadow + head accessories.
        let inWindowPoses: [MotionPose] = [
            MotionPose(),
            MotionEngine.breathPeak(reducedMotion: false),
            MotionEngine.poke(at: 0.09),
            MotionEngine.dragging(horizontalVelocity: 500),
            MotionEngine.dragging(horizontalVelocity: -500),
        ]
        var localEnvelope = localBodyPaint.union(localShadow)
        let accessoryHeadroom = CGRect(x: -24 * s, y: 74 * s, width: 48 * s, height: 12 * s)
        localEnvelope = localEnvelope.union(accessoryHeadroom)
        for pose in inWindowPoses {
            localEnvelope = localEnvelope.union(Self.transformRect(localBodyPaint, aroundOriginWith: pose))
        }

        let halfWidth = ceil(max(abs(localEnvelope.minX), abs(localEnvelope.maxX)) + safeMargin)
        let bottomSpan = ceil(max(0, -localEnvelope.minY) + safeMargin)
        let topSpan = ceil(max(0, localEnvelope.maxY) + safeMargin)

        let windowSize = CGSize(width: halfWidth * 2, height: bottomSpan + topSpan)
        let pivot = CGPoint(x: halfWidth, y: bottomSpan)

        self.idleWindowSize = windowSize
        self.anchor = pivot
        self.armCapsuleAroundShoulder = armCapsule
        self.armCornerRadius = armRadius

        self.bodyPaintBounds = localBodyPaint.offsetBy(dx: pivot.x, dy: pivot.y)
        self.headRect = localHead.offsetBy(dx: pivot.x, dy: pivot.y)
        self.torsoRect = localTorso.offsetBy(dx: pivot.x, dy: pivot.y)
        self.chestPortRect = localChestPort.offsetBy(dx: pivot.x, dy: pivot.y)
        self.leftBlushRect = localLeftBlush.offsetBy(dx: pivot.x, dy: pivot.y)
        self.rightBlushRect = localRightBlush.offsetBy(dx: pivot.x, dy: pivot.y)
        self.leftShoulderAnchor = CGPoint(x: pivot.x + localLeftShoulder.x, y: pivot.y + localLeftShoulder.y)
        self.rightShoulderAnchor = CGPoint(x: pivot.x + localRightShoulder.x, y: pivot.y + localRightShoulder.y)
        self.leftFootRect = localLeftFoot.offsetBy(dx: pivot.x, dy: pivot.y)
        self.rightFootRect = localRightFoot.offsetBy(dx: pivot.x, dy: pivot.y)
        self.groundShadowRect = localShadow.offsetBy(dx: pivot.x, dy: pivot.y)

        let leftCenterLocal = Self.rotatePoint(CGPoint(x: 0, y: -18 * s), degrees: Self.leftArmRestingDegrees)
        let rightCenterLocal = Self.rotatePoint(CGPoint(x: 0, y: -18 * s), degrees: Self.rightArmRestingDegrees)
        self.leftArmVisualCenter = CGPoint(
            x: leftShoulderAnchor.x + leftCenterLocal.x,
            y: leftShoulderAnchor.y + leftCenterLocal.y
        )
        self.rightArmVisualCenter = CGPoint(
            x: rightShoulderAnchor.x + rightCenterLocal.x,
            y: rightShoulderAnchor.y + rightCenterLocal.y
        )

        self.dizzyStarCenters = [
            CGPoint(x: pivot.x - 13 * s, y: pivot.y + 80 * s),
            CGPoint(x: pivot.x + 13 * s, y: pivot.y + 83 * s),
        ]
        self.thinkingDotCenters = [
            CGPoint(x: pivot.x - 10 * s, y: pivot.y + 80 * s),
            CGPoint(x: pivot.x, y: pivot.y + 82 * s),
            CGPoint(x: pivot.x + 10 * s, y: pivot.y + 80 * s),
        ]
    }

    // MARK: - Shared-Source Paths (Idle-Window Coordinates)

    public func makeHeadPath() -> CGPath {
        CGPath(ellipseIn: headRect, transform: nil)
    }

    /// Pear-shaped marshmallow torso whose cubic Bezier convex hull equals `torsoRect` (`84 x 92` at 1x).
    /// Wound counter-clockwise to match `CGPath(ellipseIn:)` / `CGPath(roundedRect:)` so overlapping
    /// subpaths in `makeCombinedBodyPath()` never cancel under non-zero winding fills or hit-testing.
    public func makeTorsoPath() -> CGPath {
        let s = scale
        let ax = anchor.x
        let ay = anchor.y
        let path = CGMutablePath()
        path.move(to: CGPoint(x: ax, y: ay + 46 * s))
        path.addCurve(
            to: CGPoint(x: ax - 42 * s, y: ay - 8 * s),
            control1: CGPoint(x: ax - 24 * s, y: ay + 46 * s),
            control2: CGPoint(x: ax - 42 * s, y: ay + 22 * s)
        )
        path.addCurve(
            to: CGPoint(x: ax, y: ay - 46 * s),
            control1: CGPoint(x: ax - 42 * s, y: ay - 32 * s),
            control2: CGPoint(x: ax - 24 * s, y: ay - 46 * s)
        )
        path.addCurve(
            to: CGPoint(x: ax + 42 * s, y: ay - 8 * s),
            control1: CGPoint(x: ax + 24 * s, y: ay - 46 * s),
            control2: CGPoint(x: ax + 42 * s, y: ay - 32 * s)
        )
        path.addCurve(
            to: CGPoint(x: ax, y: ay + 46 * s),
            control1: CGPoint(x: ax + 42 * s, y: ay + 22 * s),
            control2: CGPoint(x: ax + 24 * s, y: ay + 46 * s)
        )
        path.closeSubpath()
        return path.copy() ?? path
    }

    public func makeLeftArmPath(rotationDegrees: CGFloat? = nil) -> CGPath {
        Self.makeArmPath(
            shoulder: leftShoulderAnchor,
            capsuleAroundShoulder: armCapsuleAroundShoulder,
            cornerRadius: armCornerRadius,
            rotationDegrees: rotationDegrees ?? Self.leftArmRestingDegrees
        )
    }

    public func makeRightArmPath(rotationDegrees: CGFloat? = nil) -> CGPath {
        Self.makeArmPath(
            shoulder: rightShoulderAnchor,
            capsuleAroundShoulder: armCapsuleAroundShoulder,
            cornerRadius: armCornerRadius,
            rotationDegrees: rotationDegrees ?? Self.rightArmRestingDegrees
        )
    }

    public func makeLeftFootPath() -> CGPath {
        CGPath(roundedRect: leftFootRect, cornerWidth: 8 * scale, cornerHeight: 7 * scale, transform: nil)
    }

    public func makeRightFootPath() -> CGPath {
        CGPath(roundedRect: rightFootRect, cornerWidth: 8 * scale, cornerHeight: 7 * scale, transform: nil)
    }

    /// Combined Baymax silhouette path shared by rendering and hit-testing.
    /// Ground shadow and ambient glow auras are intentionally excluded.
    public func makeCombinedBodyPath(
        leftArmDegrees: CGFloat? = nil,
        rightArmDegrees: CGFloat? = nil
    ) -> CGPath {
        let combined = CGMutablePath()
        combined.addPath(makeLeftFootPath())
        combined.addPath(makeRightFootPath())
        combined.addPath(makeLeftArmPath(rotationDegrees: leftArmDegrees))
        combined.addPath(makeRightArmPath(rotationDegrees: rightArmDegrees))
        combined.addPath(makeTorsoPath())
        combined.addPath(makeHeadPath())
        return combined.copy() ?? combined
    }

    public func makeChestPortPath() -> CGPath {
        CGPath(ellipseIn: chestPortRect, transform: nil)
    }

    public func makeGroundShadowPath() -> CGPath {
        CGPath(ellipseIn: groundShadowRect, transform: nil)
    }

    public func makeBlushPaths() -> (left: CGPath, right: CGPath) {
        (
            CGPath(ellipseIn: leftBlushRect, transform: nil),
            CGPath(ellipseIn: rightBlushRect, transform: nil)
        )
    }

    /// Eye geometry interpolating height from `1.5 * scale` (closed, 0) to `6.2 * scale` (open, 1).
    public func eyeGeometry(openness: Double) -> BaymaxEyeGeometry {
        let clampedOpenness: CGFloat
        if openness.isFinite {
            clampedOpenness = CGFloat(min(1.0, max(0.0, openness)))
        } else {
            clampedOpenness = 1.0
        }
        let s = scale
        let eyeWidth = Self.eyeOpenDiameterAt1x * s
        let closedHeight = Self.eyeClosedHeightAt1x * s
        let eyeHeight = closedHeight + (eyeWidth - closedHeight) * clampedOpenness
        let halfSpacing = (Self.eyeCenterSpacingAt1x / 2) * s
        let centerY = headRect.midY
        let leftCenter = CGPoint(x: headRect.midX - halfSpacing, y: centerY)
        let rightCenter = CGPoint(x: headRect.midX + halfSpacing, y: centerY)

        return BaymaxEyeGeometry(
            leftEyeRect: CGRect(
                x: leftCenter.x - eyeWidth / 2,
                y: leftCenter.y - eyeHeight / 2,
                width: eyeWidth,
                height: eyeHeight
            ),
            rightEyeRect: CGRect(
                x: rightCenter.x - eyeWidth / 2,
                y: rightCenter.y - eyeHeight / 2,
                width: eyeWidth,
                height: eyeHeight
            ),
            bridgeStart: leftCenter,
            bridgeEnd: rightCenter,
            bridgeLineWidth: DesignTokens.strokes.scaledWidth(DesignTokens.strokes.eyeBridgeWidthAt1x, scale: s)
        )
    }

    // MARK: - Envelope & Hit-Testing

    /// Transformed axis-aligned bounding box of `bodyPaintBounds` under `pose`
    /// (matching `ScreenGeometry.RollPlan`: local scale -> rotation -> translation).
    public func transformedBodyBounds(
        for pose: MotionPose,
        atCanvasAnchor canvasAnchor: CGPoint? = nil
    ) -> CGRect {
        let pivot = canvasAnchor ?? anchor
        let relative = bodyPaintBounds.offsetBy(dx: -anchor.x, dy: -anchor.y)
        let transformed = Self.transformRect(relative, aroundOriginWith: pose)
        return transformed.offsetBy(dx: pivot.x, dy: pivot.y)
    }

    /// Same-source silhouette hit test for `PetFloatingPanel.BodyHitTest`.
    /// - Parameters:
    ///   - point: Pointer coordinate in view coordinates (points, +Y up).
    ///   - pose: Active `MotionPose` (identity at rest).
    ///   - canvasAnchor: Active anchor in canvas coordinates (defaults to idle `anchor`).
    ///   - outwardMargin: Outward hysteresis margin in points (`0` on entry, `2` while tracking).
    /// - Returns: `true` only when `point` hits the Baymax body silhouette (excluding ground shadow and transparency).
    public func containsBodyPoint(
        _ point: CGPoint,
        pose: MotionPose = MotionPose(),
        atCanvasAnchor canvasAnchor: CGPoint? = nil,
        outwardMargin: CGFloat = 0
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite, outwardMargin.isFinite,
              pose.offsetX.isFinite, pose.offsetY.isFinite, pose.rotationDegrees.isFinite,
              pose.scaleX.isFinite, pose.scaleY.isFinite,
              abs(pose.scaleX) > 1e-6, abs(pose.scaleY) > 1e-6 else {
            return false
        }

        let margin = max(0, outwardMargin)
        let localPoint: CGPoint
        if pose == MotionPose(), canvasAnchor == nil {
            localPoint = point
        } else {
            let pivot = canvasAnchor ?? anchor
            let dx = point.x - (pivot.x + CGFloat(pose.offsetX))
            let dy = point.y - (pivot.y + CGFloat(pose.offsetY))
            let rad = CGFloat(-pose.rotationDegrees) * .pi / 180
            let rx = dx * cos(rad) - dy * sin(rad)
            let ry = dx * sin(rad) + dy * cos(rad)
            localPoint = CGPoint(
                x: anchor.x + rx / CGFloat(pose.scaleX),
                y: anchor.y + ry / CGFloat(pose.scaleY)
            )
        }

        let quickRect = bodyPaintBounds.insetBy(dx: -(margin + 2), dy: -(margin + 2))
        guard quickRect.contains(localPoint) else { return false }

        let bodyPath = makeCombinedBodyPath()
        if bodyPath.contains(localPoint, using: .winding) {
            return true
        }
        guard margin > 0 else { return false }

        let expanded = bodyPath.copy(
            strokingWithWidth: margin * 2,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 4
        )
        return expanded.contains(localPoint, using: .winding)
    }

    // MARK: - Helpers

    private static func makeArmPath(
        shoulder: CGPoint,
        capsuleAroundShoulder: CGRect,
        cornerRadius: CGFloat,
        rotationDegrees: CGFloat
    ) -> CGPath {
        var transform = CGAffineTransform(translationX: shoulder.x, y: shoulder.y)
            .rotated(by: rotationDegrees * .pi / 180)
        return CGPath(
            roundedRect: capsuleAroundShoulder,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: &transform
        )
    }

    private static func rotatePoint(_ point: CGPoint, degrees: CGFloat) -> CGPoint {
        let rad = degrees * .pi / 180
        let c = cos(rad)
        let s = sin(rad)
        return CGPoint(x: point.x * c - point.y * s, y: point.x * s + point.y * c)
    }

    private static func transformRect(_ relative: CGRect, aroundOriginWith pose: MotionPose) -> CGRect {
        let rad = CGFloat(pose.rotationDegrees) * .pi / 180
        let c = cos(rad)
        let s = sin(rad)
        let sx = CGFloat(pose.scaleX)
        let sy = CGFloat(pose.scaleY)
        let ox = CGFloat(pose.offsetX)
        let oy = CGFloat(pose.offsetY)

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for x in [relative.minX, relative.maxX] {
            for y in [relative.minY, relative.maxY] {
                let lx = x * sx
                let ly = y * sy
                let tx = ox + lx * c - ly * s
                let ty = oy + lx * s + ly * c
                minX = min(minX, tx)
                minY = min(minY, ty)
                maxX = max(maxX, tx)
                maxY = max(maxY, ty)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public enum BaymaxGeometry {
    /// Returns a layout for one of the three supported UI scale presets (`0.8`, `1.0`, `1.25`).
    public static func layout(scale: BaymaxScale) -> BaymaxLayout {
        BaymaxLayout(scale: scale.factor)
    }

    /// Returns a layout for any finite positive scale factor, or `nil` for invalid inputs (`<= 0`, `NaN`, `infinity`).
    public static func makeLayout(scaleFactor: CGFloat) -> BaymaxLayout? {
        guard scaleFactor.isFinite, scaleFactor > 0 else { return nil }
        return BaymaxLayout(scale: scaleFactor)
    }

    /// Idle window size derived from the complete pose envelope plus safe margin.
    public static func idleWindowSize(scale: BaymaxScale) -> CGSize {
        layout(scale: scale).idleWindowSize
    }

    /// Convenience overload accepting a raw `CGFloat` scale factor; returns `nil` for invalid scales.
    public static func idleWindowSize(scaleFactor: CGFloat) -> CGSize? {
        makeLayout(scaleFactor: scaleFactor)?.idleWindowSize
    }
}
