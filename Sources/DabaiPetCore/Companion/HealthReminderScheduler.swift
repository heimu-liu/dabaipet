/// Schedules at most one reminder using caller-provided monotonic time and live context.
public struct HealthReminderScheduler: Sendable {
    public enum Interval: Int, CaseIterable, Sendable {
        case off = 0
        case minutes30 = 30
        case minutes45 = 45
        case minutes60 = 60
    }

    public struct Context: Sendable {
        public var isSleeping: Bool
        public var isScreenLocked: Bool
        public var userIdleDuration: Duration
        public var petState: PetState

        public init(isSleeping: Bool = false, isScreenLocked: Bool = false,
                    userIdleDuration: Duration = .zero, petState: PetState = .idle) {
            self.isSleeping = isSleeping
            self.isScreenLocked = isScreenLocked
            self.userIdleDuration = userIdleDuration
            self.petState = petState
        }
    }

    public enum Decision: Equatable, Sendable {
        case waiting
        /// One reminder is waiting for the pet to become idle.
        case deferred
        /// Deliver `.healthReminderDue` to the pet state machine.
        case due
    }

    /// Inactivity at or above this duration starts a fresh work interval on return.
    public static let userIdleThreshold: Duration = .seconds(5 * 60)

    private enum Schedule: Sendable {
        case inactive
        case armed(deadline: Duration)
        case deferred
    }

    private let now: @Sendable () -> Duration
    private var interval: Interval = .off
    private var schedule: Schedule = .inactive

    /// The armed deadline in the same time base as `now`, if one exists.
    public var nextDeadline: Duration? {
        if case .armed(let deadline) = schedule { return deadline }
        return nil
    }

    /// `now` returns elapsed time measured from a fixed monotonic origin.
    public init(now: @escaping @Sendable () -> Duration) {
        self.now = now
    }

    /// Call on deadline and when preferences, activity or device context change.
    public mutating func update(interval: Interval, context: Context) -> Decision {
        if self.interval != interval {
            self.interval = interval
            schedule = .inactive
        }
        guard canSchedule(in: context) else {
            schedule = .inactive
            return .waiting
        }

        let instant = now()
        let nextInterval = Schedule.armed(deadline: instant + .seconds(interval.rawValue * 60))
        switch schedule {
        case .inactive:
            schedule = nextInterval
            return .waiting
        case .armed(let deadline) where instant < deadline:
            return .waiting
        case .armed, .deferred:
            break
        }

        switch context.petState {
        case .idle:
            schedule = nextInterval
            return .due
        case .healthReminder:
            // A reminder is already on display. Begin another interval.
            schedule = nextInterval
            return .waiting
        default:
            schedule = .deferred
            return .deferred
        }
    }

    /// Requeues one reminder for the state machine's `.enqueueDeferredHealthReminder` effect.
    public mutating func deferReminder(in context: Context) {
        guard canSchedule(in: context) else {
            schedule = .inactive
            return
        }
        if context.petState != .healthReminder { schedule = .deferred }
    }

    private func canSchedule(in context: Context) -> Bool {
        interval != .off && !context.isSleeping && !context.isScreenLocked
            && context.userIdleDuration < Self.userIdleThreshold
    }
}
