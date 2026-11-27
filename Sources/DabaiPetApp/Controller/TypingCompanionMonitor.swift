import CoreGraphics
import Foundation

@MainActor
final class TypingCompanionMonitor {
    private let readCount: () -> UInt32
    private var timer: Timer?

    init(readCount: @escaping () -> UInt32 = {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    }) {
        self.readCount = readCount
    }

    func start(onBeat: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        var previous = readCount()
        let interval: TimeInterval = 1
        let timer = Timer(fire: Date(timeIntervalSinceNow: interval), interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                let current = self.readCount()
                let advanced = current > previous
                previous = current  // A reset or wrap starts a new baseline.
                if advanced { onBeat() }
            }
        }
        timer.tolerance = 0.15
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    isolated deinit { stop() }
}
