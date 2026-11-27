import CoreGraphics
import Foundation

/// All coordinates are in points with positive y upwards. Frames are in screen
/// space; the supplied paint bounds and pivot are in the idle window's space.
public enum ScreenGeometry {
    public struct RollPlan: Sendable {
        public let startFrame: CGRect
        public let wideFrame: CGRect
        public let endFrame: CGRect
        public let direction: RollDirection
        public let anchorInCanvas: CGPoint
        public let rollingRadius: Double
        fileprivate let relativeBounds: CGRect
        fileprivate let travel: Double
        fileprivate let reducedMotion: Bool

        /// Keep the renderer at anchorInCanvas. Apply local scale, then rotation,
        /// then add the returned translation. At 2.2 s switch to endFrame and identity.
        public func pose(at seconds: Double) -> MotionPose {
            guard travel != 0 else { return MotionPose() }
            let finalOffset = endFrame.minX - startFrame.minX
            var pose = MotionEngine.roll(at: seconds, travel: travel, finalOffset: finalOffset,
                                         radius: rollingRadius, reducedMotion: reducedMotion)
            let angle = pose.rotationDegrees * .pi / 180
            let c = cos(angle), s = sin(angle)
            let mx = relativeBounds.midX * pose.scaleX, my = relativeBounds.midY * pose.scaleY
            let w = relativeBounds.width * pose.scaleX, h = relativeBounds.height * pose.scaleY
            // Project both half-axes about the paint pivot.
            let width = abs(c)*w + abs(s)*h, height = abs(s)*w + abs(c)*h
            let pivotX = anchorInCanvas.x + pose.offsetX
            let leftExtent = width/2 - (c*mx - s*my)
            let rightExtent = width/2 + (c*mx - s*my)
            // A paint envelope with no side padding can cross the physical screen
            // edge during squash/rotation. Fit about the pivot only as necessary;
            // moving the pivot sideways here would invalidate the rolling radius.
            var fit = 1.0
            if leftExtent > pivotX { fit = pivotX / leftExtent }
            let rightRoom = wideFrame.width - pivotX
            if rightExtent > rightRoom { fit = min(fit, rightRoom / rightExtent) }
            pose.scaleX *= fit
            pose.scaleY *= fit
            let y = anchorInCanvas.y + pose.offsetY + fit * (s*mx + c*my - height/2)
            pose.offsetY += max(0, -y) + min(0, wideFrame.height - (y + fit*height))
            return pose
        }
    }

