import Combine
import Foundation

struct AIProviderConfiguration: Equatable, Sendable {
    let baseURL: URL
    let model: String
    let apiKey: String?

    var displayHost: String { baseURL.host ?? baseURL.absoluteString }
}

enum AIServiceError: LocalizedError, Equatable, Sendable {
    case disabled
    case invalidBaseURL
    case insecureRemoteURL
    case missingModel
    case missingAPIKey
    case authentication
    case modelUnavailable
    case rateLimited
    case timeout
    case network
    case refused
    case invalidResponse
    case inputTooLong(limit: Int)
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .disabled: "请先在设置中主动启用 AI。"
        case .invalidBaseURL: "API Base URL 无效。请填写服务的 API 根地址。"
        case .insecureRemoteURL: "远程 AI 服务必须使用 HTTPS；HTTP 只允许本机地址。"
        case .missingModel: "请填写服务提供的模型名称。"
        case .missingAPIKey: "远程 AI 服务需要 API Key。"
        case .authentication: "API Key 未通过服务验证。请检查后重试。"
        case .modelUnavailable: "当前服务找不到这个模型，请检查模型名称。"
        case .rateLimited: "服务请求较多或额度受限，请稍后再试。"
        case .timeout: "AI 服务等待超时。你的原始内容仍然保留。"
        case .network: "无法连接 AI 服务，请检查网络或 Base URL。"
        case .refused: "AI 服务没有处理这项内容。你可以调整范围或改用本地流程。"
        case .invalidResponse: "AI 返回的内容不完整，未修改任何原文或任务。"
        case .inputTooLong(let limit): "本次最多发送 \(limit.formatted()) 个字符，请缩小范围。"
        case .server(let status): "AI 服务暂时不可用（HTTP \(status)）。"
        }
    }
}

nonisolated enum AIEndpointPolicy {
    static func validate(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil else {
            throw AIServiceError.invalidBaseURL
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw AIServiceError.insecureRemoteURL
        }

        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw AIServiceError.invalidBaseURL }
        return url
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

struct AIOutputSchema: Sendable {
    let name: String
    let jsonData: Data

    init(name: String, object: [String: Any]) {
        self.name = name
        self.jsonData = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

protocol AICompleting: Sendable {
    func complete(
        systemPrompt: String,
        userPrompt: String,
        schema: AIOutputSchema,
        configuration: AIProviderConfiguration
    ) async throws -> String
}

enum ReadingAIAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case simplify
    case explainTerms
    case questions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simplify: "简化句子"
        case .explainTerms: "解释术语"
        case .questions: "生成问题"
        }
    }

    var promptInstruction: String {
        switch self {
        case .simplify:
            "把内容改写成更易读的中文，不删掉重要事实。每项 heading 写“简化”，output 写简化文本。"
        case .explainTerms:
            "选择真正影响理解的术语，用简洁中文解释。heading 写术语，output 写解释。"
        case .questions:
            "生成 3 到 5 个帮助理解内容的问题。heading 写问题，output 写答案提示。"
        }
    }
}

enum ReadingAIScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case selection
    case currentSegment
    case fullDocument

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: "选中文字"
        case .currentSegment: "当前段落"
        case .fullDocument: "全文"
        }
    }
}

struct ReadingAIItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let heading: String
    let output: String
    let sourceQuote: String

    enum CodingKeys: String, CodingKey {
        case heading, output, sourceQuote
    }
}

struct ReadingAIResult: Codable, Equatable, Sendable {
    let title: String
    let items: [ReadingAIItem]
}

@MainActor
final class AISettingsStore: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Keys.baseURL) }
    }
    @Published var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    @Published var apiKeyDraft = ""
    @Published private(set) var hasStoredKey: Bool
    @Published var statusMessage: String?
    @Published var isTesting = false

    private enum Keys {
        static let enabled = "aiEnabled"
        static let baseURL = "aiBaseURL"
        static let model = "aiModel"
    }

    private let defaults: UserDefaults
    private let credentials: CredentialStoring

    init(defaults: UserDefaults, credentials: CredentialStoring) {
        self.defaults = defaults
        self.credentials = credentials
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        self.baseURL = defaults.string(forKey: Keys.baseURL) ?? "https://api.openai.com/v1"
        self.model = defaults.string(forKey: Keys.model) ?? ""
        self.hasStoredKey = (try? credentials.load())?.isEmpty == false
    }

    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try credentials.save(trimmed)
            apiKeyDraft = ""
            hasStoredKey = true
            statusMessage = "API Key 已安全保存到钥匙串。"
        } catch {
            statusMessage = "无法保存 API Key，请稍后重试。"
        }
    }

    func clearAPIKey() {
        do {
            try credentials.delete()
            apiKeyDraft = ""
            hasStoredKey = false
            statusMessage = "已从钥匙串移除 API Key。"
        } catch {
            statusMessage = "无法移除 API Key，请稍后重试。"
        }
    }

    func configuration(requireEnabled: Bool = true) throws -> AIProviderConfiguration {
        if requireEnabled, !isEnabled { throw AIServiceError.disabled }
        let url = try AIEndpointPolicy.validate(baseURL)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else { throw AIServiceError.missingModel }
        let key = try credentials.load()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !AIEndpointPolicy.isLoopback(url), key?.isEmpty != false {
            throw AIServiceError.missingAPIKey
        }
        return AIProviderConfiguration(baseURL: url, model: cleanModel, apiKey: key?.isEmpty == false ? key : nil)
    }
}
