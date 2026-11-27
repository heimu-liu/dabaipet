import AppKit
import CoreGraphics

struct PetAnimationSystemState: Equatable, Sendable {
    struct PauseReasons: OptionSet, Sendable {
        let rawValue: UInt8

        static let occluded = Self(rawValue: 1 << 0)
        static let systemSleeping = Self(rawValue: 1 << 1)
        static let screenLocked = Self(rawValue: 1 << 2)
        static let lowPowerMode = Self(rawValue: 1 << 3)
    }

    var reduceMotion = false
    var pauseReasons: PauseReasons = []
    var shouldPauseAnimations: Bool { !pauseReasons.isEmpty }
}

@MainActor
final class PetAnimationSystemMonitor: NSObject {
    @MainActor
    struct Sources {
        var localNotifications = NotificationCenter.default
        var workspaceNotifications = NSWorkspace.shared.notificationCenter
        var lockNotifications: NotificationCenter = DistributedNotificationCenter.default()
        var readReduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        var readLowPowerMode: @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        var readScreenLocked: @MainActor () -> Bool = {
            // The session flag and lock notification names are macOS conventions.
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        }
    }

    private static let screenDidLock = Notification.Name("com.apple.screenIsLocked")
    private static let screenDidUnlock = Notification.Name("com.apple.screenIsUnlocked")

    private weak var window: NSWindow?
    private let sources: Sources
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var onChange: (@MainActor (PetAnimationSystemState) -> Void)?
    private(set) var state = PetAnimationSystemState()

    init(window: NSWindow, sources: Sources = Sources()) {
        self.window = window
        self.sources = sources
        super.init()
    }

    /// Publishes the initial snapshot synchronously, then publishes changes on the main actor.
    func start(onChange: @escaping @MainActor (PetAnimationSystemState) -> Void) {
        guard self.onChange == nil, let window else { return }
        self.onChange = onChange

        observe(sources.localNotifications, NSWindow.didChangeOcclusionStateNotification, object: window) { monitor in
            monitor.setPauseReason(.occluded, active: monitor.isWindowOccluded)
        }
        observe(sources.localNotifications, .NSProcessInfoPowerStateDidChange, object: ProcessInfo.processInfo) { monitor in
            monitor.setPauseReason(.lowPowerMode, active: monitor.sources.readLowPowerMode())
        }
        observe(sources.workspaceNotifications, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { monitor in
            var next = monitor.state
            next.reduceMotion = monitor.sources.readReduceMotion()
            monitor.publish(next)
        }
        observe(sources.workspaceNotifications, NSWorkspace.willSleepNotification) { monitor in
            monitor.setPauseReason(.systemSleeping, active: true)
        }
        observe(sources.workspaceNotifications, NSWorkspace.didWakeNotification) { monitor in
            monitor.setPauseReason(.systemSleeping, active: false)
        }
        for name in [Self.screenDidLock, Self.screenDidUnlock] {
            sources.lockNotifications.addObserver(self, selector: #selector(screenLockDidChange(_:)),
                                                  name: name, object: nil)
        }

        var initial = PetAnimationSystemState(reduceMotion: sources.readReduceMotion())
        if isWindowOccluded { initial.pauseReasons.insert(.occluded) }
        if sources.readLowPowerMode() { initial.pauseReasons.insert(.lowPowerMode) }
        if sources.readScreenLocked() { initial.pauseReasons.insert(.screenLocked) }
        state = initial
        onChange(initial)
    }

    func stop() {
        guard onChange != nil else { return }
        onChange = nil
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
        sources.lockNotifications.removeObserver(self, name: Self.screenDidLock, object: nil)
        sources.lockNotifications.removeObserver(self, name: Self.screenDidUnlock, object: nil)
    }

    isolated deinit { stop() }

    private var isWindowOccluded: Bool {
        window?.occlusionState.contains(.visible) != true
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                         handle: @escaping @MainActor (PetAnimationSystemMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.onChange != nil else { return }
                handle(self)
            }
        }
        observers.append((center, token))
    }

    // Distributed notifications are delivered on the main thread. The event wakes the monitor;
    // the current session, rather than the sender or payload, determines the lock state.
    @objc private func screenLockDidChange(_ notification: Notification) {
        guard onChange != nil else { return }
        setPauseReason(.screenLocked, active: sources.readScreenLocked())
    }

    private func setPauseReason(_ reason: PetAnimationSystemState.PauseReasons, active: Bool) {
        var next = state
        if active {
            next.pauseReasons.insert(reason)
        } else {
            next.pauseReasons.remove(reason)
        }
        publish(next)
    }

    private func publish(_ next: PetAnimationSystemState) {
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}
