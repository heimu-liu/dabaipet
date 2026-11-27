import AVFoundation
import CoreAudio
import Foundation
import Speech

@MainActor
final class VoicePermissionCoordinator {
    enum Kind: String { case microphone, speech }
    enum Access { case undetermined, allowed, denied, restricted }
    enum Route: Equatable { case analyzer(Locale), legacy(Locale) }
    enum Failure: Error, Equatable {
        case denied(Kind), restricted(Kind), cancelled, noInput, noRecognizer, captureFailed, noSpeech, unconfirmedTranscript

        static func recognition(_ error: any Error) -> Self {
            if let failure = error as? Self { return failure }
            if error is CancellationError { return .cancelled }
            let native = error as NSError
            if native.domain == NSCocoaErrorDomain, native.code == NSUserCancelledError { return .cancelled }
            if native.domain == "kAFAssistantErrorDomain", native.code == 1110 { return .noSpeech }
            if native.domain == SFSpeechErrorDomain,
               [SFSpeechError.Code.noModel, .assetLocaleNotAllocated, .cannotAllocateUnsupportedLocale]
                .contains(where: { $0.rawValue == native.code }) { return .noRecognizer }
            return .captureFailed
        }

        var message: String {
            switch self {
            case .denied(let kind):
                let item = kind == .microphone ? "麦克风" : "语音识别"
                return "请在“系统设置 → 隐私与安全性 → \(item)”中允许大白，也可以继续打字。"
            case .restricted(let kind):
                let item = kind == .microphone ? "麦克风" : "语音识别"
                return "\(item)使用受限。请联系设备管理员，或继续打字。"
            case .cancelled: return "已取消语音输入，可以继续打字。"
            case .noInput: return "请连接麦克风，并在“系统设置 → 声音 → 输入”中选择它，或继续打字。"
            case .noRecognizer: return "中文端侧语音识别暂不可用。请检查中文语音资源，或继续打字。"
            case .captureFailed: return "语音输入启动或识别失败，请重试或继续打字。"
            case .unconfirmedTranscript: return "刚才没听清，请再说一次。"
            case .noSpeech: return "没有听到语音，请再说一次或继续打字。"
            }
        }
    }

    struct Environment {
        var hasInput: @MainActor () -> Bool
        var primaryLocale: @MainActor () async -> Locale?
        var legacyLocale: @MainActor () -> Locale?
        var status: @MainActor (Kind) -> Access
        var request: @MainActor (Kind) async -> Access

