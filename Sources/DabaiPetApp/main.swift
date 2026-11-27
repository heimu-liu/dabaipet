import AppKit
import DabaiPetUI
import DabaiPetCore
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let options = Array(arguments.dropFirst())

@MainActor
private func preparePetApplication() -> NSApplication {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    return app
}

@MainActor
private func applicationController() throws -> PetController {
    let store = KeychainStore()
    return try PetController(settingsConnectionActions: .configured(store: store),
                      llmClient: ConnectionServices(store: store).client,
                      makeVoiceInput: { SpeechInputService() })
}

@MainActor
private func runPet() throws {
    guard let instanceLock = try PetInstanceLock.acquire() else { return }
    defer { withExtendedLifetime(instanceLock) {} }

    let app = preparePetApplication()
    let delegate = AppDelegate(controller: try applicationController())
    app.delegate = delegate
    defer {
        delegate.shutdown()
        app.delegate = nil
    }
    delegate.start()
    app.run()
}

@MainActor
private func runPetSmoke(output: URL) throws {
    _ = preparePetApplication()
    let controller = try applicationController()
    defer { controller.shutdown() }
    try controller.writeSmoke(to: output)
}

do {
    switch arguments.first {
    case "--smoke-test":
        guard options.count == 2, options[0] == "--out", !options[1].isEmpty, !options[1].hasPrefix("--") else {
            FileHandle.standardError.write(Data("Usage: DabaiPet --smoke-test --out OUTPUT.json\n".utf8))
            exit(EX_USAGE)
        }
        try runPetSmoke(output: URL(fileURLWithPath: options[1]))
        exit(EXIT_SUCCESS)
    case "--keychain-canary":
        Task {
            do { exit(try await KeychainCanary.run(options) ? EXIT_SUCCESS : EXIT_FAILURE) }
            catch { exit(EX_DATAERR) }
        }
        dispatchMain()
    case "--snapshot":
        guard options.count == 2, options[0] == "--out", !options[1].isEmpty, !options[1].hasPrefix("--") else {
            FileHandle.standardError.write(Data("Usage: DabaiPet --snapshot --out OUTPUT.png\n".utf8))
            exit(EX_USAGE)
        }
        try BaymaxSnapshot.write(to: URL(fileURLWithPath: options[1]))
        exit(EXIT_SUCCESS)
    case "--spike-s1":
        try IdentityProbe.run(options)
    case "--spike-interaction":
        try InteractionProbe.run(options)
        exit(EXIT_SUCCESS)
    case "--spike-s4":
        try PerformanceProbe.run(options)
    default:
        if arguments.contains(where: { $0.hasPrefix("--") }) {
            FileHandle.standardError.write(Data("DabaiPet: Unknown command-line option.\n".utf8))
            exit(EX_USAGE)
        }
        try runPet()
        exit(EXIT_SUCCESS)
    }
    NSApplication.shared.run()
} catch {
    FileHandle.standardError.write(Data("DabaiPet: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
