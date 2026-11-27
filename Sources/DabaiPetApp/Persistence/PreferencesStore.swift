import CoreFoundation
import CoreGraphics
import Foundation

struct PetPreferences: Equatable {
    enum Scale: Double, CaseIterable {
        case small = 0.8
        case standard = 1.0
        case large = 1.25
    }

    enum HealthReminderInterval: Int, CaseIterable {
        case off = 0
        case minutes30 = 30
        case minutes45 = 45
        case minutes60 = 60
    }

    var scale: Scale = .standard
    var isSpeechMuted = false
    var healthReminderInterval: HealthReminderInterval = .off
    var isTypingCompanionEnabled = false
    var isRPSEnabled = false
}

@MainActor
struct PreferencesStore {
    private static let preferencesKey = "DabaiPet.preferences.v1"
    private static let windowOriginKey = "DabaiPet.windowOrigin.v1"
    private static let connectionKey = "DabaiPet.connection.v1"
    private static let defaultWindowInset: CGFloat = 16

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPreferences() -> PetPreferences {
        guard let values = defaults.dictionary(forKey: Self.preferencesKey) else { return PetPreferences() }

        var preferences = PetPreferences()
        if let value = Self.number(values["scale"]), let scale = PetPreferences.Scale(rawValue: value) {
            preferences.scale = scale
        }
        if let value = Self.number(values["healthReminderInterval"]), let minutes = Int(exactly: value),
           let interval = PetPreferences.HealthReminderInterval(rawValue: minutes) {
            preferences.healthReminderInterval = interval
        }
        preferences.isSpeechMuted = Self.boolean(values["isSpeechMuted"]) ?? preferences.isSpeechMuted
        preferences.isTypingCompanionEnabled = Self.boolean(values["isTypingCompanionEnabled"])
            ?? preferences.isTypingCompanionEnabled
        preferences.isRPSEnabled = Self.boolean(values["isRPSEnabled"]) ?? preferences.isRPSEnabled
        return preferences
    }

    func savePreferences(_ preferences: PetPreferences) {
        defaults.set([
            "scale": preferences.scale.rawValue,
            "isSpeechMuted": preferences.isSpeechMuted,
            "healthReminderInterval": preferences.healthReminderInterval.rawValue,
            "isTypingCompanionEnabled": preferences.isTypingCompanionEnabled,
            "isRPSEnabled": preferences.isRPSEnabled,
        ], forKey: Self.preferencesKey)
    }

    func loadConnection() -> (provider: String?, baseURL: String, model: String) {
        let values = defaults.dictionary(forKey: Self.connectionKey)
        return (values?["provider"] as? String, values?["baseURL"] as? String ?? "", values?["model"] as? String ?? "")
    }

    func saveConnection(provider: String, baseURL: String, model: String) {
        defaults.set(["provider": provider, "baseURL": baseURL, "model": model], forKey: Self.connectionKey)
    }

    /// Save the resting panel origin on the built-in screen after a completed move.
    func saveWindowOrigin(_ origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        defaults.set(["x": Double(origin.x), "y": Double(origin.y)], forKey: Self.windowOriginKey)
    }

    /// Pass the current built-in screen's visible frame and the resting panel size.
    /// A nil result means geometry is unavailable. The saved origin is left intact.
    func restoredWindowOrigin(for windowSize: CGSize, in visibleFrame: CGRect) -> CGPoint? {
        guard visibleFrame.size.width > 0, visibleFrame.size.height > 0,
              visibleFrame.minX.isFinite, visibleFrame.minY.isFinite,
              visibleFrame.maxX.isFinite, visibleFrame.maxY.isFinite,
              windowSize.width.isFinite, windowSize.width > 0,
              windowSize.height.isFinite, windowSize.height > 0 else { return nil }

        let maxX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)
        let origin = savedWindowOrigin() ?? CGPoint(x: maxX - Self.defaultWindowInset,
                                                    y: visibleFrame.minY + Self.defaultWindowInset)
        return CGPoint(x: min(max(origin.x, visibleFrame.minX), maxX),
                       y: min(max(origin.y, visibleFrame.minY), maxY))
    }

    private func savedWindowOrigin() -> CGPoint? {
        guard let values = defaults.dictionary(forKey: Self.windowOriginKey),
              let x = Self.number(values["x"]), let y = Self.number(values["y"]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
