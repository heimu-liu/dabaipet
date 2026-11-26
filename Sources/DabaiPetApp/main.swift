import AppKit
import Darwin
import Foundation

if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
    FileHandle.standardError.write(Data("DabaiPet: Launch without command-line options.\n".utf8))
    exit(EX_USAGE)
}

NSApplication.shared.run()
