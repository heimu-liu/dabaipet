import AppKit

// All shape coordinates are relative to the point about which the body rolls.
enum ProbeShape {
    static let idleSize = CGSize(width: 152, height: 152)
    static let ellipses = [
        CGRect(x: -26, y: -56, width: 24, height: 20),
        CGRect(x: 2, y: -56, width: 24, height: 20),
        CGRect(x: -46, y: -32, width: 19, height: 57),
        CGRect(x: 27, y: -32, width: 19, height: 57),
        CGRect(x: -35, y: -44, width: 70, height: 77),
        CGRect(x: -23, y: 25, width: 46, height: 32),
    ]

    static func contains(_ point: CGPoint, margin: CGFloat) -> Bool {
        ellipses.contains { rect in
            let e = rect.insetBy(dx: -margin, dy: -margin)
            return pow((point.x - e.midX) / (e.width / 2), 2)
                 + pow((point.y - e.midY) / (e.height / 2), 2) <= 1
        }
    }

    // Exact axis-aligned bounds of the rotated ellipses, plus their stroke.
    static func bounds(center: CGPoint, radians: CGFloat) -> CGRect {
        let c = cos(radians), s = sin(radians)
        return ellipses.reduce(CGRect.null) { union, e in
            let x = center.x + c * e.midX - s * e.midY
            let y = center.y + s * e.midX + c * e.midY
            let rx = hypot(c * e.width, s * e.height) / 2 + 1
            let ry = hypot(s * e.width, c * e.height) / 2 + 1
            return union.union(CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
        }
    }
}

func probeClamp(_ rect: CGRect, to visible: CGRect) -> CGRect {
    let x = max(visible.minX, min(rect.minX, visible.maxX - rect.width))
    let y = max(visible.minY, min(rect.minY, visible.maxY - rect.height))
    return CGRect(origin: CGPoint(x: x, y: y), size: rect.size)
}

func probeRect(_ r: CGRect) -> [String: CGFloat] {
    ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
}

struct ProbeRoll {
    static let duration = 2.2
    let visible: CGRect
    let start: CGRect
    let wide: CGRect
    let end: CGRect
    let travel: CGFloat
    let reducedMotion: Bool

    init(at rect: CGRect, visible: CGRect, reducedMotion: Bool) {
        self.visible = visible
        self.reducedMotion = reducedMotion
        start = probeClamp(rect, to: visible)
        let right = visible.maxX - start.maxX
        let left = start.minX - visible.minX
        let distance: CGFloat = reducedMotion ? 60 : 180
        travel = right >= distance || right >= left ? min(distance, right) : -min(distance, left)
        wide = start.union(start.offsetBy(dx: travel, dy: 0))
        end = start.offsetBy(dx: (0.9 * travel).rounded(), dy: 0)
    }

    func pose(_ progress: Double) -> (center: CGPoint, angle: Double) {
        func ease(_ value: Double) -> Double { (1 - cos(.pi * value)) / 2 }
        let offset = progress < 0.65
            ? travel * ease(progress / 0.65)
            : travel + (end.minX - start.minX - travel) * ease((progress - 0.65) / 0.35)
        let finalOffset = end.minX - start.minX
        let angle = reducedMotion || finalOffset == 0 ? 0 : -2 * .pi * offset / abs(finalOffset)
        return (CGPoint(x: start.midX + offset, y: start.midY), angle)
    }

    func geometryPasses() -> Bool {
        visible.contains(wide) && wide.contains(start) && wide.contains(end) && (0...264).allSatisfy {
            let p = pose(Double($0) / 264)
            return wide.contains(ProbeShape.bounds(center: p.center, radians: p.angle))
        }
    }
}
