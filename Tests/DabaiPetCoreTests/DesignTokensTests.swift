import CoreGraphics
import DabaiPetCore
import Foundation
import Testing

@Suite("DesignTokens")
struct DesignTokensTests {
    private static let tolerance = 1e-6

    @Test func palettesMatchUIUXSpecExactValues() {
        let light = DesignTokens.palette(for: .light)
        let dark = DesignTokens.palette(for: .dark)

        // Body gradient endpoints
        #expect(light.bodyTop == RGBA(hex: 0xFFFFFF))
        #expect(light.bodyBottom == RGBA(hex: 0xE6ECF2))
        #expect(dark.bodyTop == RGBA(hex: 0xF8FAFC))
        #expect(dark.bodyBottom == RGBA(hex: 0xD8E0EB))

        // Stroke prevents disappearing on white or dark desktops
        #expect(light.stroke == RGBA(r255: 30, g255: 41, b255: 59, a: 0.16))
        #expect(dark.stroke == RGBA(r255: 255, g255: 255, b255: 255, a: 0.22))

        // Iconic eyes
        #expect(light.eye == RGBA(hex: 0x1E242B))
        #expect(dark.eye == RGBA(hex: 0x1E242B))

        // Chest port, blush, shadow, heal accent
        #expect(light.chestPort == RGBA(r255: 148, g255: 163, b255: 184, a: 0.28))
        #expect(dark.chestPort == RGBA(r255: 148, g255: 163, b255: 184, a: 0.34))
        #expect(light.blush == RGBA(r255: 255, g255: 138, b255: 155, a: 0.44))
        #expect(dark.blush == RGBA(r255: 255, g255: 138, b255: 155, a: 0.50))
        #expect(light.groundShadow == RGBA(r255: 15, g255: 23, b255: 42, a: 0.15))
        #expect(dark.groundShadow == RGBA(r255: 0, g255: 0, b255: 0, a: 0.32))
        #expect(light.accentHeal == RGBA(hex: 0x38BDF8))
        #expect(dark.accentHeal == RGBA(hex: 0x7DD3FC))

        // Dizzy stars and care glow must be visible (non-zero alpha)
        #expect(light.dizzyStar.a > 0.5 && dark.dizzyStar.a > 0.5)
        #expect(light.careGlow.a > 0.1 && dark.careGlow.a > 0.1)
    }

    @Test func allColorChannelsAreNormalizedAndFinite() {
        for appearance in DesktopAppearance.allCases {
            let p = DesignTokens.palette(for: appearance)
            let colors = [
                p.bodyTop, p.bodyBottom, p.stroke, p.eye, p.chestPort,
                p.blush, p.groundShadow, p.accentHeal, p.dizzyStar, p.careGlow,
            ]
            for c in colors {
                for ch in [c.r, c.g, c.b, c.a] {
                    #expect(ch.isFinite && ch >= 0 && ch <= 1)
                }
            }
        }
    }

    @Test func outlineAndEyesMaintainVisibilityOnPureWhiteAndPureBlack() {
        let pureWhite = RGBA(hex: 0xFFFFFF)
        let pureBlack = RGBA(hex: 0x000000)

        let light = DesignTokens.palette(for: .light)
        let dark = DesignTokens.palette(for: .dark)

        // Stroke composited over pure white must visibly separate from white
        let lightStrokeOnWhite = light.stroke.composited(over: pureWhite)
        #expect(lightStrokeOnWhite.contrastRatio(against: pureWhite) >= 1.30)

        // Body silhouette over pure black has high contrast
        #expect(dark.bodyBottom.contrastRatio(against: pureBlack) >= 12.0)

        // Eyes over body top must have very strong contrast (>= 10:1)
        #expect(light.eye.contrastRatio(against: light.bodyTop) >= 10.0)
        #expect(dark.eye.contrastRatio(against: dark.bodyTop) >= 10.0)
    }

    @Test func bodyRadialGradientHasMarshmallowUpperLeftHighlight() {
        for appearance in DesktopAppearance.allCases {
            let gradient = DesignTokens.bodyGradient(for: appearance)
            let palette = DesignTokens.palette(for: appearance)
            #expect(gradient.startColor == palette.bodyTop)
            #expect(gradient.endColor == palette.bodyBottom)
            // Positive y is upwards: upper-left highlight has x < 0.5 and y > 0.5
            #expect(gradient.startCenterNormalized.x < 0.5)
            #expect(gradient.startCenterNormalized.y > 0.5)
            #expect(gradient.endRadiusFraction > gradient.startRadiusFraction)
            #expect(gradient.endRadiusFraction <= 1.0)
        }
    }

    @Test func strokeAndMotionTokensMatchSpecBaselines() {
        #expect(abs(DesignTokens.strokes.bodyStrokeWidthAt1x - 1.2) < Self.tolerance)
        #expect(abs(DesignTokens.strokes.eyeBridgeWidthAt1x - 1.5) < Self.tolerance)
        #expect(DesignTokens.strokes.scaledWidth(DesignTokens.strokes.bodyStrokeWidthAt1x, scale: 0.8) >= 0.9)
        #expect(DesignTokens.strokes.scaledWidth(DesignTokens.strokes.bodyStrokeWidthAt1x, scale: 1.25) > 1.2)

        let m = DesignTokens.motion
        #expect(abs(m.breathPeriod - 3.6) < Self.tolerance)
        #expect(abs(m.breathScaleY - 1.028) < Self.tolerance)
        #expect(abs(m.breathScaleX - 0.988) < Self.tolerance)
        #expect(abs(m.blinkMinInterval - 3.5) < Self.tolerance)
        #expect(abs(m.blinkMaxInterval - 6.5) < Self.tolerance)
        #expect(abs(m.blinkDuration - 0.16) < Self.tolerance)
        #expect(abs(m.rollDuration - 2.2) < Self.tolerance)
        #expect(abs(m.pokeMaxDistancePt - 3.0) < Self.tolerance)
        #expect(abs(m.pokeMaxDurationSec - 0.25) < Self.tolerance)
        #expect(abs(m.hitHysteresisOutwardPt - 2.0) < Self.tolerance)
        #expect(abs(m.safeCanvasMarginAt1x - 8.0) < Self.tolerance)
    }

    @Test func rgbaCodableRoundTripPreservesComponents() throws {
        let sample = RGBA(r255: 56, g255: 189, b255: 248, a: 0.75)
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(RGBA.self, from: data)
        #expect(decoded == sample)
    }
}
