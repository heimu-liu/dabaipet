import Foundation

/// Time is measured in seconds, distances in screen points, and rotations in degrees.
public enum MotionEngine {
    public static let rollDuration = 2.2
    public static let dragReleaseDuration = 0.35
    public static let pokeDuration = 0.60
    public static let blinkDuration = 0.16
    static let rollSquashX = 1.12
    static let rollHopHeight = 4.0
    static let fullRollTravel = 180.0
    /// The UI's standard 84 pt torso rolls one turn over its 180 pt outward stride.
    static func rollingRadius(forBodyWidth width: Double) -> Double {
        (fullRollTravel / (2 * .pi)) * (width / 84)
    }

    /// SplitMix64 allows a replay to reproduce every scheduled blink.
    public struct BlinkGenerator: RandomNumberGenerator, Sendable {
        private var state: UInt64
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    public static func nextBlinkInterval(using rng: inout some RandomNumberGenerator) -> Double {
        3.5 + 3 * Double(rng.next() >> 11) / 9_007_199_254_740_992
    }

    /// Interpolate the renderer's closed and open eye heights with this weight.
    public static func blinkOpenness(at seconds: Double) -> Double {
        let t = unit(seconds / blinkDuration)
        return (1 + cos(2 * .pi * t)) / 2
    }

    /// End value for the renderer's autoreversing CA animation.
    public static func breathPeak(reducedMotion: Bool) -> MotionPose {
        reducedMotion ? MotionPose(scaleX: 0.994, scaleY: 1.014) : MotionPose(scaleX: 0.988, scaleY: 1.028)
    }

    public static func dragging(horizontalVelocity: Double) -> MotionPose {
        let angle = max(-14, min(14, -horizontalVelocity * 0.08))
        return MotionPose(rotationDegrees: angle, scaleX: 0.96, scaleY: 1.05)
    }

    public static func dragRelease(from pose: MotionPose, at seconds: Double) -> MotionPose {
        if seconds <= 0 { return pose }
        if seconds >= dragReleaseDuration { return MotionPose() }
        let weight = spring(seconds / dragReleaseDuration)
        return MotionPose(offsetX: pose.offsetX * weight, offsetY: pose.offsetY * weight,
                          rotationDegrees: pose.rotationDegrees * weight,
                          scaleX: 1 + (pose.scaleX - 1) * weight, scaleY: 1 + (pose.scaleY - 1) * weight)
    }

    public static func poke(at seconds: Double) -> MotionPose {
        let attack = 0.09
        let weight = seconds <= attack ? ease(seconds / attack) : spring((seconds - attack) / (pokeDuration - attack))
        return MotionPose(scaleX: 1 + (1.14 - 1) * weight, scaleY: 1 + (0.88 - 1) * weight)
    }

    /// Unconstrained trajectory; RollPlan.pose also accounts for the actual paint bounds.
    static func roll(at seconds: Double, travel: Double, finalOffset: Double, radius: Double,
                     reducedMotion: Bool) -> MotionPose {
        guard travel != 0 else { return MotionPose() }
        let t = max(0, min(seconds, rollDuration))
        let forward = ease((t - 0.25) / 1.0)
        let brake = ease((t - 1.25) / 0.60)
        let x = travel * forward + (finalOffset - travel) * brake
        let load = t <= 0.25 ? ease(t / 0.25) : 1 - ease((t - 0.25) / 0.25)
        if reducedMotion {
            return MotionPose(offsetX: x, scaleY: 1 - 0.03 * load)
        }
        let rolling = unit((t - 0.25) / 1.0)
        let hop = rollHopHeight * pow(sin(.pi * rolling), 2)
        let settle = unit((t - 1.85) / 0.35)
        let degreesPerPoint = 180 / (.pi * radius)
        let landingAngle = -finalOffset * degreesPerPoint
        let upright = (landingAngle / 360).rounded() * 360
        // During braking, ease the residual angle to the nearest upright orientation.
        // A short roll unwinds to zero. The unwrapped angle stays continuous across phases.
        let rotation = brake == 1 ? upright : -x * degreesPerPoint + (upright - landingAngle) * brake
        let amplitude = min(2, abs(landingAngle) * 0.03)
        let wobble = settle == 1 ? 0 : amplitude * sin(2 * .pi * settle) * pow(sin(.pi * settle), 2)
        return MotionPose(offsetX: x, offsetY: rolling == 1 ? 0 : hop,
                          rotationDegrees: rotation + wobble, scaleX: 1 + (rollSquashX - 1) * load, scaleY: 1 - 0.14 * load)
    }

    private static func unit(_ t: Double) -> Double { min(1, max(0, t)) }

    private static func ease(_ t: Double) -> Double {
        (1 - cos(.pi * unit(t))) / 2
    }

    private static func spring(_ t: Double) -> Double {
        let p = unit(t)
        return (1 - ease(p)) * exp(-4 * p) * cos(2 * .pi * p)
    }
}
