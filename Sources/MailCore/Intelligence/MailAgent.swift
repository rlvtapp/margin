import Foundation

// The assistant taking actions: the person asks ("Sort my mail"), the model picks tools, Margin
// runs them and sends back what happened, until the model answers in words. The tools are the
// same ones AI apps get over MCP (`MCPTool`, `MCPValue`), so their schemas, handlers and
// permission switches are shared; this file only carries them to each provider in its own
// format and back.

/// One tool call the model asked for.
public struct AgentToolCall: Sendable, Equatable {
    /// The provider's id for the call, used to match the result to it.
    public var id: String
    public var name: String
    public var arguments: [String: MCPValue]
    /// Set when the arguments couldn't be read (cut off, not JSON). The call isn't run; the
    /// model is told why instead.
    public var problem: String?

    public init(id: String, name: String, arguments: [String: MCPValue], problem: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.problem = problem
    }
}

/// What a tool answered, as text (usually JSON).
public struct AgentToolResult: Sendable, Equatable {
    public var callID: String
    public var name: String
    public var text: String
    public var isError: Bool

    public init(callID: String, name: String, text: String, isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.text = text
        self.isError = isError
    }
}

/// One answer from the model: words, tool calls, or both.
public struct AgentTurn: Sendable, Equatable {
    public var text: String
    public var calls: [AgentToolCall]
    /// The provider's own message as JSON, sent back unchanged on the next step: it carries what
    /// the provider needs to continue (thinking blocks, thought signatures, call ids).
    public var native: Data?

    public init(text: String, calls: [AgentToolCall], native: Data? = nil) {
        self.text = text
        self.calls = calls
        self.native = native
    }
}

/// The conversation so far, in order.
public enum AgentEntry: Sendable, Equatable {
    case request(String)
    case turn(AgentTurn)
    case results([AgentToolResult])
}

/// How a run ended.
public struct AgentOutcome: Sendable, Equatable {
    /// The model's closing words.
    public var text: String
    /// How many tool calls ran.
    public var toolCalls: Int
    /// True when it stopped at the step limit rather than finishing.
    public var reachedLimit: Bool

    public init(text: String, toolCalls: Int, reachedLimit: Bool) {
        self.text = text
        self.toolCalls = toolCalls
        self.reachedLimit = reachedLimit
    }
}

/// Runs one tool call and returns its result. The app supplies it; it never throws: errors go
/// back to the model as error results so it can try another way.
public typealias AgentToolRunner = @Sendable (AgentToolCall) async -> AgentToolResult

/// A model that can take actions with tools.
public protocol MailAgentModel: Sendable {
    /// "by Claude", "on this Mac".
    var attribution: String { get }
    /// Small context windows (the on-device model) get fewer tools and shorter results.
    var isCompact: Bool { get }
    /// Characters of one tool result the model is sent; longer ones are cut.
    var resultBudget: Int { get }
    func run(instructions: String, request: String, tools: [MCPTool], maxSteps: Int,
             perform: @escaping AgentToolRunner) async throws -> AgentOutcome
    /// Asks the model to call a harmless tool: true when it does, false when the server refuses
    /// tools or the model answers without calling one. Throws when the server can't be reached.
    func checkActions() async throws -> Bool
}

/// A model reached one request at a time: give it the conversation, get its next turn. The loop
/// around it (`AgentLoop`) is shared by every hosted and local provider.
public protocol AgentStepModel: MailAgentModel {
    func next(instructions: String, entries: [AgentEntry], tools: [MCPTool]) async throws -> AgentTurn
}

extension AgentStepModel {
    public var isCompact: Bool { false }

    public func checkActions() async throws -> Bool {
        let probe = AgentLoop.probeTool
        do {
            let turn = try await next(instructions: "You can call tools. When asked to, call the tool and say nothing else.",
                                      entries: [.request("Call the \(probe.name) tool now.")], tools: [probe])
            return turn.calls.contains { $0.name == probe.name }
        } catch AssistantError.toolsUnsupported {
            return false
        }
    }

    public func run(instructions: String, request: String, tools: [MCPTool], maxSteps: Int,
                    perform: @escaping AgentToolRunner) async throws -> AgentOutcome {
        try await AgentLoop.run(self, instructions: instructions, request: request, tools: tools,
                                maxSteps: maxSteps, perform: perform)
    }
}

