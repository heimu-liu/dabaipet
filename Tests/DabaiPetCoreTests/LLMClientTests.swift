import Foundation
import Synchronization
import Testing
@testable import DabaiPetCore

private actor WireSpy: LLMTransport {
    private(set) var requests: [URLRequest] = []
    let steps: [(Int, Data)]
    init(_ steps: [(Int, Data)]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        guard steps.indices.contains(index) else { throw URLError(.unknown) }
        let (code, data) = steps[index]
        return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private struct Signal: Sendable {
    private let pair = AsyncStream<Void>.makeStream()
    func open() { pair.continuation.yield(()); pair.continuation.finish() }
    func wait() async { for await _ in pair.stream { return } }
}

private final class LateTransport: LLMTransport {
    let started = Signal()
    let cancelled = Signal()
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation.withLock { $0 = continuation }
                started.open()
            }
        } onCancel: { self.cancelled.open() }
        return (LLMResponseFixtures.openAI, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func release() { continuation.withLock { $0?.resume(); $0 = nil } }
}

private final class ManualTime: Sendable {
    let origin = ContinuousClock.now
    let elapsed = Mutex<Duration>(.zero)
    let target = Mutex<ContinuousClock.Instant?>(nil)
    let armed = Signal()
    let alarm = Signal()
    var now: ContinuousClock.Instant { origin.advanced(by: elapsed.withLock { $0 }) }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        target.withLock { $0 = deadline }
        armed.open()
        await alarm.wait()
        try Task.checkCancellation()
    }
}

struct LLMClientTests {
    private func config(_ provider: LLMProvider = .openAICompatible, _ path: String = "") -> LLMConfig {
        LLMConfig(provider: provider, baseURL: URL(string: "https://fixture.invalid/gateway" + path)!, model: "fixture-model")
    }

    @Test(arguments: ["openai", "deepseek", "ollama", "anthropic"])
    func vendorContracts(_ vendor: String) async throws {
        let fixture: Data
        let answer: String
        switch vendor {
        case "openai": (fixture, answer) = (LLMResponseFixtures.openAI, "[happy] OK")
        case "deepseek": (fixture, answer) = (LLMResponseFixtures.deepSeek, "[care] OK")
        case "ollama": (fixture, answer) = (LLMResponseFixtures.ollama, "OK")
        default: (fixture, answer) = (LLMResponseFixtures.anthropic, "[happy]\nOK")
        }
        let anthropic = vendor == "anthropic"
        for suffix in ["", "/", "/v1", "/v1/"] {
            let transport = WireSpy([(200, fixture)])
            let store = InMemorySecretStore()
            if vendor != "ollama" { await store.save("fixture-only", account: vendor) }
            let client = LLMClient(transport: transport, apiKey: { _ in await store.read(account: vendor) })
            let history = [ChatMessage(role: .assistant, content: "orphan"), .init(role:.user,content:"old"),
                           .init(role:.assistant,content:"old"), .init(role:.user,content:"q"),
                           .init(role:.assistant,content:"a"), .init(role:.user,content:"unpaired")]
            let result = try await client.reply(config: config(anthropic ? .anthropic : .openAICompatible, suffix),
                                                system:"instruction", history:history, input:"next", maxHistoryTurns:1)
            #expect(result == answer)
            let records = await transport.requests
            let req = try #require(records.first)
            #expect(records.count == 1 && req.httpMethod == "POST")
            #expect(req.url?.path == "/gateway/v1/" + (anthropic ? "messages" : "chat/completions"))
            #expect(req.value(forHTTPHeaderField:"Content-Type") == "application/json")
            let bearer = req.value(forHTTPHeaderField:"Authorization")
            #expect(bearer == (!anthropic && vendor != "ollama" ? "Bearer fixture-only" : nil))
            #expect(req.value(forHTTPHeaderField:"x-api-key") == (anthropic ? "fixture-only" : nil))
            #expect(req.value(forHTTPHeaderField:"anthropic-version") == (anthropic ? "2023-06-01" : nil))
            let bytes = try #require(req.httpBody)
            let object = try JSONSerialization.jsonObject(with: bytes)
            let body = try #require(object as? [String:Any])
            #expect(body["max_tokens"] as? Int == 256 && body["stream"] as? Bool == false)
            #expect(body["model"] as? String == "fixture-model")
            #expect(body["system"] as? String == (anthropic ? "instruction" : nil))
            let messages = try #require(body["messages"] as? [[String:String]])
            #expect(messages.compactMap { $0["role"] } == (anthropic ? [] : ["system"]) + ["user","assistant","user"])
            #expect(messages.compactMap { $0["content"] } == (anthropic ? [] : ["instruction"]) + ["q","a","next"])
        }
    }

