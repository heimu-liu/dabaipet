import CoreGraphics
import DabaiPetCore
import Foundation
import Testing

@Suite("BaymaxGeometry")
struct BaymaxGeometryTests {
    private static let eps: CGFloat = 1e-4

    @Test func standard1xAnatomyMatchesUIUXSpecDimensions() {
        let layout = BaymaxGeometry.layout(scale: .standard)

        // Coordinate system & scale
        #expect(layout.scale == 1.0)
        #expect(layout.rollingBodyWidth == 84.0)

        // Head: 44 x 31 pt
        #expect(abs(layout.headRect.width - 44.0) < Self.eps)
        #expect(abs(layout.headRect.height - 31.0) < Self.eps)

        // Torso: 84 x 92 pt exact Bezier bounding box
        let torsoBounds = layout.makeTorsoPath().boundingBoxOfPath
        #expect(abs(layout.torsoRect.width - 84.0) < Self.eps)
        #expect(abs(layout.torsoRect.height - 92.0) < Self.eps)
        #expect(abs(torsoBounds.width - 84.0) < 0.05)
        #expect(abs(torsoBounds.height - 92.0) < 0.05)

        // Eyes: 6.2 pt open diameter, 18 pt center spacing, 1.5 pt closed height & bridge width
        let openEyes = layout.eyeGeometry(openness: 1.0)
        let closedEyes = layout.eyeGeometry(openness: 0.0)
        #expect(abs(openEyes.leftEyeRect.width - 6.2) < Self.eps)
        #expect(abs(openEyes.leftEyeRect.height - 6.2) < Self.eps)
        #expect(abs(openEyes.rightEyeRect.width - 6.2) < Self.eps)
        #expect(abs(openEyes.rightEyeRect.height - 6.2) < Self.eps)
        #expect(abs((openEyes.rightEyeRect.midX - openEyes.leftEyeRect.midX) - 18.0) < Self.eps)
        #expect(abs(closedEyes.leftEyeRect.height - 1.5) < Self.eps)
        #expect(abs(openEyes.bridgeLineWidth - 1.5) < Self.eps)

        // Chest port: 10 pt diameter, inside torso
        #expect(abs(layout.chestPortRect.width - 10.0) < Self.eps)
        #expect(abs(layout.chestPortRect.height - 10.0) < Self.eps)
        #expect(layout.makeTorsoPath().contains(CGPoint(x: layout.chestPortRect.midX, y: layout.chestPortRect.midY)))

        // Positive Y is upwards: head above torso above feet above ground shadow bottom
        #expect(layout.headRect.midY > layout.torsoRect.midY)
        #expect(layout.torsoRect.midY > layout.leftFootRect.midY)
        #expect(layout.leftFootRect.minY > layout.groundShadowRect.minY)
        #expect(layout.leftShoulderAnchor.x < layout.anchor.x)
        #expect(layout.rightShoulderAnchor.x > layout.anchor.x)
    }

    @Test func supportedScalesMonotonicallyScaleDimensionsAndIdleWindowSize() {
        let small = BaymaxGeometry.layout(scale: .small)
        let standard = BaymaxGeometry.layout(scale: .standard)
        let large = BaymaxGeometry.layout(scale: .large)

        #expect(BaymaxScale.allCases == [.small, .standard, .large])
        #expect(BaymaxGeometry.idleWindowSize(scale: .small) == small.idleWindowSize)
        #expect(BaymaxGeometry.idleWindowSize(scale: .standard) == standard.idleWindowSize)
        #expect(BaymaxGeometry.idleWindowSize(scale: .large) == large.idleWindowSize)

        // Monotonic window growth
        #expect(small.idleWindowSize.width < standard.idleWindowSize.width)
        #expect(standard.idleWindowSize.width < large.idleWindowSize.width)
        #expect(small.idleWindowSize.height < standard.idleWindowSize.height)
        #expect(standard.idleWindowSize.height < large.idleWindowSize.height)

        // Proportional torso rolling width
        #expect(abs(small.rollingBodyWidth - 84.0 * 0.8) < Self.eps)
        #expect(abs(large.rollingBodyWidth - 84.0 * 1.25) < Self.eps)

        // Integer point sizes for crisp AppKit window frames
        for layout in [small, standard, large] {
            #expect(layout.idleWindowSize.width == layout.idleWindowSize.width.rounded())
            #expect(layout.idleWindowSize.height == layout.idleWindowSize.height.rounded())
        }
    }

