import Foundation

/// Which model does the assistant work: Apple's model on this device, a model running on
/// this computer, or a hosted model with the person's own key. Requests go straight from
/// the app to that provider; there is no service of ours in between.
public enum AssistantProvider: String, Codable, CaseIterable, Sendable {
    case off, onDevice, ollama, lmStudio, claude, chatGPT, gemini, grok, custom

    public var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .onDevice:
            #if os(macOS)
            String(localized: "On this Mac")
            #else
            String(localized: "On this device")
            #endif
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .custom: String(localized: "Other server")
        }
    }

    /// Where mail goes, in one line, shown under the picker.
    public var privacyNote: String {
        switch self {
        case .off: String(localized: "The assistant is off.")
        case .onDevice:
            #if os(macOS)
            String(localized: "Runs on Apple's on-device model. Mail never leaves this Mac.")
            #else
            String(localized: "Runs on Apple's on-device model. Mail never leaves this device.")
            #endif
        case .ollama, .lmStudio: String(localized: "Runs on a model on this computer. Mail never leaves it.")
        case .claude: String(localized: "The conversation you ask about is sent to Anthropic with your API key. Nothing goes through Margin.")
        case .chatGPT: String(localized: "The conversation you ask about is sent to OpenAI with your API key. Nothing goes through Margin.")
        case .gemini: String(localized: "The conversation you ask about is sent to Google with your API key. Nothing goes through Margin.")
        case .grok: String(localized: "The conversation you ask about is sent to xAI with your API key. Nothing goes through Margin.")
        case .custom: String(localized: "The conversation you ask about is sent to the server below. Nothing goes through Margin.")
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .chatGPT: "https://api.openai.com/v1"
        // Both speak the same API as ChatGPT.
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .grok: "https://api.x.ai/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        default: ""
        }
    }

    /// The model picked before the person chooses one. Other providers list their own.
    public var defaultModel: String {
        self == .claude ? "claude-opus-5-5" : ""
    }

    public var needsKey: Bool { [.claude, .chatGPT, .gemini, .grok].contains(self) }
    public var acceptsKey: Bool { needsKey || self == .custom }
    public var hasServerURL: Bool { self == .ollama || self == .lmStudio || self == .custom }
    public var keychainKey: String { "assistant.\(rawValue)" }
}

public struct AssistantSettings: Codable, Equatable, Sendable {
    public var provider: AssistantProvider
    public var model: String
    public var baseURL: String

    public init(provider: AssistantProvider, model: String? = nil, baseURL: String? = nil) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.baseURL = baseURL ?? provider.defaultBaseURL
    }

    /// The on-device model when this device has one, otherwise off.
    public static var initial: AssistantSettings {
        AssistantSettings(provider: OnDeviceModel.isAvailable ? .onDevice : .off)
    }

    /// A ready model, or nil when the settings are incomplete.
    public func makeModel(apiKey: String?) -> (any MailLanguageModel)? {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .off:
            return nil
        case .onDevice:
            return OnDeviceModel.make()
        case .claude:
            guard let key, !key.isEmpty, !model.isEmpty else { return nil }
            return AnthropicModel(apiKey: key, model: model)
        case .chatGPT, .gemini, .grok, .ollama, .lmStudio, .custom:
            guard let url = URL(string: baseURL), !model.isEmpty else { return nil }
            if provider.needsKey && (key ?? "").isEmpty { return nil }
            return OpenAICompatibleModel(
                baseURL: url, apiKey: key?.isEmpty == false ? key : nil, model: model,
                attribution: provider == .custom
                    ? String(localized: "by \(url.host() ?? String(localized: "your server"))", comment: "Who wrote an assistant answer: a server or provider name")
                    : String(localized: "by \(provider.title)", comment: "Who wrote an assistant answer: a server or provider name"),
                isLocal: ["localhost", "127.0.0.1", "::1"].contains(url.host() ?? "")
            )
        }
    }
}

public enum AssistantError: LocalizedError, Equatable, Sendable {
    case unavailable
    case refused
    case badResponse(String)
    case http(Int, String)
    /// Apple's on-device model failed; the detail is shown in plain words.
    case onDevice(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "The assistant isn't available right now.")
        case .onDevice(let detail): detail
        case .refused: String(localized: "The model declined to help with this conversation.")
        case .badResponse(let detail): String(localized: "The model's answer couldn't be read. \(detail)")
        case .http(401, _), .http(403, _): String(localized: "The API key was refused. Check it in Settings → Assistant.")
        case .http(429, _): String(localized: "The provider is rate-limiting requests. Try again in a moment.")
        case .http(let code, let message): String(localized: "The provider returned an error (\(code)). \(message)")
        }
    }
}

/// JSON Schemas for the three answers, shared by every hosted provider.
enum AnswerSchema {
    static func schema(for task: ModelRequest.Task) -> [String: Any] {
        switch task {
        case .summary:
            object([
                "headline": ["type": "string", "description": "One sentence: what this is about and where it stands."],
                "points": ["type": "array", "items": ["type": "string"], "description": "Up to four short facts worth knowing."],
                "action": ["type": "string", "description": "What the reader is asked to do, or an empty string."],
            ])
        case .labels:
            object(["labels": ["type": "array", "items": ["type": "string"], "description": "Zero to three labels of one or two words."]])
        case .reply:
            object(["body": ["type": "string", "description": "The email body only."]])
        case .answer:
            object([
                "answer": ["type": "string", "description": "The answer, briefly."],
                "sources": ["type": "array", "items": ["type": "integer"], "description": "Numbers of the conversations used."],
            ])
        }
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    /// Reads a JSON answer into the result types.
    static func decodeSummary(_ data: Data) throws -> ThreadSummary {
        struct Raw: Decodable { var headline: String; var points: [String]?; var action: String? }
        let raw = try decode(Raw.self, data)
        return ThreadSummary(headline: raw.headline, points: raw.points ?? [], action: raw.action)
    }

    static func decodeLabels(_ data: Data) throws -> [String] {
        struct Raw: Decodable { var labels: [String] }
        return try decode(Raw.self, data).labels
    }

    static func decodeAnswer(_ data: Data) throws -> MailAnswer {
        struct Raw: Decodable { var answer: String; var sources: [Int]? }
        let raw = try decode(Raw.self, data)
        return MailAnswer(text: raw.answer, sources: raw.sources ?? [])
    }

    static func decodeReply(_ data: Data) throws -> String {
        struct Raw: Decodable { var body: String }
        return try decode(Raw.self, data).body
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Some local models wrap JSON in prose or a code fence; take the outermost object.
            let text = String(decoding: data, as: UTF8.self)
            if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
               let value = try? JSONDecoder().decode(type, from: Data(text[start...end].utf8)) {
                return value
            }
            throw AssistantError.badResponse(String(text.prefix(120)))
        }
    }
}
