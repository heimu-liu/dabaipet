import CredentialIPC
import DabaiPetCore
import Foundation
import Security

struct KeychainStore: SecretStore {
    private func call(_ operation: String, account: String, value: Data = Data()) async throws -> Data? {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var data: NSData?
                let status = DabaiCredentialCall(operation, account, value, &data)
                switch status {
                case errSecSuccess: continuation.resume(returning: data as Data?)
                case errSecItemNotFound where operation != "save": continuation.resume(returning: nil)
                default: continuation.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
                }
            }
        }
    }
    func read(account: String) async throws -> String? {
        guard let data = try await call("read", account: account) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw LLMClientError.credentialUnavailable }
        return text
    }
    func save(_ secret: String, account: String) async throws {
        _ = try await call("save", account: account, value: Data(secret.utf8))
    }
    func delete(account: String) async throws {
        _ = try await call("delete", account: account)
    }
}
