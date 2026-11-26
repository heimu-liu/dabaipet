import AppKit
import ApplicationServices
import AVFoundation
import CryptoKit
import Security

@MainActor
enum IdentityProbe {
    // The harness changes this literal only in the second build's temporary source copy.
    static let buildMarker = "canonical"
    private static let service = "com.dabaipet.app.spikes.s1.disposable"

    private static func microphoneState() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    private static func keychain(phase: String, account: UUID, reference: URL) throws -> [String: Any] {
        // This probe exercises the file-based login Keychain ACL. Make any password
        // or trust prompt fail with an OSStatus instead of asking the user to approve it.
        let disabled = SecKeychainSetUserInteractionAllowed(false)
        guard disabled == errSecSuccess else { return ["disableInteractionStatus": disabled] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString
        ]
        switch phase {
        case "create":
            var bytes = [UInt8](repeating: 0, count: 32)
            let count = bytes.count
            let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            guard status == errSecSuccess else { return ["randomStatus": status] }
            let data = Data(bytes)
            try Data(SHA256.hash(data: data)).write(to: reference, options: .withoutOverwriting)
            var attributes = query
            attributes[kSecValueData as String] = data
            return ["addStatus": SecItemAdd(attributes as CFDictionary, nil)]
        case "read":
            var attributes = query
            attributes[kSecReturnData as String] = true
            var value: CFTypeRef?
            let status = SecItemCopyMatching(attributes as CFDictionary, &value)
            var result: [String: Any] = ["readStatus": status]
            if status == errSecSuccess, let data = value as? Data {
                let expected = try Data(contentsOf: reference)
                result["valueMatched"] = Data(SHA256.hash(data: data)) == expected
            }
            return result
        default:
            return ["deleteStatus": SecItemDelete(query as CFDictionary)]
        }
    }

    static func run(_ arguments: [String]) throws {
        guard (5...6).contains(arguments.count), ["create", "read", "delete"].contains(arguments[0]),
              let account = UUID(uuidString: arguments[1]),
              let seconds = Int(arguments[4]), (0...120).contains(seconds),
              arguments.count == 5 || (arguments[5] == "--ask-microphone" && arguments[0] == "create")
        else { throw CocoaError(.fileReadInvalidFileName) }
        let phase = arguments[0]
        let output = URL(fileURLWithPath: arguments[2])
        let reference = URL(fileURLWithPath: arguments[3])
        Task { @MainActor in
            do {
                var report: [String: Any] = [
                    "phase": phase, "account": account.uuidString, "build": buildMarker,
                    "bundleID": Bundle.main.bundleIdentifier ?? "", "pid": ProcessInfo.processInfo.processIdentifier
                ]
                report["keychain"] = try keychain(phase: phase, account: account, reference: reference)
                if phase != "delete" {
                    let before = microphoneState()
                    report["micBefore"] = before
                    var requested = false
                    if arguments.last == "--ask-microphone", before == "notDetermined" {
                        let alert = NSAlert()
                        alert.messageText = "验证麦克风授权能否跨编译保留？"
                        alert.informativeText = "此次仅请求系统权限，不会录音。"
                        alert.addButton(withTitle: "请求麦克风权限")
                        alert.addButton(withTitle: "跳过")
                        NSApp.activate()
                        if alert.runModal() == .alertFirstButtonReturn {
                            requested = true
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                        }
                    }
                    report["micRequested"] = requested
                    report["micAfter"] = microphoneState()
                    report["axTrustedBefore"] = AXIsProcessTrusted()
                    let start = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
                    try await Task.sleep(for: .seconds(seconds))
                    let end = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
                    report["counterSeconds"] = seconds
                    if end >= start {
                        report["counterDelta"] = end - start
                    } else {
                        report["counterDelta"] = NSNull()
                    }
                    report["axTrustedAfter"] = AXIsProcessTrusted()
                }
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("S1 failed to read or write its probe files.\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
    }
}
