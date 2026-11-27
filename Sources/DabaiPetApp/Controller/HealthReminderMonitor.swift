import CoreGraphics
import DabaiPetCore
import Foundation

/// Wakes the scheduler at its deadline or when the session can first become idle.
@MainActor
final class HealthReminderMonitor {
    private let now: @Sendable () -> Duration
    private let idleDuration: () -> Duration
    private var scheduler: HealthReminderScheduler
    private var timer: Timer?
    private var context = HealthReminderScheduler.Context()

    init(now: @escaping @Sendable () -> Duration = { .seconds(ProcessInfo.processInfo.systemUptime) },
         idleDuration: @escaping () -> Duration = {
             // kCGAnyInputEventType reports elapsed time only.
             let anyInput = CGEventType(rawValue: UInt32.max)!
             let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
             return seconds.isFinite ? .seconds(min(max(0, seconds), 86400)) : .seconds(86400)
         }) {
        self.now = now
        self.idleDuration = idleDuration
        scheduler = HealthReminderScheduler(now: now)
    }

    func update(minutes: Int, state: PetState, pause: PetAnimationSystemState.PauseReasons,
                wake: @escaping @MainActor () -> Void) -> HealthReminderScheduler.Decision {
        timer?.invalidate()
        timer = nil
        let interval = HealthReminderScheduler.Interval(rawValue: minutes) ?? .off
        context = .init(isSleeping: pause.contains(.systemSleeping), isScreenLocked: pause.contains(.screenLocked),
                        petState: state)
        let watching = interval != .off && !context.isSleeping && !context.isScreenLocked
        if watching { context.userIdleDuration = idleDuration() }
        let decision = scheduler.update(interval: interval, context: context)
        guard watching else { return decision }

        let untilIdle = HealthReminderScheduler.userIdleThreshold - context.userIdleDuration
        // While away, sample only for return. While present, jump directly to the next boundary.
        var delay: Duration = untilIdle > .zero ? untilIdle : .seconds(1)
        if let deadline = scheduler.nextDeadline { delay = min(delay, deadline - now()) }
        let seconds = max(0.02, delay / Duration.seconds(1))
        let timer = Timer(fire: Date(timeIntervalSinceNow: seconds), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { wake() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return decision
    }

    func deferReminder() { scheduler.deferReminder(in: context) }

    func stop() {
        timer?.invalidate()
        timer = nil
        _ = scheduler.update(interval: .off, context: context)
    }

    isolated deinit { timer?.invalidate() }
}