        static var system: Self {
            .init(hasInput: defaultInputAvailable, primaryLocale: {
                guard SpeechTranscriber.isAvailable,
                      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else { return nil }
                let module = SpeechTranscriber(locale: locale, preset: .transcription)
                let inventory = await AssetInventory.status(forModules: [module])
                if inventory == .installed { return locale }
                // S5 observed a working installed locale whose module inventory reported supported.
                guard inventory == .supported, await SpeechTranscriber.installedLocales.contains(locale) else { return nil }
                return locale
            }, legacyLocale: {
                let requested = Locale(identifier: "zh-CN")
                guard let recognizer = SFSpeechRecognizer(locale: requested),
                      recognizer.locale.language.isEquivalent(to: requested.language),
                      recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return nil }
                return recognizer.locale
            }, status: { kind in
                switch kind {
                case .microphone:
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized: return .allowed
                    case .denied: return .denied
                    case .notDetermined: return .undetermined
                    default: return .restricted
                    }
                case .speech: return speechAccess(SFSpeechRecognizer.authorizationStatus())
                }
            }, request: { kind in
                switch kind {
                case .microphone:
                    if await AVCaptureDevice.requestAccess(for: .audio) { return .allowed }
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .notDetermined: return .undetermined
                    case .denied: return .denied
                    default: return .restricted
                    }
                case .speech:
                    let decision = await withCheckedContinuation { continuation in
                        SFSpeechRecognizer.requestAuthorization { @Sendable in continuation.resume(returning: $0) }
                    }
                    return speechAccess(decision)
                }
            })
        }

        private static func speechAccess(_ status: SFSpeechRecognizerAuthorizationStatus) -> Access {
            switch status {
            case .authorized: .allowed
            case .denied: .denied
            case .notDetermined: .undetermined
            default: .restricted
            }
        }

        private static func defaultInputAvailable() -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout.size(ofValue: device))
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                             &size, &device) == noErr, device != kAudioObjectUnknown else { return false }
            address.mSelector = kAudioDevicePropertyStreams
            address.mScope = kAudioObjectPropertyScopeInput
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size >= MemoryLayout<AudioStreamID>.size
        }
    }

    typealias Completion = @MainActor (Result<Route, Failure>) -> Void
    private let environment: Environment
    private var pending: Task<Void, Never>?
    private var completion: Completion?
    // macOS owns a displayed permission sheet. A fresh user intent may reuse its decision after cancellation.
    private var waiters: [Kind: [CheckedContinuation<Access, Never>]] = [:]
    var isPending: Bool { pending != nil }

    init(environment: Environment = .system) { self.environment = environment }

    func requestFromUser(legacyOnly: Bool = false, completion: @escaping Completion) {
        guard pending == nil else { return }
        self.completion = completion
        pending = Task {
            let outcome: Result<Route, Failure>
            do { outcome = .success(try await resolve(legacyOnly: legacyOnly)) }
            catch let reason as Failure { outcome = .failure(reason) }
            catch { outcome = .failure(.cancelled) }
            guard !Task.isCancelled else { return }
            finish(outcome)
        }
    }

    func cancel() {
        guard let pending else { return }
        pending.cancel()
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<Route, Failure>) {
        let callback = completion
        pending = nil
        completion = nil
        callback?(result)
    }

    private func route(legacyOnly: Bool) async throws -> Route {
        if !legacyOnly, let locale = await environment.primaryLocale() { return .analyzer(locale) }
        try Task.checkCancellation()
        guard let locale = environment.legacyLocale() else { throw Failure.noRecognizer }
        return .legacy(locale)
    }

    private func resolve(legacyOnly: Bool) async throws -> Route {
        try Task.checkCancellation()
        guard environment.hasInput() else { throw Failure.noInput }
        let initial = try await route(legacyOnly: legacyOnly)
        try Task.checkCancellation()
        if case .legacy = initial {
            let speech = environment.status(.speech)
            if speech != .undetermined { try requireAccess(speech, for: .speech) }
        }
        try await authorize(.microphone)
        guard environment.hasInput() else { throw Failure.noInput }
        let selected = try await route(legacyOnly: legacyOnly)
        if case .legacy = selected {
            try await authorize(.speech)
            guard environment.legacyLocale() != nil else { throw Failure.noRecognizer }
            try requireAccess(environment.status(.speech), for: .speech)
        }
        try Task.checkCancellation()
        guard environment.hasInput() else { throw Failure.noInput }
        try requireAccess(environment.status(.microphone), for: .microphone)
        return selected
    }

    /// Subsequent turns use the established route only while its grants and input are still available.
    func validateForNextTurn(_ route: Route) throws {
        guard environment.hasInput() else { throw Failure.noInput }
        try requireAccess(environment.status(.microphone), for: .microphone)
        if case .legacy = route { try requireAccess(environment.status(.speech), for: .speech) }
    }

    private func authorize(_ kind: Kind) async throws {
        try Task.checkCancellation()
        let current = environment.status(kind)
        guard current == .undetermined else { return try requireAccess(current, for: kind) }
        let result: Access
        if waiters[kind] != nil {
            result = await withCheckedContinuation { waiters[kind, default: []].append($0) }
        } else {
            waiters[kind] = []
            result = await environment.request(kind)
            for waiter in waiters.removeValue(forKey: kind) ?? [] { waiter.resume(returning: result) }
        }
        try Task.checkCancellation()
        try requireAccess(result, for: kind)
    }

    private func requireAccess(_ access: Access, for kind: Kind) throws {
        switch access {
        case .allowed: return
        case .restricted: throw Failure.restricted(kind)
        case .denied: throw Failure.denied(kind)
        case .undetermined: throw Failure.cancelled
        }
    }
}
