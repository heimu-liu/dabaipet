import Foundation
import os

/// A diagnostic can address only randomly named synthetic canaries and never returns their contents.
enum KeychainCanary {
    struct Receipt: Codable {
        var phase: String
        var pid = ProcessInfo.processInfo.processIdentifier
        var bundle = Bundle.main.bundleURL.path
        var identifier = Bundle.main.bundleIdentifier
        var ok = false
        var status: Int?
    }

    static func run(_ args: [String]) async throws -> Bool {
        guard args.count == 5, let id = UUID(uuidString: args[1]), args[3] == "--out",
              ["create", "read", "read-updated", "update", "delete"].contains(args[0]) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let phase = args[0]
        let account = "canary-" + id.uuidString
        let output = URL(fileURLWithPath: args[4])
        let raw = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        guard raw.count == 58, let first = String(data: raw, encoding: .utf8),
              first.range(of: #"\Ask-CANARY-[0-9a-f]{48}\z"#, options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let second = first + "-updated"
        let store = KeychainStore()
        var receipt = Receipt(phase: phase)
        do {
            let before = try await store.read(account: account)
            switch phase {
            case "create" where before == nil:
                try await store.save(first, account: account)
                receipt.ok = try await store.read(account: account) == first
            case "read":
                receipt.ok = before == first
            case "read-updated":
                receipt.ok = before == second
            case "update" where before == first || before == second:
                try await store.save(second, account: account)
                receipt.ok = try await store.read(account: account) == second
            case "delete" where before == first || before == second:
                try await store.delete(account: account)
                receipt.ok = try await store.read(account: account) == nil
            default: break
            }
        } catch {
            receipt.status = (error as NSError).code
        }
        Logger(subsystem: "com.dabaipet.app", category: "credential-canary").notice("Disposable credential operation completed")
        try JSONEncoder().encode(receipt).write(to: output, options: .withoutOverwriting)
        return receipt.ok
    }
}
