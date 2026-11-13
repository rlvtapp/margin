import Foundation

/// Claude, through Anthropic's Messages API with the person's own key.
public struct AnthropicModel: MailLanguageModel {
    public let apiKey: String
    public let model: String
    public var attribution: String { String(localized: "by Claude", comment: "Who wrote an assistant answer: a server or provider name") }
    public var transcriptBudget: Int { 60_000 }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let modelsEndpoint = URL(string: "https://api.anthropic.com/v1/models")!
    static let apiVersion = "2026-10-21"
    /// Models that accept server-side fallback in its `"default"` form: when the model
    /// declines on safety grounds, Anthropic retries on a model it picks for that case.
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func summary(_ request: ModelRequest) async throws -> ThreadSummary {
        try AnswerSchema.decodeSummary(try await fetchJSON(request))
    }

    public func labels(_ request: ModelRequest) async throws -> [String] {
        try AnswerSchema.decodeLabels(try await fetchJSON(request))
    }

    public func reply(_ request: ModelRequest) async throws -> String {
        try AnswerSchema.decodeReply(try await fetchJSON(request))
    }

    public func answer(_ request: ModelRequest) async throws -> MailAnswer {
        try AnswerSchema.decodeAnswer(try await fetchJSON(request))
    }

    /// Streams the answer: text deltas arrive as server-sent events, and the `answer` field
    /// of the JSON is read out of what has arrived so far.
    public func answer(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> MailAnswer {
        try AnswerSchema.decodeAnswer(Data(try await stream(request, key: "answer", partial: partial).utf8))
    }

    /// Streams a draft the same way, its `body` shown as it's written.
    public func reply(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        try AnswerSchema.decodeReply(Data(try await stream(request, key: "body", partial: partial).utf8))
    }

    /// The whole JSON answer, with the text of `key` handed over as it arrives.
    private func stream(_ request: ModelRequest, key: String, partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        var http = try makeRequest(request)
        var body = (try JSONSerialization.jsonObject(with: http.httpBody ?? Data()) as? [String: Any]) ?? [:]
        body["stream"] = true
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (bytes, response) = try await URLSession.shared.bytes(for: http)
        try await StreamedAnswer.checkStatus(response, bytes)
        var reader = StreamedAnswer(partial: partial, key: key)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let event = StreamedAnswer.json(line) else { continue }
            switch event["type"] as? String {
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { await reader.add(text) }
            case "message_delta":
                if (event["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { throw AssistantError.refused }
            case "error":
                let error = event["error"] as? [String: Any]
                throw AssistantError.badResponse(error?["message"] as? String ?? String(localized: "The answer stopped."))
            default: break
            }
        }
        return reader.text
    }

    private func fetchJSON(_ request: ModelRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: try makeRequest(request))
        try HTTPCheck.ok(response, data)
        return try Self.answerText(from: data)
    }

    func makeRequest(_ request: ModelRequest) throws -> URLRequest {
        var http = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        http.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "system": request.instructions,
            "messages": [["role": "user", "content": request.prompt]],
            // Short, well-defined tasks: low effort keeps them quick; the schema keeps the answer readable.
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": AnswerSchema.schema(for: request.task)]],
        ]
        if Self.fallbackModels.contains(model) {
            http.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return http
    }

    /// The JSON text of the answer: the text blocks joined (thinking blocks skipped).
    static func answerText(from data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.badResponse(String(localized: "Not JSON."))
        }
        if object["stop_reason"] as? String == "refusal" { throw AssistantError.refused }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AssistantError.badResponse(String(localized: "No text in the answer.")) }
        return Data(text.utf8)
    }

    /// Model ids the key can use, newest first as the API lists them.
    public static func availableModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: modelsEndpoint.appending(queryItems: [URLQueryItem(name: "limit", value: "100")]), timeoutInterval: 30)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPCheck.ok(response, data)
        return HTTPCheck.ids(in: data)
    }
}

/// ChatGPT, Ollama, LM Studio and any server that speaks the OpenAI chat API.
public struct OpenAICompatibleModel: MailLanguageModel {
    public let baseURL: URL
    public let apiKey: String?
    public let model: String
    public let attribution: String
    /// Local models have small context windows and run on this machine's memory.
    public let isLocal: Bool
    public var transcriptBudget: Int { isLocal ? 12_000 : 60_000 }