    @Test func invalidScaleFactorsAreRejectedSafely() {
        #expect(BaymaxGeometry.makeLayout(scaleFactor: 0) == nil)
        #expect(BaymaxGeometry.makeLayout(scaleFactor: -0.5) == nil)
        #expect(BaymaxGeometry.makeLayout(scaleFactor: .nan) == nil)
        #expect(BaymaxGeometry.makeLayout(scaleFactor: .infinity) == nil)
        #expect(BaymaxGeometry.makeLayout(scaleFactor: -.infinity) == nil)

        // Positive finite scales succeed
        #expect(BaymaxGeometry.makeLayout(scaleFactor: 0.8)?.scale == 0.8)
        #expect(BaymaxGeometry.makeLayout(scaleFactor: 1.0)?.scale == 1.0)
        #expect(BaymaxGeometry.makeLayout(scaleFactor: 1.25)?.scale == 1.25)
    }

    @Test(arguments: BaymaxScale.allCases)
    func idleWindowContainsAllInWindowPosesAndSafeMargin(scale: BaymaxScale) {
        let layout = BaymaxGeometry.layout(scale: scale)
        let windowRect = CGRect(origin: .zero, size: layout.idleWindowSize)
        let margin = DesignTokens.motion.safeCanvasMarginAt1x * layout.scale
        let safeInnerRect = windowRect.insetBy(dx: margin - 0.5, dy: margin - 0.5)

        // Resting body paint bounds (including stroke) and ground shadow fit inside safe margin
        #expect(safeInnerRect.contains(layout.bodyPaintBounds))
        #expect(safeInnerRect.contains(layout.groundShadowRect))

        // Every in-window pose (idle, breath peak, poke peak, max drag tilt left/right) stays within window
        let poses: [MotionPose] = [
            MotionPose(),
            MotionEngine.breathPeak(reducedMotion: false),
            MotionEngine.breathPeak(reducedMotion: true),
            MotionEngine.poke(at: 0.09),
            MotionEngine.dragging(horizontalVelocity: 500),
            MotionEngine.dragging(horizontalVelocity: -500),
        ]

        for pose in poses {
            let transformed = layout.transformedBodyBounds(for: pose)
            #expect(windowRect.contains(transformed), "Pose \(pose) clipped at scale \(scale.rawValue): \(transformed) not in \(windowRect)")
        }
    }

