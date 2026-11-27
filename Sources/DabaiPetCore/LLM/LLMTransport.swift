import Foundation

public protocol LLMTransport: Sendable {
    /// Implementations must propagate task cancellation to their underlying request.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionLLMTransport: LLMTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        // A redirected POST could carry provider credentials and conversation history to a different host.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw LLMClientError.invalidResponse }
        return (data, http)
    }
}

public enum LLMClientError: Error, Equatable, Sendable {
    case invalidConfiguration, missingAPIKey, credentialUnavailable
    case unauthorized, rateLimited, timedOut, invalidResponse
    case httpStatus(Int)
    case network(URLError.Code)
}

protocol LLMWireFormat: Sendable {
    var replyPath: String { get }
    func authenticate(_ request: inout URLRequest, key: String?) throws
    func body(model: String, system: String, messages: [ChatMessage], maxTokens: Int) throws -> Data
    func text(from data: Data) throws -> String
}