    @Test func typedFailures() async {
        for provider in [LLMProvider.openAICompatible, .anthropic] {
            let cases: [(Int,Data,LLMClientError)] = [
                (401,Data(),.unauthorized), (429,Data(),.rateLimited), (503,Data(),.httpStatus(503)),
                (200,Data("{".utf8),.invalidResponse), (200,Data("{}".utf8),.invalidResponse),
                (200,Data(#"{"choices":[{"message":{"role":"assistant","content":"","reasoning_content":"hidden"}}]}"#.utf8),.invalidResponse)
            ]
            for (status, payload, error) in cases {
                let client = LLMClient(transport:WireSpy([(status,payload)]), apiKey:{ _ in "fixture-only" })
                await #expect(throws:error) { try await client.reply(config:config(provider), system:"", history:[], input:"q") }
            }
        }
    }

    @Test func modelsProbeAndShortFallback() async throws {
        for provider in [LLMProvider.openAICompatible, .anthropic] {
            for initial in [200, 404, 405, 501, 401, 429] {
                let spy = WireSpy([(initial,LLMResponseFixtures.models), (200,provider == .anthropic ? LLMResponseFixtures.anthropic : LLMResponseFixtures.ollama)])
                let client = LLMClient(transport:spy, apiKey:{ _ in "fixture-only" })
                if [401,429].contains(initial) {
                    let expected: LLMClientError = initial == 401 ? .unauthorized : .rateLimited
                    await #expect(throws:expected) { try await client.testConnection(config:config(provider)) }
                } else { try await client.testConnection(config:config(provider)) }
                let requests = await spy.requests
                #expect(requests[0].httpMethod == "GET" && requests[0].url?.path == "/gateway/v1/models" && requests[0].httpBody == nil)
                let fallback = [404,405,501].contains(initial)
                #expect(requests.count == (fallback ? 2 : 1))
                if fallback {
                    let bytes = try #require(requests[1].httpBody)
                    let object = try JSONSerialization.jsonObject(with: bytes)
                    let body = try #require(object as? [String:Any])
                    #expect(body["max_tokens"] as? Int == 8)
                }
            }
        }
    }

    @Test func configurationAndCredentials() async throws {
        let spy = WireSpy([])
        let client = LLMClient(transport: spy)
        await #expect(throws: LLMClientError.missingAPIKey) {
            try await client.reply(config: config(.anthropic), system: "", history: [], input: "q")
        }
        for endpoint in ["file:///tmp/fixture", "https://user:pass@fixture.invalid", "https://fixture.invalid/?test=1"] {
            var invalid = config()
            invalid.baseURL = try #require(URL(string: endpoint))
            let value = invalid
            await #expect(throws: LLMClientError.invalidConfiguration) { try await client.testConnection(config: value) }
        }
        let unavailable = LLMClient(transport: spy, apiKey: { _ in throw URLError(.cannotOpenFile) })
        await #expect(throws: LLMClientError.credentialUnavailable) { try await unavailable.testConnection(config: config()) }
        #expect(await spy.requests.isEmpty)
    }

    @Test func transportErrors() async {
        struct Failing: LLMTransport {
            let code: URLError.Code
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(code) }
        }
        for code in [URLError.Code.timedOut, .notConnectedToInternet] {
            let client = LLMClient(transport: Failing(code: code))
            let expected: LLMClientError = code == .timedOut ? .timedOut : .network(code)
            await #expect(throws: expected) { try await client.testConnection(config: config()) }
        }
    }

    @Test func fallbackCannotRenewDeadline() async {
        final class SlowModels: LLMTransport {
            let time: ManualTime
            let paths = Mutex<[String]>([])
            init(time: ManualTime) { self.time = time }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                paths.withLock { $0.append(request.httpMethod ?? "") }
                time.elapsed.withLock { $0 = .seconds(20) }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
        let time = ManualTime()
        let wire = SlowModels(time: time)
        let client = LLMClient(transport: wire, apiKey: { _ in nil }, now: { time.now }, sleepUntil: time.sleep)
        await #expect(throws: LLMClientError.timedOut) { try await client.testConnection(config: config()) }
        #expect(wire.paths.withLock { $0 } == ["GET"])
    }

    @Test(arguments:["timeout","cancel","late"])
    func deadlineAndCancellation(_ cause: String) async throws {
        let wire = LateTransport()
        let time = ManualTime()
        let client = LLMClient(transport:wire, apiKey:{ _ in nil }, now:{ time.now }, sleepUntil:time.sleep)
        let work = Task { try await client.reply(config:config(), system:"", history:[], input:"q") }
        await wire.started.wait()
        await time.armed.wait()
        #expect(time.target.withLock { $0 } == time.origin.advanced(by:.seconds(20)))
        switch cause {
        case "cancel":
            work.cancel()
            await #expect(throws:CancellationError.self) { try await work.value }
        case "timeout":
            time.elapsed.withLock { $0 = .seconds(20) }; time.alarm.open()
            await #expect(throws:LLMClientError.timedOut) { try await work.value }
        default:
            time.elapsed.withLock { $0 = .seconds(21) }; wire.release()
            await #expect(throws:LLMClientError.timedOut) { try await work.value }
        }
        if cause != "late" { await wire.cancelled.wait(); wire.release() }
    }
}