public enum AgentLoop {
    /// What `checkActions` asks the model to call.
    static let probeTool = MCPTool(name: "check_connection", description: "Confirms that tools work. Call it when asked to.",
                                   inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#)

    /// Asks, runs the tools it calls, sends back the results, and repeats until the model
    /// answers without calling a tool or `maxSteps` requests have been made. Stops between
    /// steps and between tool calls when the task is cancelled.
    public static func run(_ model: some AgentStepModel, instructions: String, request: String, tools: [MCPTool],
                           maxSteps: Int, perform: AgentToolRunner) async throws -> AgentOutcome {
        var entries: [AgentEntry] = [.request(request)]
        var calls = 0
        var lastText = ""
        for _ in 0..<max(maxSteps, 1) {
            try Task.checkCancellation()
            let turn = try await model.next(instructions: instructions, entries: entries, tools: tools)
            entries.append(.turn(turn))
            if !turn.text.isEmpty { lastText = turn.text }
            if turn.calls.isEmpty {
                return AgentOutcome(text: turn.text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls, reachedLimit: false)
            }
            var results: [AgentToolResult] = []
            for call in turn.calls {
                try Task.checkCancellation()
                if let problem = call.problem {
                    results.append(AgentToolResult(callID: call.id, name: call.name, text: problem, isError: true))
                    continue
                }
                var result = await perform(call)
                result.callID = call.id
                result.name = call.name
                result.text = trimmed(result.text, to: model.resultBudget)
                results.append(result)
                calls += 1
            }
            entries.append(.results(results))
        }
        return AgentOutcome(text: lastText.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls, reachedLimit: true)
    }

    /// A long result, cut with a note the model can act on.
    public static func trimmed(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        return String(text.prefix(budget)) + "\n… (cut short: ask for fewer with limit, or page with offset)"
    }

    /// Tool arguments from JSON text; nil when it isn't a JSON object.
    static func arguments(fromJSON text: String) -> [String: MCPValue]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else { return nil }
        return object.mapValues(MCPValue.init)
    }

    /// A tool's JSON Schema as an object; an empty object schema when it can't be read.
    static func schema(_ tool: MCPTool) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)) as? [String: Any])
            ?? ["type": "object", "properties": [String: Any]()]
    }

    static func json(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

extension MCPValue {
    /// Back to plain JSON values, for request bodies.
    public var any: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value as Any
        case .bool(let value): value
        case .null: NSNull()
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }
}

// MARK: - Providers

extension AssistantProvider {
    /// Whether a provider can take actions (call tools).
    public enum ActionSupport: Sendable { case yes, dependsOnModel, no }

    /// The hosted providers and Apple's model support tool calling. Local and other servers
    /// depend on the server and the model, so Margin checks (or finds out on the first try).
    public var actionSupport: ActionSupport {
        switch self {
        case .off: .no
        case .onDevice, .claude, .chatGPT, .gemini, .grok: .yes
        case .ollama, .lmStudio, .custom: .dependsOnModel
        }
    }

    /// The order Automatic picks a provider for actions in: hosted ones first, since actions
    /// over a whole inbox need a large context and many steps; Apple's on-device model last.
    public static let actionOrder: [AssistantProvider] = [.claude, .chatGPT, .gemini, .grok, .custom, .lmStudio, .ollama, .onDevice]
}

extension AssistantSettings {
    /// Identifies this setup for remembering whether it can take actions.
    public var actionKey: String { "\(provider.rawValue)|\(baseURL)|\(model)" }

    /// The provider's name for messages ("Grok", or the server's address for Other server).
    public var displayName: String {
        provider == .custom ? (URL(string: baseURL)?.host() ?? provider.title) : provider.title
    }
}

