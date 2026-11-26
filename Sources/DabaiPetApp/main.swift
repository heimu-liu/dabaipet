import AppKit
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let options = Array(arguments.dropFirst())

do {
    switch arguments.first {
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
    }
    NSApplication.shared.run()
} catch {
    FileHandle.standardError.write(Data("DabaiPet: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
