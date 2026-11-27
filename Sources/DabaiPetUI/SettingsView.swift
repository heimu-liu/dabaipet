import Combine
import DabaiPetCore
import Foundation
import SwiftUI

@MainActor
public struct SettingsView: View {
    public struct Connection: Equatable, Sendable {
        public var provider: LLMProvider
        public var baseURL: String
        public var model: String

        public init(provider: LLMProvider = .local, baseURL: String = "", model: String = "") {
            self.provider = provider
            self.baseURL = baseURL
            self.model = model
        }

        public var validatedBaseURL: URL? {
            let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: input),
                  let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil else { return nil }
            return components.url
        }

        public var configuration: LLMConfig? {
            let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard provider != .local, let url = validatedBaseURL, !modelName.isEmpty else { return nil }
            return LLMConfig(provider: provider, baseURL: url, model: modelName)
        }
    }

    public struct Companion: Equatable, Sendable {
        public var scale: Double
        public var isSpeechMuted: Bool
        public var healthReminderMinutes: Int
        public var isTypingCompanionEnabled: Bool

        public init(scale: Double, isSpeechMuted: Bool, healthReminderMinutes: Int, isTypingCompanionEnabled: Bool) {
            self.scale = scale
            self.isSpeechMuted = isSpeechMuted
            self.healthReminderMinutes = healthReminderMinutes
            self.isTypingCompanionEnabled = isTypingCompanionEnabled
        }
    }

    public enum Preset: String, CaseIterable {
        case openAI = "OpenAI"
        case deepSeek = "DeepSeek"
        case ollama = "Ollama"

        public var connection: Connection {
            switch self {
            case .openAI: Connection(provider: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
            case .deepSeek: Connection(provider: .openAICompatible, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
            case .ollama: Connection(provider: .openAICompatible, baseURL: "http://localhost:11434/v1")
            }
        }
    }

    public struct ConnectionActions {
        let saveKey: (@MainActor (LLMConfig, String) async throws -> Void)?
        let test: (@MainActor (LLMConfig) async throws -> Void)?

        public var canSaveKey: Bool { saveKey != nil }
        public var canTest: Bool { test != nil }

        public init(saveKey: (@MainActor (LLMConfig, String) async throws -> Void)? = nil,
                    test: (@MainActor (LLMConfig) async throws -> Void)? = nil) {
            self.saveKey = saveKey
            self.test = test
        }
    }

    public let connection: Binding<Connection>
    public let companion: Binding<Companion>
    public let connectionActions: ConnectionActions
    private let windowClosed: AnyPublisher<Void, Never>
    @State private var apiKey = ""
    @State private var status: String?
    @State private var pending: UUID?
    @State private var operation: Task<Void, Never>?

    public init(connection: Binding<Connection>, companion: Binding<Companion>,
                connectionActions: ConnectionActions = .init(),
                windowClosed: AnyPublisher<Void, Never> = Empty(completeImmediately: false).eraseToAnyPublisher()) {
        self.connection = connection
        self.companion = companion
        self.connectionActions = connectionActions
        self.windowClosed = windowClosed
    }

    public var body: some View {
        Form {
            connectionSection
            companionSection
        }
        .formStyle(.grouped)
        .onReceive(windowClosed) { resetConnectionAction(clearKey: true) }
        .onChange(of: connection.wrappedValue) { oldValue, newValue in
            let endpointChanged = oldValue.provider != newValue.provider || oldValue.baseURL != newValue.baseURL
            resetConnectionAction(clearKey: endpointChanged)
        }
        .onDisappear {
            resetConnectionAction(clearKey: true)
        }
    }

    private var connectionSection: some View {
        Section("AI 连接") {
            Picker("Provider", selection: connection.provider) {
                Text("本地模式").tag(LLMProvider.local)
                Text("OpenAI 兼容").tag(LLMProvider.openAICompatible)
                Text("Anthropic (Claude)").tag(LLMProvider.anthropic)
            }
            .accessibilityIdentifier("settings.provider")

            LabeledContent("Base URL") {
                HStack(spacing: 8) {
                    TextField("Base URL", text: connection.baseURL, prompt: Text(baseURLPrompt))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("settings.base-url")
                    Menu("预设") {
                        ForEach(Preset.allCases, id: \.self) { preset in
                            Button(preset.rawValue) { connection.wrappedValue = preset.connection }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("settings.presets")
                }
            }

            TextField("Model", text: connection.model, prompt: Text(modelPrompt))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .accessibilityIdentifier("settings.model")

            SecureField("API Key", text: $apiKey, prompt: Text("仅存于本机 Keychain"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .disabled(!connectionActions.canSaveKey || connection.provider.wrappedValue == .local)
                .accessibilityIdentifier("settings.api-key")

            HStack(spacing: 8) {
                if connectionActions.canSaveKey {
                    Button("保存密钥", action: saveKey).disabled(pending != nil || apiKey.isEmpty || connection.wrappedValue.configuration == nil)
                        .accessibilityIdentifier("settings.save-key")
                }
                Button("测试连接", action: testConnection)
                    .disabled(pending != nil || !connectionActions.canTest || connection.wrappedValue.configuration == nil)
                    .accessibilityIdentifier("settings.test-connection")
                if let status = status ?? unavailableStatus {
                    Text(status).foregroundStyle(.secondary).font(.caption).accessibilityIdentifier("settings.connection-status")
                }
            }
        }
    }

    private var companionSection: some View {
        Section {
            Picker("缩放比例", selection: companion.scale) {
                Text("0.8×").tag(0.8)
                Text("1.0×").tag(1.0)
                Text("1.25×").tag(1.25)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.scale")

            Toggle("静音播报", isOn: companion.isSpeechMuted)
                .accessibilityIdentifier("settings.mute")

            Picker("健康提醒间隔", selection: companion.healthReminderMinutes) {
                Text("关闭").tag(0)
                Text("30 分钟").tag(30)
                Text("45 分钟").tag(45)
                Text("60 分钟").tag(60)
            }
            .accessibilityIdentifier("settings.reminder")

            Toggle("敲键陪伴", isOn: companion.isTypingCompanionEnabled)
                .accessibilityIdentifier("settings.typing")
        } header: {
            Text("陪伴与外观")
        } footer: {
            Text("敲键陪伴只用按键次数，不读取键入内容。")
        }
    }

    private var baseURLPrompt: String {
        connection.provider.wrappedValue == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
    }

    private var modelPrompt: String {
        if connection.provider.wrappedValue == .anthropic { return "claude-haiku-4-5" }
        if connection.baseURL.wrappedValue == Preset.ollama.connection.baseURL { return "输入已安装的模型名" }
        return "gpt-4o-mini / deepseek-chat"
    }

    private var unavailableStatus: String? {
        switch (connectionActions.canSaveKey, connectionActions.canTest) {
        case (false, false): "密钥保存与连接测试暂未接入"
        case (false, true): "密钥保存暂未接入"
        case (true, false): "连接测试暂未接入"
        case (true, true): nil
        }
    }

    private func saveKey() {
        guard let save = connectionActions.saveKey, let config = connection.wrappedValue.configuration, !apiKey.isEmpty else { return }
        let credential = apiKey
        apiKey = ""
        runConnectionAction(success: "密钥已存入本机 Keychain", failure: "无法保存密钥") {
            try await save(config, credential)
        }
    }

    private func testConnection() {
        guard let test = connectionActions.test, let config = connection.wrappedValue.configuration else { return }
        runConnectionAction(success: "连接成功", failure: "连接失败，请检查地址、模型和密钥") {
            try await test(config)
        }
    }

    private func runConnectionAction(success: String, failure: String, action: @escaping @MainActor () async throws -> Void) {
        guard pending == nil else { return }
        let id = UUID()
        let selection = connection.wrappedValue
        pending = id
        status = "正在处理…"
        operation = Task { @MainActor in
            let message: String
            do {
                try await action()
                message = success
            } catch let error as LLMClientError {
                message = Self.message(for: error)
            } catch {
                message = failure
            }
            guard pending == id, connection.wrappedValue == selection else { return }
            status = message
            pending = nil
            operation = nil
        }
    }

    private func resetConnectionAction(clearKey: Bool) {
        pending = nil
        operation?.cancel()
        operation = nil
        status = nil
        if clearKey { apiKey = "" }
    }

    public static func message(for error: LLMClientError) -> String {
        switch error {
        case .missingAPIKey: "请先为此服务地址保存密钥"
        case .credentialUnavailable: "无法读取本机钥匙串"
        case .unauthorized: "认证失败（401），请检查此地址的密钥"
        case .rateLimited: "请求过于频繁（429），请稍后再试"
        case .network: "无法连接服务，请检查地址和网络"
        case .timedOut: "连接超时，请稍后再试"
        case .invalidResponse: "服务返回了异常响应"
        case .invalidConfiguration: "请检查服务地址、模型和密钥格式"
        case .httpStatus(let code): "服务返回错误（\(code)）"
        }
    }
}
