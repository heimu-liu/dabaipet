import DabaiPetCore
import Synchronization
import Testing

private final class ReminderTestClock: Sendable {
    private let elapsed = Mutex<Duration>(.zero)

    var now: Duration { elapsed.withLock { $0 } }

    func advance(by duration: Duration) {
        elapsed.withLock { $0 += duration }
    }
}

@Suite struct HealthReminderSchedulerTests {
    private typealias Scheduler = HealthReminderScheduler

    @Test(arguments: [(.minutes30, 30), (.minutes45, 45), (.minutes60, 60)] as [(HealthReminderScheduler.Interval, Int)])
    func firesAtTheConfiguredBoundaryAndRearmsFromDelivery(_ interval: HealthReminderScheduler.Interval, _ minutes: Int) {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })
        let period = Duration.seconds(minutes * 60)

        #expect(interval.rawValue == minutes)
        #expect(scheduler.update(interval: interval, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == period)
        clock.advance(by: period - .nanoseconds(1))
        #expect(scheduler.update(interval: interval, context: .init()) == .waiting)
        clock.advance(by: .nanoseconds(1))
        #expect(scheduler.update(interval: interval, context: .init()) == .due)
        #expect(scheduler.nextDeadline == period + period)
        #expect(scheduler.update(interval: interval, context: .init()) == .waiting)
    }

    @Test func changingIntervalsReplacesTheDeadlineAndRepeatingTheSettingKeepsIt() {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })

        #expect(scheduler.update(interval: .minutes30, context: .init()) == .waiting)
        clock.advance(by: .seconds(20 * 60))
        #expect(scheduler.update(interval: .minutes45, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == .seconds(65 * 60))
        clock.advance(by: .seconds(10 * 60))
        #expect(scheduler.update(interval: .minutes45, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == .seconds(65 * 60))
        clock.advance(by: .seconds(35 * 60))
        #expect(scheduler.update(interval: .minutes45, context: .init()) == .due)
    }

    @Test func warmingUpWhileLockedOrSleepingRequiresAllReasonsToClear() {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })

        #expect(scheduler.update(interval: .minutes30, context: .init(isSleeping: true, isScreenLocked: true)) == .waiting)
        clock.advance(by: .seconds(2 * 60 * 60))
        #expect(scheduler.update(interval: .minutes30, context: .init(isScreenLocked: true)) == .waiting)
        #expect(scheduler.nextDeadline == nil)
        #expect(scheduler.update(interval: .minutes45, context: .init(isSleeping: true)) == .waiting)
        #expect(scheduler.nextDeadline == nil)
        #expect(scheduler.update(interval: .minutes45, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == clock.now + .seconds(45 * 60))
        clock.advance(by: .seconds(45 * 60))
        #expect(scheduler.update(interval: .minutes45, context: .init()) == .due)
    }

    @Test func treatsFiveMinutesOfIdleTimeAsABreakAndShortInactivityAsContinuousUse() {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })
        #expect(Scheduler.userIdleThreshold == .seconds(5 * 60))

        #expect(scheduler.update(interval: .minutes30, context: .init()) == .waiting)
        clock.advance(by: .seconds(29 * 60))
        #expect(scheduler.update(interval: .minutes30, context: .init(userIdleDuration: .seconds(299))) == .waiting)
        #expect(scheduler.nextDeadline == .seconds(30 * 60))
        clock.advance(by: .seconds(60))
        #expect(scheduler.update(interval: .minutes30, context: .init(userIdleDuration: .seconds(300))) == .waiting)
        #expect(scheduler.nextDeadline == nil)
        clock.advance(by: .seconds(3 * 60 * 60))
        #expect(scheduler.update(interval: .minutes30, context: .init(userIdleDuration: .seconds(3 * 60 * 60))) == .waiting)
        #expect(scheduler.nextDeadline == nil)
        #expect(scheduler.update(interval: .minutes30, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == clock.now + .seconds(30 * 60))
    }

    @Test(arguments: [
        .sleeping, .locked, .away,
    ] as [HealthReminderSchedulerTests.Interruption])
    func aBreakClearsAnyPendingReminderAndRestartsAfterItEnds(_ interruption: Interruption) {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })
        let busy = Scheduler.Context(petState: .thinking)
        #expect(scheduler.update(interval: .minutes30, context: busy) == .waiting)
        clock.advance(by: .seconds(30 * 60))
        #expect(scheduler.update(interval: .minutes30, context: busy) == .deferred)
        #expect(scheduler.update(interval: .minutes30, context: interruption.context) == .waiting)
        #expect(scheduler.nextDeadline == nil)

        clock.advance(by: .seconds(31 * 60))
        #expect(scheduler.update(interval: .minutes30, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == clock.now + .seconds(30 * 60))
    }

    enum Interruption: Sendable {
        case sleeping, locked, away

        var context: HealthReminderScheduler.Context {
            switch self {
            case .sleeping: .init(isSleeping: true)
            case .locked: .init(isScreenLocked: true)
            case .away: .init(userIdleDuration: .seconds(5 * 60))
            }
        }
    }

    @Test(arguments: [.listening, .thinking, .speaking(emotion: .care), .playingRPS(phase: .preparing),
                      .poked, .dragging, .rolling(direction: .left)] as [PetState])
    func defersOneReminderDuringActivityAndDeliversItOnFirstIdleUpdate(_ state: PetState) {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })
        let context = Scheduler.Context(petState: state)
        #expect(scheduler.update(interval: .minutes30, context: context) == .waiting)
        clock.advance(by: .seconds(30 * 60))
        #expect(scheduler.update(interval: .minutes30, context: context) == .deferred)
        #expect(scheduler.nextDeadline == nil)

        clock.advance(by: .seconds(4 * 60 * 60))
        #expect(scheduler.update(interval: .minutes30, context: context) == .deferred)
        #expect(scheduler.update(interval: .minutes30, context: .init()) == .due)
        #expect(scheduler.update(interval: .minutes30, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == clock.now + .seconds(30 * 60))
    }

    @Test func changingOrDisablingTheSettingDropsADeferredReminder() {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })
        let busy = Scheduler.Context(petState: .speaking(emotion: .care))
        #expect(Scheduler.Interval.off.rawValue == 0)
        #expect(scheduler.update(interval: .off, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == nil)
        #expect(scheduler.update(interval: .minutes30, context: busy) == .waiting)
        clock.advance(by: .seconds(30 * 60))
        #expect(scheduler.update(interval: .minutes30, context: busy) == .deferred)
        #expect(scheduler.update(interval: .minutes60, context: busy) == .waiting)
        #expect(scheduler.nextDeadline == clock.now + .seconds(60 * 60))
        clock.advance(by: .seconds(60 * 60))
        #expect(scheduler.update(interval: .minutes60, context: busy) == .deferred)

        #expect(scheduler.update(interval: .off, context: busy) == .waiting)
        #expect(scheduler.nextDeadline == nil)
        scheduler.deferReminder(in: busy)
        clock.advance(by: .seconds(2 * 60 * 60))
        #expect(scheduler.update(interval: .off, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == nil)
        #expect(scheduler.update(interval: .minutes30, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == clock.now + .seconds(30 * 60))
    }

    @Test func skipsASecondReminderWhileTheExistingReminderIsVisible() {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })
        #expect(scheduler.update(interval: .minutes30, context: .init()) == .waiting)
        clock.advance(by: .seconds(30 * 60))
        #expect(scheduler.update(interval: .minutes30, context: .init()) == .due)
        clock.advance(by: .seconds(30 * 60))
        #expect(scheduler.update(interval: .minutes30, context: .init(petState: .healthReminder)) == .waiting)
        #expect(scheduler.update(interval: .minutes30, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == clock.now + .seconds(30 * 60))
    }

    @Test func anOverdueCheckProducesOneReminderWithoutCatchUp() {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })
        #expect(scheduler.update(interval: .minutes60, context: .init()) == .waiting)
        clock.advance(by: .seconds(6 * 60 * 60))
        #expect(scheduler.update(interval: .minutes60, context: .init()) == .due)
        #expect(scheduler.update(interval: .minutes60, context: .init()) == .waiting)
        #expect(scheduler.nextDeadline == clock.now + .seconds(60 * 60))
    }

    @Test func requeuesTheStateMachineEffectOnceIfAPetActivityWinsTheRace() {
        let clock = ReminderTestClock()
        var scheduler = Scheduler(now: { clock.now })
        var machine = PetStateMachine()
        #expect(scheduler.update(interval: .minutes30, context: .init(petState: machine.state)) == .waiting)
        clock.advance(by: .seconds(30 * 60))
        #expect(scheduler.update(interval: .minutes30, context: .init(petState: machine.state)) == .due)

        _ = machine.handle(.llmRequestStarted)
        #expect(machine.handle(.healthReminderDue) == [.enqueueDeferredHealthReminder])
        let busy = Scheduler.Context(petState: machine.state)
        scheduler.deferReminder(in: busy)
        scheduler.deferReminder(in: busy)
        #expect(scheduler.update(interval: .minutes30, context: busy) == .deferred)
        #expect(scheduler.nextDeadline == nil)

        _ = machine.handle(.llmFailed)
        #expect(scheduler.update(interval: .minutes30, context: .init(petState: machine.state)) == .due)
        #expect(machine.handle(.healthReminderDue) == [.showTransientBubble(text: "休息一下")])
        #expect(scheduler.update(interval: .minutes30, context: .init(petState: machine.state)) == .waiting)
    }
}
