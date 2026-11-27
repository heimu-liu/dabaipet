import AVFoundation
import CryptoKit
import Foundation
import Speech

/// Offline file probe. Each invocation exercises one recognizer in a separate process.
@main struct S5Probe {
    static let requested = Locale(identifier: "zh-CN")
    static let expected = "你好，我是大白。今天我们一起喝水。"

    static func log(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    static func errorDetail(_ e: Error) -> String {
        let error = e as NSError
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " underlying=\($0.domain)/\($0.code) \($0.localizedDescription)" } ?? ""
        return "\(error.domain)/\(error.code) \(error.localizedDescription)\(underlying)"
    }

    static func verdict(_ text: String) -> Int32 {
        func normalize(_ value: String) -> String {
            String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        log("finalText=\(text)")
        let match = normalize(text) == normalize(expected)
        log("punctuationAndSpaceInsensitiveExactMatch=\(match)")
        return match ? 0 : 3
    }

    static func permissions() {
        log("speechAuthorization=\(SFSpeechRecognizer.authorizationStatus().rawValue) microphoneAuthorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
    }

    static func primary(_ url: URL, install: Bool) async throws -> Int32 {
        let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        let locales = await SpeechTranscriber.installedLocales
        log("speechTranscriberAvailable=\(SpeechTranscriber.isAvailable) equivalent=\(equivalent?.identifier ?? "nil") installedLocales=\(locales.map(\.identifier).sorted())")
        guard let equivalent, SpeechTranscriber.isAvailable else { return 4 }
        let module = SpeechTranscriber(locale: equivalent, preset: .transcription)
        let before = await AssetInventory.status(forModules: [module])
        log("assetStatusBefore=\(before) reservedLocalesBefore=\(await AssetInventory.reservedLocales.map(\.identifier))")
        if install && before != .installed {
            // This mode is run only following explicit user approval of asset installation.
            log("installPhase=request")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                log("installRequest=created downloadAndInstall=start")
                do { try await request.downloadAndInstall() }
                catch { log("installFailureStage=downloadOrInstall"); throw error }
            }
            log("assetStatusAfterInstall=\(await AssetInventory.status(forModules: [module]))")
        }
        let file = try AVAudioFile(forReading: url)
        defer { file.close(); log("inputAudioFileClosed=true") }
        let analyzer = SpeechAnalyzer(modules: [module])
        let reader = Task {
            var text = ""
            for try await result in module.results {
                let segment = String(result.text.characters)
                log("segment final=\(result.isFinal) text=\(segment)")
                if result.isFinal { text += segment }
            }
            return text
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(30))
            log("probeDeadline=30s cancelAnalyzer=true")
            await analyzer.cancelAndFinishNow()
            reader.cancel()
        }
        defer { deadline.cancel() }
        do {
            log("analyzer.start fileFrames=\(file.length) sampleRate=\(file.processingFormat.sampleRate) finishAfterFile=true")
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let text = try await reader.value
            log("analyzerResultsFinished=true")
            await analyzer.cancelAndFinishNow()
            log("analyzerSessionEnded=true assetStatusAfter=\(await AssetInventory.status(forModules: [module]))")
            return verdict(text)
        } catch {
            await analyzer.cancelAndFinishNow()
            reader.cancel()
            _ = await reader.result
            log("analyzerCancelled=true readerJoined=true assetStatusAfter=\(await AssetInventory.status(forModules: [module]))")
            throw error
        }
    }

    enum LegacyEvent: Sendable {
        case text(String, final: Bool)
        case failure(String)
        case timeout
    }

    @MainActor static func fallback(_ url: URL, authorize: Bool) async -> Int32 {
        guard let engine = SFSpeechRecognizer(locale: requested) else { log("recognizer=nil"); return 4 }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        log("recognizerLocale=\(engine.locale.identifier) available=\(engine.isAvailable) supportsOnDevice=\(engine.supportsOnDeviceRecognition) requiresOnDevice=\(request.requiresOnDeviceRecognition)")
        guard engine.isAvailable, engine.supportsOnDeviceRecognition else { log("unavailableForLocalRequest=true"); return 4 }
        if authorize && SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            log("personalSpeechAuthorizationRequested=true")
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            log("authorizationDecision=\(status.rawValue)")
        }
        let auth = SFSpeechRecognizer.authorizationStatus()
        guard auth != .denied, auth != .restricted else { log("speechAccessBlocked=true"); return 4 }
        let (events, sink) = AsyncStream<LegacyEvent>.makeStream()
        log("onDeviceFileTask=start")
        let task = engine.recognitionTask(with: request) { result, error in
            if let error { sink.yield(.failure(errorDetail(error))); return }
            if let result { sink.yield(.text(result.bestTranscription.formattedString, final: result.isFinal)) }
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(30))
            sink.yield(.timeout)
        }
        defer { deadline.cancel(); sink.finish() }
        for await event in events {
            switch event {
            case let .text(text, final):
                if final { log("legacyFinal=true taskState=\(task.state.rawValue)"); return verdict(text) }
            case let .failure(message):
                log("systemError=\(message)"); task.cancel(); log("cancelSent=true"); return 2
            case .timeout:
                log("probeDeadline=30s"); task.cancel(); log("cancelSent=true"); return 5
            }
        }
        return 2
    }

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, ["primary", "legacy", "primary-install", "legacy-authorize"].contains(args[0]) else { exit(64) }
        let url = URL(fileURLWithPath: args[1])
        log("mode=\(args[0]) pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "-") requestedLocale=\(requested.identifier)")
        permissions()
        let installation = args[0] == "primary-install"
        let reservedBefore = installation ? await AssetInventory.reservedLocales : []
        let code: Int32
        do {
            log("inputSHA256=\(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined())")
            if args[0].hasPrefix("primary") {
                code = try await primary(url, install: args[0] == "primary-install")
            } else {
                code = await fallback(url, authorize: args[0] == "legacy-authorize")
            }
        } catch {
            log("systemError=\(errorDetail(error))")
            code = 2
        }
        if installation, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested),
           !reservedBefore.contains(locale), await AssetInventory.reservedLocales.contains(locale) {
            let released = await AssetInventory.release(reservedLocale: locale)
            log("releasedProbeReservation=\(released)")
        }
        permissions()
        log("probeExit=\(code)")
        exit(code)
    }
}