    public init(baseURL: URL, apiKey: String?, model: String, attribution: String, isLocal: Bool) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.attribution = attribution
        self.isLocal = isLocal
    }

    public func summary(_ request: ModelRequest) async throws -> ThreadSummary {
        try AnswerSchema.decodeSummary(try await fetchJSON(request))
    }

    public func labels(_ request: ModelRequest) async throws -> [String] {
        try AnswerSchema.decodeLabels(try await fetchJSON(request))
    }

    public func reply(_ request: ModelRequest) async throws -> String {
        try AnswerSchema.decodeReply(try await fetchJSON(request))
    }

    public func answer(_ request: ModelRequest) async throws -> MailAnswer {
        try AnswerSchema.decodeAnswer(try await fetchJSON(request))
    }

    /// Streams the answer as chat-completion chunks; servers without schema support get
    /// plain JSON mode, as in `fetchJSON`.
    public func answer(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> MailAnswer {
        try AnswerSchema.decodeAnswer(Data(try await stream(request, key: "answer", partial: partial).utf8))
    }

    /// Streams a draft the same way, its `body` shown as it's written.
    public func reply(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        try AnswerSchema.decodeReply(Data(try await stream(request, key: "body", partial: partial).utf8))
    }

    private func stream(_ request: ModelRequest, key: String, partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        func streaming(strict: Bool) throws -> URLRequest {
            var http = try makeRequest(request, strictSchema: strict)
            var body = (try JSONSerialization.jsonObject(with: http.httpBody ?? Data()) as? [String: Any]) ?? [:]
            body["stream"] = true
            http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return http
        }
        var (bytes, response) = try await URLSession.shared.bytes(for: try streaming(strict: true))
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 422 {
            (bytes, response) = try await URLSession.shared.bytes(for: try streaming(strict: false))
        }
        try await StreamedAnswer.checkStatus(response, bytes)
        var reader = StreamedAnswer(partial: partial, key: key)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let event = StreamedAnswer.json(line),
                  let delta = (event["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw AssistantError.refused }
            if let text = delta["content"] as? String { await reader.add(text) }
        }
        guard !reader.text.isEmpty else { throw AssistantError.badResponse(String(localized: "The answer was empty.")) }
        return reader.text
    }

    /// Asks for schema-constrained JSON; servers that don't support schemas (some local
    /// ones) get plain JSON mode with the schema spelled out in the instructions.
    private func fetchJSON(_ request: ModelRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: try makeRequest(request, strictSchema: true))
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 422 {
            let (retryData, retryResponse) = try await URLSession.shared.data(for: try makeRequest(request, strictSchema: false))
            try HTTPCheck.ok(retryResponse, retryData)
            return try Self.answerText(from: retryData)
        }
        try HTTPCheck.ok(response, data)
        return try Self.answerText(from: data)
    }

    func makeRequest(_ request: ModelRequest, strictSchema: Bool) throws -> URLRequest {
        var http = URLRequest(url: baseURL.appending(path: "chat/completions"), timeoutInterval: isLocal ? 300 : 120)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let schema = AnswerSchema.schema(for: request.task)
        var system = request.instructions
        let format: [String: Any]
        if strictSchema {
            format = ["type": "json_schema", "json_schema": ["name": request.task.rawValue, "strict": true, "schema": schema]]
        } else {
            let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
            system += "\n\nAnswer with one JSON object that matches this JSON Schema and nothing else:\n\(schemaText)"
            format = ["type": "json_object"]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": request.prompt]],
            "response_format": format,
        ]
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return http
    }

    static func answerText(from data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw AssistantError.badResponse(String(localized: "No answer in the response."))
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AssistantError.refused }
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw AssistantError.badResponse(String(localized: "The answer was empty."))
        }
        return Data(content.utf8)
    }

    public static func availableModels(baseURL: URL, apiKey: String?) async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "models"), timeoutInterval: 15)
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPCheck.ok(response, data)
        return HTTPCheck.ids(in: data).sorted()
    }
}

enum HTTPCheck {
    static func ok(_ response: URLResponse, _ data: Data) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) else { return }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let message = (error?["message"] as? String) ?? (object?["error"] as? String) ?? ""
        throw AssistantError.http(status, message)
    }

    /// `{"data": [{"id": …}]}`, the shape both APIs use for model lists.
    static func ids(in data: Data) -> [String] {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

/// Collects a streamed JSON answer and passes on its `answer` text whenever it grows.
struct StreamedAnswer {
    let partial: @Sendable (String) async -> Void
    /// The JSON field being written out: "answer" for Ask, "body" for a draft.
    var key = "answer"
    private(set) var text = ""
    private var shown = ""

    init(partial: @escaping @Sendable (String) async -> Void, key: String = "answer") {
        self.partial = partial
        self.key = key
    }

    mutating func add(_ delta: String) async {
        text += delta
        guard let answer = Self.answerSoFar(in: text, key: key), answer != shown else { return }
        shown = answer
        await partial(answer)
    }

    /// The `"answer"` string of a JSON object that may still be cut off part-way, with escapes
    /// read; nil until its opening quote has arrived.
    static func answerSoFar(in json: String, key name: String = "answer") -> String? {
        guard let key = json.range(of: "\"\(name)\"") else { return nil }
        let rest = Array(json[key.upperBound...].unicodeScalars)
        var i = 0
        while i < rest.count, rest[i] == " " || rest[i] == ":" || rest[i] == "\n" || rest[i] == "\t" { i += 1 }
        guard i < rest.count, rest[i] == "\"" else { return nil }
        i += 1
        var result = String.UnicodeScalarView()
        while i < rest.count {
            let scalar = rest[i]
            if scalar == "\"" { break }
            guard scalar == "\\" else { result.append(scalar); i += 1; continue }
            // An escape; stop at one that hasn't fully arrived yet.
            guard i + 1 < rest.count else { break }
            switch rest[i + 1] {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r", "b", "f": break
            case "u":
                guard i + 5 < rest.count, let code = UInt32(String(String.UnicodeScalarView(rest[(i + 2)...(i + 5)])), radix: 16) else {
                    return String(result)
                }
                if let decoded = Unicode.Scalar(code) { result.append(decoded) }
                i += 6
                continue
            default: result.append(rest[i + 1])
            }
            i += 2
        }
        return String(result)
    }

    static func json(_ line: String) -> [String: Any]? {
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    }

    /// A failed request's body is read whole, so its error message can be shown.
    static func checkStatus(_ response: URLResponse, _ bytes: URLSession.AsyncBytes) async throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) else { return }
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        try HTTPCheck.ok(response, data)
    }
}
