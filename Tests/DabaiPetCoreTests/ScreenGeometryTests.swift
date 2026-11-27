import CoreGraphics
import DabaiPetCore
import Foundation
import Testing

struct ScreenGeometryTests {
    @Test(arguments: [0.8, 1.0, 1.25])
    func angleTracksBodyScaleAndActualTravel(scale: Double) throws {
        // 84 pt torso and 180 pt nominal roll are the UI specification's 1x dimensions.
        let width = 84 * scale
        let size = CGSize(width: 160*scale, height: 170*scale)
        let bounds = CGRect(x: 37*scale, y: 28*scale, width: width, height: 108*scale)
        let pivot = CGPoint(x: 80*scale, y: 85*scale)
        for direction in [RollDirection.left, .right] {
            for distance in [0.0, 1.0, 40.0, 180.0] {
                let screen = CGRect(x: -1000, y: -200, width: size.width + distance, height: 500)
                let x = direction == .right ? screen.minX : screen.maxX - size.width
                let start = CGRect(origin: CGPoint(x: x, y: 0), size: size)
                for reduced in [false, true] {
                    let plan = try #require(ScreenGeometry.wideRollFrame(startFrame: start, visibleFrame: screen,
                        bodyBounds: bounds, anchor: pivot, preferredDirection: direction, reducedMotion: reduced))
                    let peak = plan.pose(at: 1.25)
                    let sign = direction == .right ? 1.0 : -1.0
                    #expect(abs(peak.offsetX - sign * min(distance, reduced ? 60 : 180)) < 1e-8)
                    var last = plan.pose(at: 0)
                    var largestAngle = 0.0
                    for i in 0...264 {
                        let p = plan.pose(at: Double(i)/120)
                        if reduced || distance == 0 {
                            if p.rotationDegrees != 0 { Issue.record("rotation without rolling"); break }
                        } else if (30...150).contains(i) {
                            if abs(p.rotationDegrees + p.offsetX * 2 / scale) > 1e-7 {
                                Issue.record("arc-length mismatch at frame \(i), travel \(distance), scale \(scale)")
                                break
                            }
                        }
                        // Largest nominal angular speed here is under 5 degrees/frame;
                        // a hidden snap at a phase boundary must fail independently of its final angle.
                        if abs(p.rotationDegrees-last.rotationDegrees) > 6 {
                            Issue.record("angular discontinuity at frame \(i)"); break
                        }
                        largestAngle = max(largestAngle, abs(p.rotationDegrees))
                        last = p
                    }
                    let end = plan.pose(at: 2.2)
                    #expect(abs(end.rotationDegrees.truncatingRemainder(dividingBy: 360)) < 1e-8)
                    #expect(end.offsetY == 0 && end.scaleX == 1 && end.scaleY == 1)
                    #expect(abs(plan.startFrame.minX + end.offsetX - plan.endFrame.minX) < 1e-8)
                    if distance <= 40 {
                        #expect(largestAngle <= distance * 2 / scale + 1e-7)
                        #expect(end.rotationDegrees == 0)
                    }
                }
            }
        }
    }
    // Asymmetric, off-center painted rectangle in a tight idle window. Verify its
    // four actual transformed vertices, independently of the planner's extents.
    private func vertices(_ bounds: CGRect, anchor: CGPoint, at canvasAnchor: CGPoint, pose: MotionPose) -> [CGPoint] {
        let theta = pose.rotationDegrees * .pi / 180
        return [bounds.minX, bounds.maxX].flatMap { x in
            [bounds.minY, bounds.maxY].map { y in
                let dx = (x - anchor.x) * pose.scaleX, dy = (y - anchor.y) * pose.scaleY
                return CGPoint(x: canvasAnchor.x + pose.offsetX + dx*cos(theta) - dy*sin(theta),
                               y: canvasAnchor.y + pose.offsetY + dx*sin(theta) + dy*cos(theta))
            }
        }
    }

    @Test(arguments: [0.8, 1.0, 1.25])
    func allFramesAndCorners(scale s: Double) throws {
        let size = CGSize(width: 112*s, height: 146*s)
        let bounds = CGRect(x: 7*s, y: 6*s, width: 97*s, height: 132*s)
        let anchor = CGPoint(x: 50*s, y: 63*s)
        for screen in [CGRect(x: 0, y: 56, width: 1512, height: 893),
                       CGRect(x: -1536, y: -320, width: 1480, height: 920)] {
            for x in [screen.minX, screen.midX, screen.maxX - size.width] {
                for y in [screen.minY, screen.maxY - size.height] {
                    let idle = CGRect(origin: CGPoint(x: x, y: y), size: size)
                    for preferred in [RollDirection.left, .right] {
                        for reduced in [false, true] {
                            let plan = try #require(ScreenGeometry.wideRollFrame(startFrame: idle, visibleFrame: screen,
                                bodyBounds: bounds, anchor: anchor, preferredDirection: preferred, reducedMotion: reduced))
                            let wide = plan.wideFrame
                            #expect(screen.contains(wide) && wide.contains(plan.startFrame) && wide.contains(plan.endFrame))
                            let dir: RollDirection = x == screen.minX ? .right : (x == screen.maxX-size.width ? .left : preferred)
                            #expect(plan.direction == dir)
                            let dx = (dir == .right ? 1.0 : -1.0) * (reduced ? 60 : 180)
                            #expect(abs(plan.endFrame.minX - idle.minX - 0.9*dx) < 1e-8)
                            #expect(plan.pose(at: 0) == MotionPose())
                            let end = plan.pose(at: 2.2)
                            #expect(abs(plan.anchorInCanvas.x + end.offsetX + wide.minX - plan.endFrame.minX - anchor.x) < 1e-8)
                            #expect(abs(plan.anchorInCanvas.y + end.offsetY + wide.minY - plan.endFrame.minY - anchor.y) < 1e-8)
                            #expect(end.scaleX == 1 && end.scaleY == 1)
                            #expect(end.rotationDegrees.truncatingRemainder(dividingBy: 360) == 0)
                            let canvas = CGRect(origin: .zero, size: wide.size).insetBy(dx: -1e-8, dy: -1e-8)
                            for frame in 0...264 {
                                let pose = plan.pose(at: Double(frame)/120)
                                let corners = vertices(bounds, anchor: anchor, at: plan.anchorInCanvas, pose: pose)
                                if !corners.allSatisfy(canvas.contains) || (reduced && pose.rotationDegrees != 0) {
                                    Issue.record("Body escaped or reduced rotation at frame \(frame), \(idle), \(preferred), reduced=\(reduced)")
                                    return
                                }
                            }
                            for join in [0.25, 1.25, 1.85, 2.2] {
                                let l = plan.pose(at: join-1e-7), r = plan.pose(at: join+1e-7)
                                #expect(abs(l.offsetX-r.offsetX) + abs(l.offsetY-r.offsetY) < 0.001)
                                #expect(abs(l.rotationDegrees-r.rotationDegrees) < 0.001)
                                #expect(abs(l.scaleX-r.scaleX) + abs(l.scaleY-r.scaleY) < 0.001)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func rollPhasesAndLimitedTravel() throws {
        let rect = CGRect(x: 100, y: 200, width: 160, height: 170)
        let bounds = CGRect(x: 37, y: 28, width: 86, height: 108)
        let anchor = CGPoint(x: 80, y: 85)
        let plan = try #require(ScreenGeometry.wideRollFrame(startFrame: rect, visibleFrame: CGRect(x: -500,y: 0,width: 1200,height: 800),
            bodyBounds: bounds, anchor: anchor, preferredDirection: .right, reducedMotion: false))
        #expect(plan.pose(at: 0.25) == MotionPose(scaleX: 1.12, scaleY: 0.86))
        #expect(plan.pose(at: 0.75).offsetY > 0)
        #expect(plan.pose(at: 1.25).offsetX == 180)
        let calibratedSlope = 360.0 / 180 * (84 / bounds.width)
        #expect(abs(plan.pose(at: 0.75).rotationDegrees / plan.pose(at: 0.75).offsetX + calibratedSlope) < 1e-8)
        let small = try #require(ScreenGeometry.wideRollFrame(startFrame: rect, visibleFrame: CGRect(x: 100, y: 200, width: 200,height: 200),
            bodyBounds: bounds, anchor: anchor, preferredDirection: .left, reducedMotion: false))
        #expect(small.direction == .right && small.pose(at: 1.25).offsetX == 40)
        #expect(small.endFrame.minX == 136)
        #expect(ScreenGeometry.wideRollFrame(startFrame: rect, visibleFrame: CGRect(x: 0,y: 0,width: 20,height: 30),
            bodyBounds: bounds, anchor: anchor, preferredDirection: .left, reducedMotion: false) == nil)
        #expect(ScreenGeometry.clampedFrame(rect, to: CGRect(x: -500,y: -300,width: 400,height: 500)).maxX == -100)
    }

    @Test func tightPaintMarginPreservesPivotTravel() throws {
        let screen = CGRect(x: 0, y: 0, width: 220, height: 210)
        let body = CGRect(x: 0, y: 10, width: 100, height: 120)
        let pivot = CGPoint(x: 12, y: 72)
        let plan = try #require(ScreenGeometry.wideRollFrame(startFrame: CGRect(x: 0, y: 0, width: 180, height: 160),
            visibleFrame: screen, bodyBounds: body, anchor: pivot, rollingBodyWidth: 84))
        #expect(abs(plan.rollingRadius - 180 / (2 * Double.pi)) < 1e-8)
        let canvas = CGRect(origin: .zero, size: plan.wideFrame.size).insetBy(dx: -1e-8, dy: -1e-8)
        for i in 0...264 {
            let p = plan.pose(at: Double(i)/120)
            if (30...150).contains(i) && abs(p.rotationDegrees + 2*p.offsetX) > 1e-7 {
                Issue.record("horizontal boundary changed arc length at frame \(i)")
                return
            }
            let points = vertices(body, anchor: pivot, at: plan.anchorInCanvas, pose: p)
            #expect(points.allSatisfy(canvas.contains))
        }
    }
}