    /// Keep the whole rectangle on screen. Shrink only dimensions larger than
    /// the available area; roll planning below requires the idle size to fit.
    public static func clampedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let w = min(frame.width, visibleFrame.width), h = min(frame.height, visibleFrame.height)
        return CGRect(x: max(visibleFrame.minX, min(frame.minX, visibleFrame.maxX - w)),
                      y: max(visibleFrame.minY, min(frame.minY, visibleFrame.maxY - h)), width: w, height: h)
    }

    /// Anchor a chat window above, below, or beside the pet in screen coordinates.
    public static func chatPanelFrame(petFrame pet: CGRect, visibleFrame area: CGRect) -> CGRect {
        guard !area.isEmpty else { return .zero }
        let size = DesignTokens.chatPanelSize
        let gap: CGFloat = 8
        let x = pet.midX - size.width / 2, y = pet.midY - size.height / 2
        let origins = [
            CGPoint(x: x, y: pet.maxY + gap), CGPoint(x: x, y: pet.minY - gap - size.height),
            CGPoint(x: pet.maxX + gap, y: y), CGPoint(x: pet.minX - gap - size.width, y: y)
        ]
        let clearance = pet.insetBy(dx: -gap, dy: -gap)
        var best = CGRect.zero
        var leastOverlap = CGFloat.infinity
        for origin in origins {
            let frame = clampedFrame(CGRect(origin: origin, size: size), to: area)
            let overlap = frame.intersection(clearance)
            if overlap.isEmpty { return frame }
            let covered = overlap.width * overlap.height
            if covered < leastOverlap {
                best = frame
                leastOverlap = covered
            }
        }
        return best
    }

    /// Include stroke, shadows and other moving paint in bodyBounds. Supply the
    /// renderer's scaled torso width separately if the paint envelope is wider.
    /// Otherwise its width serves as the rolling body width. A nil plan
    /// means the inputs cannot guarantee an unclipped roll with that mode.
    public static func wideRollFrame(startFrame: CGRect, visibleFrame: CGRect, bodyBounds: CGRect,
                                     anchor: CGPoint, preferredDirection: RollDirection = .right,
                                     reducedMotion: Bool = false, rollingBodyWidth: CGFloat? = nil) -> RollPlan? {
        let rollingRadius = MotionEngine.rollingRadius(forBodyWidth: rollingBodyWidth ?? bodyBounds.width)
        guard [startFrame, visibleFrame, bodyBounds].allSatisfy({ rect in
            rect.size.width > 0 && rect.size.height > 0 && !rect.isInfinite &&
            [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
        }), anchor.x.isFinite, anchor.y.isFinite, rollingRadius.isFinite, rollingRadius > 0,
              CGRect(origin: .zero, size: startFrame.size).contains(bodyBounds),
              startFrame.width <= visibleFrame.width, startFrame.height <= visibleFrame.height else { return nil }

        let start = clampedFrame(startFrame, to: visibleFrame)
        let left = start.minX - visibleFrame.minX, right = visibleFrame.maxX - start.maxX
        let stride: CGFloat = reducedMotion ? 60 : MotionEngine.fullRollTravel
        let preferredSpace = preferredDirection == .right ? right : left
        let otherSpace = preferredDirection == .right ? left : right
        let direction: RollDirection = preferredSpace >= stride || preferredSpace >= otherSpace
            ? preferredDirection : (preferredDirection == .right ? .left : .right)
        let travel = direction == .right ? min(stride, right) : -min(stride, left)
        let peak = start.offsetBy(dx: travel, dy: 0)
        let end = start.offsetBy(dx: 0.9 * travel, dy: 0)
        let relative = bodyBounds.offsetBy(dx: -anchor.x, dy: -anchor.y)
        var canvas = start.union(peak)
        if !reducedMotion && travel != 0 {
            // The roll never exceeds 1.12x horizontal or 1x vertical scale.
            // A circle around the pivot bounds every angle, including between samples.
            let maxWidth = MotionEngine.rollSquashX * bodyBounds.width
            let span = hypot(maxWidth, bodyBounds.height)
            guard span <= min(visibleFrame.width, visibleFrame.height) else { return nil }
            let radius = hypot(MotionEngine.rollSquashX * max(abs(relative.minX), abs(relative.maxX)),
                               max(abs(relative.minY), abs(relative.maxY)))
            let circle = CGRect(x: start.minX + anchor.x - radius, y: start.minY + anchor.y - radius,
                                width: 2 * radius, height: 2 * radius + MotionEngine.rollHopHeight)
            canvas = canvas.union(circle).union(circle.offsetBy(dx: travel, dy: 0))
        }
        let wide = clampedFrame(canvas, to: visibleFrame)
        let pivot = CGPoint(x: start.minX - wide.minX + anchor.x, y: start.minY - wide.minY + anchor.y)
        // A moving pivot must stay inside the canvas for scaling about it to keep
        // paint on screen. Normal artwork supplies its torso pivot inside the body.
        if travel != 0 {
            guard min(pivot.x, pivot.x + travel) >= 0,
                  max(pivot.x, pivot.x + travel) <= wide.width else { return nil }
        }
        return RollPlan(startFrame: start, wideFrame: wide, endFrame: end, direction: direction,
                        anchorInCanvas: pivot, rollingRadius: rollingRadius, relativeBounds: relative,
                        travel: travel, reducedMotion: reducedMotion)
    }
}
