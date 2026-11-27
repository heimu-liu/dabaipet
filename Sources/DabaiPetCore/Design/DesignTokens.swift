import CoreGraphics
import Foundation

/// Normalized sRGB color in 0...1 channel range. Pure Core data with zero GUI framework imports.
public struct RGBA: Equatable, Hashable, Codable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = Self.clampUnit(r, fallback: 0)
        self.g = Self.clampUnit(g, fallback: 0)
        self.b = Self.clampUnit(b, fallback: 0)
        self.a = Self.clampUnit(a, fallback: 1)
    }

    public init(hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(r: red, g: green, b: blue, a: alpha)
    }

    public init(r255: Double, g255: Double, b255: Double, a: Double = 1.0) {
        self.init(r: r255 / 255.0, g: g255 / 255.0, b: b255 / 255.0, a: a)
    }

    /// Standard Porter-Duff source-over composition over an opaque or translucent background.
    public func composited(over background: RGBA) -> RGBA {
        let outAlpha = a + background.a * (1 - a)
        guard outAlpha > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        let outR = (r * a + background.r * background.a * (1 - a)) / outAlpha
        let outG = (g * a + background.g * background.a * (1 - a)) / outAlpha
        let outB = (b * a + background.b * background.a * (1 - a)) / outAlpha
        return RGBA(r: outR, g: outG, b: outB, a: outAlpha)
    }

    /// WCAG 2.1 relative luminance for linearized sRGB channels.
    public var relativeLuminance: Double {
        0.2126 * Self.linearize(r) + 0.7152 * Self.linearize(g) + 0.0722 * Self.linearize(b)
    }

    /// WCAG 2.1 contrast ratio against another opaque color (1.0 to 21.0).
    public func contrastRatio(against other: RGBA) -> Double {
        let l1 = max(relativeLuminance, other.relativeLuminance)
        let l2 = min(relativeLuminance, other.relativeLuminance)
        return (l1 + 0.05) / (l2 + 0.05)
    }

    private static func clampUnit(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(1, max(0, value))
    }

    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

public enum DesktopAppearance: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case light
    case dark
}

public struct BaymaxPalette: Equatable, Codable, Sendable {
    public let bodyTop: RGBA
    public let bodyBottom: RGBA
    public let stroke: RGBA
    public let eye: RGBA
    public let chestPort: RGBA
    public let blush: RGBA
    public let groundShadow: RGBA
    public let accentHeal: RGBA
    public let dizzyStar: RGBA
    public let careGlow: RGBA

    public init(
        bodyTop: RGBA,
        bodyBottom: RGBA,
        stroke: RGBA,
        eye: RGBA,
        chestPort: RGBA,
        blush: RGBA,
        groundShadow: RGBA,
        accentHeal: RGBA,
        dizzyStar: RGBA,
        careGlow: RGBA
    ) {
        self.bodyTop = bodyTop
        self.bodyBottom = bodyBottom
        self.stroke = stroke
        self.eye = eye
        self.chestPort = chestPort
        self.blush = blush
        self.groundShadow = groundShadow
        self.accentHeal = accentHeal
        self.dizzyStar = dizzyStar
        self.careGlow = careGlow
    }
}

/// Normalized radial gradient in y-up torso bounds (0...1 on each axis).
public struct RadialGradientSpec: Equatable, Codable, Sendable {
    public let startColor: RGBA
    public let endColor: RGBA
    public let startCenterNormalized: CGPoint
    public let endCenterNormalized: CGPoint
    public let startRadiusFraction: Double
    public let endRadiusFraction: Double

    public init(
        startColor: RGBA,
        endColor: RGBA,
        startCenterNormalized: CGPoint,
        endCenterNormalized: CGPoint,
        startRadiusFraction: Double,
        endRadiusFraction: Double
    ) {
        self.startColor = startColor
        self.endColor = endColor
        self.startCenterNormalized = startCenterNormalized
        self.endCenterNormalized = endCenterNormalized
        self.startRadiusFraction = startRadiusFraction
        self.endRadiusFraction = endRadiusFraction
    }
}

public struct StrokeStyleTokens: Equatable, Codable, Sendable {
    public let bodyStrokeWidthAt1x: CGFloat
    public let eyeBridgeWidthAt1x: CGFloat
    public let chestPortStrokeWidthAt1x: CGFloat
    public let minimumHairlineWidth: CGFloat

    public init(
        bodyStrokeWidthAt1x: CGFloat = 1.2,
        eyeBridgeWidthAt1x: CGFloat = 1.5,
        chestPortStrokeWidthAt1x: CGFloat = 1.1,
        minimumHairlineWidth: CGFloat = 0.95
    ) {
        self.bodyStrokeWidthAt1x = bodyStrokeWidthAt1x
        self.eyeBridgeWidthAt1x = eyeBridgeWidthAt1x
        self.chestPortStrokeWidthAt1x = chestPortStrokeWidthAt1x
        self.minimumHairlineWidth = minimumHairlineWidth
    }