extension AssistantSettings {
    /// The chosen provider, ready to take actions, or nil when it's off or incomplete. Keys come
    /// from the Keychain, as for every other assistant request.
    public func makeAgent(apiKey: String?) -> (any MailAgentModel)? {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .off:
            return nil
        case .onDevice:
            return OnDeviceModel.makeAgent()
        case .claude:
            guard let key, !key.isEmpty, !model.isEmpty else { return nil }
            return AnthropicAgent(apiKey: key, model: model)
        case .gemini:
            guard let key, !key.isEmpty, !model.isEmpty else { return nil }
            return GeminiAgent(apiKey: key, model: model, baseURL: GeminiAgent.nativeBase(from: baseURL))
        case .chatGPT, .grok, .ollama, .lmStudio, .custom:
            guard let url = URL(string: baseURL), !model.isEmpty else { return nil }
            if provider.needsKey && (key ?? "").isEmpty { return nil }
            let isLocal = ["localhost", "127.0.0.1", "::1"].contains(url.host() ?? "")
            return OpenAIChatAgent(
                baseURL: url, apiKey: key?.isEmpty == false ? key : nil, model: model, name: displayName,
                attribution: provider == .custom
                    ? String(localized: "by \(url.host() ?? String(localized: "your server"))", comment: "Who wrote an assistant answer: a server or provider name")
                    : String(localized: "by \(provider.title)", comment: "Who wrote an assistant answer: a server or provider name"),
                isLocal: isLocal
            )
        }
    }
}

/// Claude, through the Messages API: `tools` with `input_schema`, `tool_use` blocks in the
/// answer, `tool_result` blocks sent back in one user message.
public struct AnthropicAgent: AgentStepModel {
    public let apiKey: String
    public let model: String
    public var attribution: String { String(localized: "by Claude", comment: "Who wrote an assistant answer: a server or provider name") }
    public var resultBudget: Int { 40_000 }
    var session: URLSession = .shared

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func next(instructions: String, entries: [AgentEntry], tools: [MCPTool]) async throws -> AgentTurn {
        let (data, response) = try await session.data(for: try makeRequest(instructions: instructions, entries: entries, tools: tools))
        try HTTPCheck.ok(response, data)
        return try Self.turn(from: data)
    }

    func makeRequest(instructions: String, entries: [AgentEntry], tools: [MCPTool]) throws -> URLRequest {
        var http = URLRequest(url: AnthropicModel.endpoint, timeoutInterval: 180)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        http.setValue(AnthropicModel.apiVersion, forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "system": instructions,
            "messages": Self.messages(entries),
            "tools": tools.map { ["name": $0.name, "description": $0.description, "input_schema": AgentLoop.schema($0)] as [String: Any] },
            "output_config": ["effort": "medium"],
        ]
        if AnthropicModel.fallbackModels.contains(model) {
            http.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return http
    }

    static func messages(_ entries: [AgentEntry]) -> [[String: Any]] {
        entries.map { entry -> [String: Any] in
            switch entry {
            case .request(let text):
                return ["role": "user", "content": text]
            case .turn(let turn):
                // The answer's content blocks exactly as they came, thinking blocks included.
                if let native = AgentLoop.json(turn.native) { return native }
                var blocks: [[String: Any]] = turn.text.isEmpty ? [] : [["type": "text", "text": turn.text]]
                blocks += turn.calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.arguments.mapValues(\.any)] }
                return ["role": "assistant", "content": blocks]
            case .results(let results):
                return ["role": "user", "content": results.map { result -> [String: Any] in
                    var block: [String: Any] = ["type": "tool_result", "tool_use_id": result.callID, "content": result.text]
                    if result.isError { block["is_error"] = true }
                    return block
                }]
            }
        }
    }

    static func turn(from data: Data) throws -> AgentTurn {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.badResponse(String(localized: "Not JSON."))
        }
        let stop = object["stop_reason"] as? String
        if stop == "refusal" { throw AssistantError.refused }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let calls = blocks.filter { $0["type"] as? String == "tool_use" }.map { block -> AgentToolCall in
            let input = (block["input"] as? [String: Any] ?? [:]).mapValues(MCPValue.init)
            return AgentToolCall(
                id: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "", arguments: input,
                // A call cut off by max_tokens may still parse; it isn't run.
                problem: stop == "max_tokens" ? "This call was cut off before its arguments were complete. Make it again, smaller." : nil
            )
        }
        let native = try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": blocks], options: [.sortedKeys])
        return AgentTurn(text: text, calls: calls, native: native)
    }
}

/// ChatGPT, Grok, Ollama, LM Studio and other servers with the OpenAI chat API: `tools` of
/// type function, `tool_calls` in the answer, one `tool` message per result.
public struct OpenAIChatAgent: AgentStepModel {
    public let baseURL: URL
    public let apiKey: String?
    public let model: String
    public let attribution: String
    public let isLocal: Bool
    /// "LM Studio", for "LM Studio can answer questions but can't take actions."
    public let name: String
    public var resultBudget: Int { isLocal ? 12_000 : 40_000 }
    var session: URLSession = .shared