    @Test(arguments: BaymaxScale.allCases)
    func geometryIntegratesWithScreenGeometryWideRollWithoutClipping(scale: BaymaxScale) throws {
        let layout = BaymaxGeometry.layout(scale: scale)
        let screen = CGRect(x: 0, y: 56, width: 1512, height: 893)
        let start = CGRect(origin: CGPoint(x: 400, y: 200), size: layout.idleWindowSize)

        for direction in [RollDirection.left, .right] {
            for reduced in [false, true] {
                let plan = try #require(
                    ScreenGeometry.wideRollFrame(
                        startFrame: start,
                        visibleFrame: screen,
                        bodyBounds: layout.bodyPaintBounds,
                        anchor: layout.anchor,
                        preferredDirection: direction,
                        reducedMotion: reduced,
                        rollingBodyWidth: layout.rollingBodyWidth
                    )
                )
                let canvas = CGRect(origin: .zero, size: plan.wideFrame.size).insetBy(dx: -1e-6, dy: -1e-6)
                for frame in 0...264 {
                    let pose = plan.pose(at: Double(frame) / 120.0)
                    let transformed = layout.transformedBodyBounds(for: pose, atCanvasAnchor: plan.anchorInCanvas)
                    #expect(canvas.contains(transformed), "Roll frame \(frame) clipped at scale \(scale.rawValue)")
                }
            }
        }
    }

    @Test(arguments: BaymaxScale.allCases)
    func hitTestingUsesSameSourceSilhouetteAndExcludesShadowAndTransparency(scale: BaymaxScale) {
        let layout = BaymaxGeometry.layout(scale: scale)
        let bodyPath = layout.makeCombinedBodyPath()

        // Positive hits: head, torso, left/right arm, left/right foot, plus neck/shoulder/foot overlap zones
        let positivePoints: [CGPoint] = [
            CGPoint(x: layout.headRect.midX, y: layout.headRect.midY),
            CGPoint(x: layout.torsoRect.midX, y: layout.torsoRect.midY),
            CGPoint(x: layout.anchor.x, y: layout.torsoRect.maxY - 2 * layout.scale), // head-torso neck overlap
            layout.leftShoulderAnchor,                                                 // left arm-torso overlap
            layout.rightShoulderAnchor,                                                // right arm-torso overlap
            layout.leftArmVisualCenter,
            layout.rightArmVisualCenter,
            CGPoint(x: layout.leftFootRect.midX, y: layout.torsoRect.minY + 1 * layout.scale), // foot-torso overlap
            CGPoint(x: layout.leftFootRect.midX, y: layout.leftFootRect.midY),
            CGPoint(x: layout.rightFootRect.midX, y: layout.rightFootRect.midY),
        ]
        for pt in positivePoints {
            #expect(bodyPath.contains(pt), "Shared path must contain \(pt)")
            #expect(layout.containsBodyPoint(pt, outwardMargin: 0), "Hit test must accept \(pt)")
        }

        // Negative hits: 4 transparent window corners
        let w = layout.idleWindowSize.width
        let h = layout.idleWindowSize.height
        let corners = [
            CGPoint(x: 1, y: 1),
            CGPoint(x: w - 1, y: 1),
            CGPoint(x: 1, y: h - 1),
            CGPoint(x: w - 1, y: h - 1),
        ]
        for corner in corners {
            #expect(!layout.containsBodyPoint(corner, outwardMargin: 0))
            #expect(!layout.containsBodyPoint(corner, outwardMargin: 2))
        }

        // Negative hit: concave transparent notch beside head & above left arm (proves not a bounding-box check)
        let headSideNotch = CGPoint(x: layout.headRect.minX - 10 * layout.scale, y: layout.headRect.midY)
        #expect(!layout.containsBodyPoint(headSideNotch, outwardMargin: 0))

        // Negative hit: ground shadow area below feet MUST NOT register as body hit (even with 2pt margin)
        let shadowOnlyPoint = CGPoint(x: layout.groundShadowRect.midX, y: layout.groundShadowRect.minY + 1.0 * layout.scale)
        #expect(layout.makeGroundShadowPath().contains(shadowOnlyPoint))
        #expect(!layout.containsBodyPoint(shadowOnlyPoint, outwardMargin: 0))
        #expect(!layout.containsBodyPoint(shadowOnlyPoint, outwardMargin: 2))
    }

    @Test func hitTestingOutwardHysteresisMarginAndInvalidInputs() {
        let layout = BaymaxGeometry.layout(scale: .standard)

        // Rightmost waist edge of torso is at anchor.x + 42.0 (widest torso point, y = anchor.y - 8.0)
        // Find exact outer edge point on right side of head (head is clean ellipse, unobstructed by arms)
        let rightHeadEdgeX = layout.headRect.maxX
        let headMidY = layout.headRect.midY
        let slightlyOutside = CGPoint(x: rightHeadEdgeX + 1.2, y: headMidY)
        let farOutside = CGPoint(x: rightHeadEdgeX + 4.5, y: headMidY)

        #expect(!layout.containsBodyPoint(slightlyOutside, outwardMargin: 0))
        #expect(layout.containsBodyPoint(slightlyOutside, outwardMargin: 2))
        #expect(!layout.containsBodyPoint(farOutside, outwardMargin: 2))

        // Non-finite inputs and negative margins must not crash and must return deterministic safe results
        #expect(!layout.containsBodyPoint(CGPoint(x: CGFloat.nan, y: layout.anchor.y), outwardMargin: 0))
        #expect(!layout.containsBodyPoint(CGPoint(x: layout.anchor.x, y: CGFloat.infinity), outwardMargin: 2))
        #expect(!layout.containsBodyPoint(layout.anchor, outwardMargin: .nan))
        #expect(!layout.containsBodyPoint(layout.anchor, outwardMargin: .infinity))
        #expect(layout.containsBodyPoint(layout.anchor, outwardMargin: -5))
    }

    @Test func transformedHitTestAndEyeOpennessClamping() {
        let layout = BaymaxGeometry.layout(scale: .standard)
        let shiftedPose = MotionPose(offsetX: 25, offsetY: 10, rotationDegrees: 0, scaleX: 1, scaleY: 1)
        let shiftedCenter = CGPoint(x: layout.anchor.x + 25, y: layout.anchor.y + 10)

        #expect(layout.containsBodyPoint(shiftedCenter, pose: shiftedPose, outwardMargin: 0))
        #expect(!layout.containsBodyPoint(CGPoint(x: 1, y: 1), pose: shiftedPose, outwardMargin: 0))

        // Eye openness clamps cleanly outside [0, 1] and handles NaN
        let clampedLow = layout.eyeGeometry(openness: -0.5)
        let closed = layout.eyeGeometry(openness: 0.0)
        let clampedHigh = layout.eyeGeometry(openness: 1.8)
        let open = layout.eyeGeometry(openness: 1.0)
        let nanOpen = layout.eyeGeometry(openness: .nan)

        #expect(clampedLow.leftEyeRect == closed.leftEyeRect)
        #expect(clampedHigh.leftEyeRect == open.leftEyeRect)
        #expect(nanOpen.leftEyeRect == open.leftEyeRect)
    }
}
