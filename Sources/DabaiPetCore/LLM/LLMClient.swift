import Foundation
import os

/// One deadline covers credential lookup, request(s) and response decoding.
public struct LLMClient: Sendable {
    public typealias KeySource = @Sendable (LLMConfig) async throws -> String?
    private let transport: any LLMTransport
    private let apiKey: KeySource
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    private static let log = Logger(subsystem: "com.dabaipet.app", category: "llm")

    public init(transport: any LLMTransport = URLSessionLLMTransport(),
                apiKey: @escaping KeySource = { _ in nil }) {
        self.init(transport: transport, apiKey: apiKey, now: { .now },
                  sleepUntil: { try await ContinuousClock().sleep(until: $0, tolerance: .zero) })
    }

    init(transport: any LLMTransport, apiKey: @escaping KeySource,
         now: @escaping @Sendable () -> ContinuousClock.Instant,
         sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) {
        self.transport = transport
        self.apiKey = apiKey
        self.now = now
        self.sleepUntil = sleepUntil
    }

    public func reply(config: LLMConfig, system: String, history: [ChatMessage], input: String,
                      maxHistoryTurns: Int = 6) async throws -> String {
        try await withDeadline(config.timeoutSeconds) { deadline in
            let wire = try wireFormat(config)
            let key = try await credential(config)
            let messages = ChatMessage.requestMessages(history: history, pendingUserInput: input, maxHistoryTurns: maxHistoryTurns)
            return try await complete(config, wire: wire, key: key, system: system, messages: messages, limit: config.maxTokens, deadline: deadline)
        }
    }

    public func testConnection(config: LLMConfig) async throws {
        try await withDeadline(config.timeoutSeconds) { deadline in
            let wire = try wireFormat(config)
            let key = try await credential(config)
            let get = try request(config, path: "models", wire: wire, key: key)
            do {
                let data = try await exchange(get, deadline: deadline)
                struct Models: Decodable {
                    struct Model: Decodable { let id: String }
                    let data: [Model]
                }
                guard (try? JSONDecoder().decode(Models.self, from: data)) != nil else {
                    throw LLMClientError.invalidResponse
                }
            } catch LLMClientError.httpStatus(let status) where [404, 405, 501].contains(status) {
                _ = try await complete(config, wire: wire, key: key, system: "",
                                       messages: [.init(role: .user, content: "OK")], limit: 8, deadline: deadline)
            }
        }
    }

    private func wireFormat(_ config: LLMConfig) throws -> any LLMWireFormat {
        guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              config.maxTokens > 0 else { throw LLMClientError.invalidConfiguration }
        switch config.provider {
        case .openAICompatible: return OpenAICompatibleClient()
        case .anthropic: return AnthropicClient()
        case .local: throw LLMClientError.invalidConfiguration
        }
    }

    private func credential(_ config: LLMConfig) async throws -> String? {
        let key: String?
        do { key = try await apiKey(config) }
        catch is CancellationError { throw CancellationError() }
        catch LLMClientError.missingAPIKey { throw LLMClientError.missingAPIKey }
        catch { throw LLMClientError.credentialUnavailable }
        guard let key, !key.isEmpty else { return nil }
        guard key.rangeOfCharacter(from: .controlCharacters) == nil else { throw LLMClientError.invalidConfiguration }
        return key
    }

    private func request(_ config: LLMConfig, path: String, wire: any LLMWireFormat, key: String?) throws -> URLRequest {
        var parts = try config.endpointComponents()
        parts.percentEncodedPath += "/" + path
        guard let url = parts.url else { throw LLMClientError.invalidConfiguration }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        try wire.authenticate(&req, key: key)
        return req
    }

    private func complete(_ config: LLMConfig, wire: any LLMWireFormat, key: String?, system: String,
                          messages: [ChatMessage], limit: Int, deadline: ContinuousClock.Instant) async throws -> String {
        var post = try request(config, path: wire.replyPath, wire: wire, key: key)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try wire.body(model: config.model, system: system, messages: messages, maxTokens: limit)
        let data = try await exchange(post, deadline: deadline)
        guard let text = try? wire.text(from: data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMClientError.invalidResponse
        }
        return text
    }

    private func exchange(_ request: URLRequest, deadline: ContinuousClock.Instant) async throws -> Data {
        try Task.checkCancellation()
        guard now() < deadline else { throw LLMClientError.timedOut }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw LLMClientError.timedOut
            default: throw LLMClientError.network(error.code)
            }
        } catch let error as LLMClientError { throw error }
        catch { throw LLMClientError.network(.unknown) }
        try Task.checkCancellation()
        Self.log.debug("LLM status \(response.statusCode, privacy: .private)")
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw LLMClientError.unauthorized
        case 429: throw LLMClientError.rateLimited
        default: throw LLMClientError.httpStatus(response.statusCode)
        }
    }

    private func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                            operation: @escaping @Sendable (ContinuousClock.Instant) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard seconds.isFinite, seconds > 0 else { throw LLMClientError.invalidConfiguration }
        let deadline = now().advanced(by: .seconds(min(seconds, 20)))
        // A structured task group would wait for a transport that ignores cancellation.
        // The one-shot stream lets the caller finish and discards any subsequent result.
        let (results, sink) = AsyncStream<Result<T, any Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let work = Task {
            do {
                try Task.checkCancellation()
                sink.yield(.success(try await operation(deadline)))
            } catch { sink.yield(.failure(error)) }
        }
        let alarm = Task {
            do {
                try await sleepUntil(deadline)
                try Task.checkCancellation()
                sink.yield(.failure(LLMClientError.timedOut))
                work.cancel()
            } catch { /* The operation completed or the caller cancelled. */ }
        }
        defer { work.cancel(); alarm.cancel(); sink.finish() }
        var iterator = results.makeAsyncIterator()
        let result = await iterator.next()
        try Task.checkCancellation()
        guard now() < deadline else { throw LLMClientError.timedOut }
        guard let result else { throw CancellationError() }
        return try result.get()
    }
}