    public init(baseURL: URL, apiKey: String?, model: String, name: String = "", attribution: String, isLocal: Bool) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.name = name.isEmpty ? (baseURL.host() ?? "") : name
        self.attribution = attribution
        self.isLocal = isLocal
    }

    public func next(instructions: String, entries: [AgentEntry], tools: [MCPTool]) async throws -> AgentTurn {
        let (data, response) = try await session.data(for: try makeRequest(instructions: instructions, entries: entries, tools: tools))
        do {
            try HTTPCheck.ok(response, data)
        } catch AssistantError.http(let status, let message) where Self.refusesTools(status: status, message: message) {
            throw AssistantError.toolsUnsupported(name)
        }
        return try Self.turn(from: data)
    }

    /// Servers and models without tool calling say so in their error ("does not support
    /// tools", "tool choice requires --enable-auto-tool-choice", "tools param requires --jinja").
    static func refusesTools(status: Int, message: String) -> Bool {
        guard [400, 404, 422, 500, 501].contains(status) else { return false }
        let text = message.lowercased()
        return status == 501 || text.contains("tool") || text.contains("function")
    }

    func makeRequest(instructions: String, entries: [AgentEntry], tools: [MCPTool]) throws -> URLRequest {
        var http = URLRequest(url: baseURL.appending(path: "chat/completions"), timeoutInterval: isLocal ? 300 : 180)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": instructions]] + Self.messages(entries),
            "tools": tools.map { tool -> [String: Any] in
                ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": AgentLoop.schema(tool)] as [String: Any]]
            },
            "tool_choice": "auto",
        ]
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return http
    }

    static func messages(_ entries: [AgentEntry]) -> [[String: Any]] {
        entries.flatMap { entry -> [[String: Any]] in
            switch entry {
            case .request(let text):
                return [["role": "user", "content": text]]
            case .turn(let turn):
                if let native = AgentLoop.json(turn.native) { return [native] }
                var message: [String: Any] = ["role": "assistant", "content": turn.text]
                if !turn.calls.isEmpty { message["tool_calls"] = turn.calls.map(Self.callJSON) }
                return [message]
            case .results(let results):
                return results.map { ["role": "tool", "tool_call_id": $0.callID, "content": $0.isError ? "Error: \($0.text)" : $0.text] }
            }
        }
    }

    static func callJSON(_ call: AgentToolCall) -> [String: Any] {
        let arguments = (try? JSONSerialization.data(withJSONObject: call.arguments.mapValues(\.any), options: [.sortedKeys])) ?? Data("{}".utf8)
        return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": String(decoding: arguments, as: UTF8.self)]]
    }

    static func turn(from data: Data) throws -> AgentTurn {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw AssistantError.badResponse(String(localized: "No answer in the response."))
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AssistantError.refused }
        let text = message["content"] as? String ?? ""
        let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []
        var echoed: [[String: Any]] = []
        let calls = rawCalls.enumerated().map { index, raw -> AgentToolCall in
            let function = raw["function"] as? [String: Any] ?? [:]
            let id = (raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)"
            let name = function["name"] as? String ?? ""
            // Most servers send the arguments as JSON text; some local ones send the object.
            let argumentText: String
            let arguments: [String: MCPValue]?
            if let object = function["arguments"] as? [String: Any] {
                arguments = object.mapValues(MCPValue.init)
                argumentText = String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
            } else {
                argumentText = function["arguments"] as? String ?? ""
                arguments = AgentLoop.arguments(fromJSON: argumentText)
            }
            echoed.append(["id": id, "type": "function", "function": ["name": name, "arguments": argumentText.isEmpty ? "{}" : argumentText]])
            return AgentToolCall(id: id, name: name, arguments: arguments ?? [:],
                                 problem: arguments == nil ? "The arguments weren't valid JSON. Make the call again with a JSON object." : nil)
        }
        // Sent back as the server needs it: the text and the calls, with their original arguments.
        var native: [String: Any] = ["role": "assistant", "content": text]
        if !echoed.isEmpty { native["tool_calls"] = echoed }
        if text.isEmpty && calls.isEmpty, choice["finish_reason"] as? String == "content_filter" { throw AssistantError.refused }
        return AgentTurn(text: text, calls: calls, native: try JSONSerialization.data(withJSONObject: native, options: [.sortedKeys]))
    }
}