    public func scaledWidth(_ baseAt1x: CGFloat, scale: CGFloat) -> CGFloat {
        guard baseAt1x.isFinite, scale.isFinite, scale > 0 else { return minimumHairlineWidth }
        return max(minimumHairlineWidth, baseAt1x * scale)
    }
}

/// Visual motion constants shared across CALayer idle breathing and active frame-driven poses.
public struct MotionTokens: Equatable, Sendable {
    public let breathPeriod: Double = 3.6
    public let breathScaleY: Double = 1.028
    public let breathScaleX: Double = 0.988
    public let breathReducedScaleY: Double = 1.014
    public let breathReducedScaleX: Double = 0.994

    public let blinkMinInterval: Double = 3.5
    public let blinkMaxInterval: Double = 6.5
    public let blinkDuration: Double = 0.16

    public let dragScaleX: Double = 0.96
    public let dragScaleY: Double = 1.05
    public let dragTiltVelocityFactor: Double = 0.08
    public let dragMaxTiltDegrees: Double = 14.0
    public let dragReleaseDuration: Double = 0.35
    public let dragShadowScale: Double = 0.78
    public let dragShadowOpacityMultiplier: Double = 0.55

    public let rollDuration: Double = 2.2
    public let rollPrepEnd: Double = 0.25
    public let rollOutEnd: Double = 1.25
    public let rollBrakeEnd: Double = 1.85
    public let rollSquashX: Double = 1.12
    public let rollSquashY: Double = 0.86
    public let rollTravelAt1x: Double = 180.0
    public let dizzyStart: Double = 1.85
    public let dizzyStarCount: Int = 2

    public let pokeDuration: Double = 0.60
    public let pokeScaleX: Double = 1.14
    public let pokeScaleY: Double = 0.88
    public let pokeBubbleDuration: Double = 2.2
    public let pokeMaxDistancePt: CGFloat = 3.0
    public let pokeMaxDurationSec: Double = 0.25

    public let thinkingHeadSwayDegrees: Double = 4.0
    public let thinkingDotCount: Int = 3

    public let hitHysteresisOutwardPt: CGFloat = 2.0
    public let safeCanvasMarginAt1x: CGFloat = 8.0

    public init() {}
}

public enum DesignTokens {
    public static let lightPalette = BaymaxPalette(
        bodyTop: RGBA(hex: 0xFFFFFF),
        bodyBottom: RGBA(hex: 0xE6ECF2),
        stroke: RGBA(r255: 30, g255: 41, b255: 59, a: 0.16),
        eye: RGBA(hex: 0x1E242B),
        chestPort: RGBA(r255: 148, g255: 163, b255: 184, a: 0.28),
        blush: RGBA(r255: 255, g255: 138, b255: 155, a: 0.44),
        groundShadow: RGBA(r255: 15, g255: 23, b255: 42, a: 0.15),
        accentHeal: RGBA(hex: 0x38BDF8),
        dizzyStar: RGBA(hex: 0xFBBF24, alpha: 0.86),
        careGlow: RGBA(hex: 0x38BDF8, alpha: 0.28)
    )

    public static let darkPalette = BaymaxPalette(
        bodyTop: RGBA(hex: 0xF8FAFC),
        bodyBottom: RGBA(hex: 0xD8E0EB),
        stroke: RGBA(r255: 255, g255: 255, b255: 255, a: 0.22),
        eye: RGBA(hex: 0x1E242B),
        chestPort: RGBA(r255: 148, g255: 163, b255: 184, a: 0.34),
        blush: RGBA(r255: 255, g255: 138, b255: 155, a: 0.50),
        groundShadow: RGBA(r255: 0, g255: 0, b255: 0, a: 0.32),
        accentHeal: RGBA(hex: 0x7DD3FC),
        dizzyStar: RGBA(hex: 0xFDE047, alpha: 0.92),
        careGlow: RGBA(hex: 0x7DD3FC, alpha: 0.34)
    )

    public static let strokes = StrokeStyleTokens()
    public static let motion = MotionTokens()

    public static let chatPanelCornerRadius: CGFloat = 16.0
    public static let chatPanelSize = CGSize(width: 290, height: 270)

    public static func palette(for appearance: DesktopAppearance) -> BaymaxPalette {
        switch appearance {
        case .light: lightPalette
        case .dark: darkPalette
        }
    }

    public static func bodyGradient(for appearance: DesktopAppearance) -> RadialGradientSpec {
        let colors = palette(for: appearance)
        return RadialGradientSpec(
            startColor: colors.bodyTop,
            endColor: colors.bodyBottom,
            startCenterNormalized: CGPoint(x: 0.36, y: 0.72),
            endCenterNormalized: CGPoint(x: 0.52, y: 0.45),
            startRadiusFraction: 0.05,
            endRadiusFraction: 0.78
        )
    }
}
