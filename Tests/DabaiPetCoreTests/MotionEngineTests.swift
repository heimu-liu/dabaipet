import DabaiPetCore
import Foundation
import Testing

struct MotionEngineTests {
    @Test func repeatableBlinkTimingAndClosure() {
        var a = MotionEngine.BlinkGenerator(seed: 17)
        var b = MotionEngine.BlinkGenerator(seed: 17)
        var c = MotionEngine.BlinkGenerator(seed: 18)
        let first = (0..<64).map { _ in MotionEngine.nextBlinkInterval(using: &a) }
        #expect(first == (0..<64).map { _ in MotionEngine.nextBlinkInterval(using: &b) })
        #expect(first != (0..<64).map { _ in MotionEngine.nextBlinkInterval(using: &c) })
        #expect(first.allSatisfy { (3.5...6.5).contains($0) })
        #expect(MotionEngine.blinkOpenness(at: 0) == 1)
        #expect(MotionEngine.blinkOpenness(at: 0.08) == 0)
        #expect(MotionEngine.blinkOpenness(at: 0.16) == 1)
    }

    @Test func dragAndRelease() {
        #expect(MotionEngine.dragging(horizontalVelocity: 1000).rotationDegrees == -14)
        #expect(MotionEngine.dragging(horizontalVelocity: -1000).rotationDegrees == 14)
        let pose = MotionEngine.dragging(horizontalVelocity: 100)
        #expect(pose == MotionPose(rotationDegrees: -8, scaleX: 0.96, scaleY: 1.05))
        #expect(MotionEngine.dragRelease(from: pose, at: 0) == pose)
        #expect(MotionEngine.dragRelease(from: pose, at: 0.175).rotationDegrees > 0)
        #expect(MotionEngine.dragRelease(from: pose, at: 0.35) == MotionPose())
        #expect(MotionEngine.dragRelease(from: pose, at: 1) == MotionPose())
    }

    @Test func pokeAndBreathingExtrema() {
        #expect(MotionEngine.poke(at: 0) == MotionPose())
        #expect(MotionEngine.poke(at: 0.09) == MotionPose(scaleX: 1.14, scaleY: 0.88))
        #expect(MotionEngine.poke(at: 0.30).scaleX < 1)
        #expect(MotionEngine.poke(at: MotionEngine.pokeDuration) == MotionPose())
        #expect(MotionEngine.breathPeak(reducedMotion: false) == MotionPose(scaleX: 0.988, scaleY: 1.028))
        #expect(MotionEngine.breathPeak(reducedMotion: true) == MotionPose(scaleX: 0.994, scaleY: 1.014))
    }
}