/// Gemini, through its own generateContent API: `functionDeclarations` with
/// `parametersJsonSchema`, `functionCall` parts in the answer, `functionResponse` parts sent
/// back. The model's content goes back unchanged, so its thought signatures do too.
public struct GeminiAgent: AgentStepModel {
    public let apiKey: String
    public let model: String
    public let baseURL: URL
    public var attribution: String { String(localized: "by \(AssistantProvider.gemini.title)", comment: "Who wrote an assistant answer: a server or provider name") }
    public var resultBudget: Int { 40_000 }
    var session: URLSession = .shared

    public init(apiKey: String, model: String, baseURL: URL) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    /// Settings keep the OpenAI-style address (…/v1beta/openai); function calling uses the
    /// native API beside it.
    static func nativeBase(from text: String) -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/openai") { trimmed.removeLast("/openai".count) }
        return URL(string: trimmed).flatMap { $0.host() == nil ? nil : $0 }
            ?? URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    }

    public func next(instructions: String, entries: [AgentEntry], tools: [MCPTool]) async throws -> AgentTurn {
        let (data, response) = try await session.data(for: try makeRequest(instructions: instructions, entries: entries, tools: tools))
        try HTTPCheck.ok(response, data)
        return try Self.turn(from: data)
    }

    func makeRequest(instructions: String, entries: [AgentEntry], tools: [MCPTool]) throws -> URLRequest {
        let name = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        var http = URLRequest(url: baseURL.appending(path: "models/\(name):generateContent"), timeoutInterval: 180)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructions]]],
            "contents": Self.contents(entries),
            "tools": [["functionDeclarations": tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description, "parametersJsonSchema": AgentLoop.schema(tool)]
            }]],
            "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
        ]
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return http
    }

    static func contents(_ entries: [AgentEntry]) -> [[String: Any]] {
        entries.map { entry -> [String: Any] in
            switch entry {
            case .request(let text):
                return ["role": "user", "parts": [["text": text]]]
            case .turn(let turn):
                if let native = AgentLoop.json(turn.native) { return native }
                var parts: [[String: Any]] = turn.text.isEmpty ? [] : [["text": turn.text]]
                parts += turn.calls.map { ["functionCall": ["id": $0.id, "name": $0.name, "args": $0.arguments.mapValues(\.any)] as [String: Any]] }
                return ["role": "model", "parts": parts]
            case .results(let results):
                return ["role": "user", "parts": results.map { result -> [String: Any] in
                    var response: [String: Any] = ["name": result.name, "response": result.isError ? ["error": result.text] : ["result": result.text]]
                    // Ids made up here (the model sent none) aren't sent back.
                    if !result.callID.hasPrefix(Self.madeUpID) { response["id"] = result.callID }
                    return ["functionResponse": response]
                }]
            }
        }
    }

    static let madeUpID = "margin-call-"

    static func turn(from data: Data) throws -> AgentTurn {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.badResponse(String(localized: "Not JSON."))
        }
        if let feedback = object["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil { throw AssistantError.refused }
        guard let candidate = (object["candidates"] as? [[String: Any]])?.first else {
            throw AssistantError.badResponse(String(localized: "No answer in the response."))
        }
        let finish = candidate["finishReason"] as? String ?? ""
        if ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"].contains(finish) { throw AssistantError.refused }
        let content = candidate["content"] as? [String: Any] ?? ["role": "model", "parts": [[String: Any]]()]
        let parts = content["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        var index = 0
        let calls = parts.compactMap { part -> AgentToolCall? in
            guard let call = part["functionCall"] as? [String: Any] else { return nil }
            defer { index += 1 }
            return AgentToolCall(
                id: (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(madeUpID)\(index)",
                name: call["name"] as? String ?? "",
                arguments: (call["args"] as? [String: Any] ?? [:]).mapValues(MCPValue.init)
            )
        }
        if calls.isEmpty && text.isEmpty && finish == "MALFORMED_FUNCTION_CALL" {
            throw AssistantError.badResponse(String(localized: "The model's tool call couldn't be read."))
        }
        var echoed = content
        echoed["role"] = "model"
        return AgentTurn(text: text, calls: calls, native: try JSONSerialization.data(withJSONObject: echoed, options: [.sortedKeys]))
    }
}
