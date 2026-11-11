import Foundation
import Testing
@testable import MailCore

/// A step model that answers from a script and remembers what it was sent.
final class ScriptedStepModel: AgentStepModel, @unchecked Sendable {
    let lock = NSLock()
    var turns: [AgentTurn]
    var seen: [[AgentEntry]] = []
    var delay: Duration?
    var attribution: String { "by script" }
    var resultBudget: Int { 50 }

    init(_ turns: [AgentTurn], delay: Duration? = nil) {
        self.turns = turns
        self.delay = delay
    }

    func next(instructions: String, entries: [AgentEntry], tools: [MCPTool]) async throws -> AgentTurn {
        if let delay { try await Task.sleep(for: delay) }
        return lock.withLock {
            seen.append(entries)
            return turns.count > 1 ? turns.removeFirst() : turns[0]
        }
    }
}

/// Collects tool calls from the loop.
final class CallLog: @unchecked Sendable {
    let lock = NSLock()
    var calls: [AgentToolCall] = []
    func add(_ call: AgentToolCall) { lock.withLock { calls.append(call) } }
    var all: [AgentToolCall] { lock.withLock { calls } }
}

@Suite struct AgentLoopTests {
    let tools = [MCPTool(name: "list_to_sort", description: "Mail to sort.", inputSchema: #"{"type":"object","properties":{"limit":{"type":"integer"}},"additionalProperties":false}"#)]

    @Test func aToolCallRunsAndItsResultGoesBackUntilTheModelAnswers() async throws {
        let model = ScriptedStepModel([
            AgentTurn(text: "", calls: [AgentToolCall(id: "c1", name: "list_to_sort", arguments: ["limit": .number(5)])]),
            AgentTurn(text: " Sorted 3 conversations. ", calls: []),
        ])
        let log = CallLog()
        let outcome = try await AgentLoop.run(model, instructions: "i", request: "Sort my mail", tools: tools, maxSteps: 10) { call in
            log.add(call)
            return AgentToolResult(callID: "ignored", name: "ignored", text: #"{"total":3}"#)
        }
        #expect(outcome == AgentOutcome(text: "Sorted 3 conversations.", toolCalls: 1, reachedLimit: false))
        #expect(log.all.map(\.name) == ["list_to_sort"])
        #expect(log.all.first?.arguments["limit"]?.int == 5)
        // The second request carried the call and its result, matched by the call's id.
        let second = try #require(model.seen.last)
        #expect(second.count == 3)
        guard case .results(let results) = second[2] else { Issue.record("no results"); return }
        #expect(results == [AgentToolResult(callID: "c1", name: "list_to_sort", text: #"{"total":3}"#)])
    }

    @Test func itStopsAtTheStepLimit() async throws {
        let model = ScriptedStepModel([AgentTurn(text: "Working on it", calls: [AgentToolCall(id: "c", name: "list_to_sort", arguments: [:])])])
        let outcome = try await AgentLoop.run(model, instructions: "", request: "r", tools: tools, maxSteps: 3) { call in
            AgentToolResult(callID: call.id, name: call.name, text: "ok")
        }
        #expect(outcome.reachedLimit)
        #expect(outcome.toolCalls == 3)
        #expect(outcome.text == "Working on it")
    }

    @Test func callsWithUnreadableArgumentsAreReportedNotRun() async throws {
        let model = ScriptedStepModel([
            AgentTurn(text: "", calls: [AgentToolCall(id: "c1", name: "archive", arguments: [:], problem: "Not JSON.")]),
            AgentTurn(text: "Gave up.", calls: []),
        ])
        let log = CallLog()
        let outcome = try await AgentLoop.run(model, instructions: "", request: "r", tools: tools, maxSteps: 5) { call in
            log.add(call)
            return AgentToolResult(callID: call.id, name: call.name, text: "ran")
        }
        #expect(log.all.isEmpty)
        #expect(outcome.toolCalls == 0)
        guard case .results(let results)? = model.seen.last?.last else { Issue.record("no results"); return }
        #expect(results.first?.isError == true && results.first?.text == "Not JSON.")
    }

    @Test func longResultsAreCutToTheModelsBudget() async throws {
        let model = ScriptedStepModel([
            AgentTurn(text: "", calls: [AgentToolCall(id: "c1", name: "list_to_sort", arguments: [:])]),
            AgentTurn(text: "Done", calls: []),
        ])
        _ = try await AgentLoop.run(model, instructions: "", request: "r", tools: tools, maxSteps: 5) { call in
            AgentToolResult(callID: call.id, name: call.name, text: String(repeating: "x", count: 500))
        }
        guard case .results(let results)? = model.seen.last?.last else { Issue.record("no results"); return }
        #expect(results[0].text.hasPrefix(String(repeating: "x", count: 50) + "\n…"))
    }

    @Test func cancellingStopsTheRun() async throws {
        let model = ScriptedStepModel([AgentTurn(text: "", calls: [AgentToolCall(id: "c", name: "list_to_sort", arguments: [:])])], delay: .milliseconds(50))
        let log = CallLog()
        let task = Task {
            try await AgentLoop.run(model, instructions: "", request: "r", tools: tools, maxSteps: 100) { call in
                log.add(call)
                return AgentToolResult(callID: call.id, name: call.name, text: "ok")
            }
        }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let count = log.all.count
        #expect(count < 5)
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.all.count == count)
    }

    @Test func eachProviderGetsItsOwnKindOfModel() {
        #expect(AssistantSettings(provider: .claude).makeAgent(apiKey: "k") is AnthropicAgent)
        #expect(AssistantSettings(provider: .claude).makeAgent(apiKey: nil) == nil)
        #expect(AssistantSettings(provider: .gemini, model: "gemini-x").makeAgent(apiKey: "k") is GeminiAgent)
        #expect(AssistantSettings(provider: .grok, model: "grok-x").makeAgent(apiKey: "k") is OpenAIChatAgent)
        #expect(AssistantSettings(provider: .chatGPT, model: "gpt-x").makeAgent(apiKey: nil) == nil)
        let ollama = AssistantSettings(provider: .ollama, model: "qwen").makeAgent(apiKey: nil) as? OpenAIChatAgent
        #expect(ollama?.isLocal == true && ollama?.apiKey == nil)
        #expect(AssistantSettings(provider: .off).makeAgent(apiKey: "k") == nil)
        #expect(GeminiAgent.nativeBase(from: AssistantProvider.gemini.defaultBaseURL).absoluteString == "https://generativelanguage.googleapis.com/v1beta")
        #expect(GeminiAgent.nativeBase(from: "").absoluteString == "https://generativelanguage.googleapis.com/v1beta")
    }

    @Test func refusalsAndCutOffCallsAreHandled() throws {
        #expect(throws: AssistantError.refused) {
            try AnthropicAgent.turn(from: Data(#"{"stop_reason":"refusal","content":[]}"#.utf8))
        }
        let cut = try AnthropicAgent.turn(from: Data(#"{"stop_reason":"max_tokens","content":[{"type":"tool_use","id":"t","name":"archive","input":{"ids":["a"]}}]}"#.utf8))
        #expect(cut.calls.first?.problem != nil)
        #expect(throws: AssistantError.refused) {
            try GeminiAgent.turn(from: Data(#"{"candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}"#.utf8))
        }
        let bad = try OpenAIChatAgent.turn(from: Data(#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"x","type":"function","function":{"name":"archive","arguments":"{\"ids\":["}}]}}]}"#.utf8))
        #expect(bad.calls.first?.problem != nil)
    }

    #if canImport(FoundationModels)
    @Test func toolSchemasConvertForTheOnDeviceModel() throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let tool = MCPTool(name: "sort_into_group", description: "d", inputSchema: #"""
        {"type":"object","properties":{
          "ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":200},
          "group":{"type":"string","description":"A group."},
          "response":{"type":"string","enum":["accept","maybe","decline"]},
          "limit":{"type":"integer"},"read":{"type":"boolean"},
          "attachments":{"type":"array","items":{"type":"object","properties":{"filename":{"type":"string"}},"required":["filename"]}}},
         "required":["ids","group"],"additionalProperties":false}
        """#)
        _ = try AppleAgent.generationSchema(for: tool)
        _ = try AppleAgent.generationSchema(for: MCPTool(name: "list_groups", description: "d", inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#))
    }
    #endif
}

// MARK: - Each provider's format, over a stubbed network

/// Answers requests for one host from a script, and keeps what was sent.
final class AgentStub: URLProtocol, @unchecked Sendable {
    struct Sent { var url: URL; var headers: [String: String]; var body: [String: Any] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [(Int, Data)]] = [:]
    nonisolated(unsafe) private static var sent: [String: [Sent]] = [:]

    static func script(_ host: String, _ answers: [String]) {
        script(host, statuses: answers.map { (200, $0) })
    }

    static func script(_ host: String, statuses answers: [(Int, String)]) {
        lock.withLock { scripts[host] = answers.map { ($0.0, Data($0.1.utf8)) }; sent[host] = [] }
    }

    static func requests(_ host: String) -> [Sent] { lock.withLock { sent[host] ?? [] } }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host() ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let answer: (Int, Data)? = Self.lock.withLock {
            Self.sent[host, default: []].append(Sent(url: url, headers: request.allHTTPHeaderFields ?? [:],
                                                     body: (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
            return Self.scripts[host]?.isEmpty == false ? Self.scripts[host]!.removeFirst() : nil
        }
        let response = HTTPURLResponse(url: url, statusCode: answer?.0 ?? 500, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer?.1 ?? Data(#"{"error":{"message":"no script"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct AgentProviderTests {
    let tools = [MCPTool(name: "list_to_sort", description: "Mail to sort.", inputSchema: #"{"type":"object","properties":{"limit":{"type":"integer"}},"additionalProperties":false}"#)]

    func run(_ model: some AgentStepModel) async throws -> (AgentOutcome, [AgentToolCall]) {
        let log = CallLog()
        let outcome = try await model.run(instructions: "Be brief.", request: "Sort my mail", tools: tools, maxSteps: 5) { call in
            log.add(call)
            return AgentToolResult(callID: call.id, name: call.name, text: #"{"total":0}"#)
        }
        return (outcome, log.all)
    }

    @Test func claudeUsesToolUseBlocksAndSendsThinkingBack() async throws {
        AgentStub.script("api.anthropic.com", [
            #"{"stop_reason":"tool_use","content":[{"type":"thinking","thinking":"","signature":"sig-1"},{"type":"tool_use","id":"toolu_1","name":"list_to_sort","input":{"limit":50}}]}"#,
            #"{"stop_reason":"end_turn","content":[{"type":"text","text":"Nothing left to sort."}]}"#,
        ])
        var agent = AnthropicAgent(apiKey: "sk-test", model: "claude-opus-5-5")
        agent.session = AgentStub.session
        let (outcome, calls) = try await run(agent)
        #expect(outcome.text == "Nothing left to sort.")
        #expect(calls.map(\.id) == ["toolu_1"] && calls[0].arguments["limit"]?.int == 50)

        let sent = AgentStub.requests("api.anthropic.com")
        #expect(sent.count == 2)
        #expect(sent[0].headers["x-api-key"] == "sk-test")
        #expect(sent[0].headers["anthropic-version"] == AnthropicModel.apiVersion)
        #expect(sent[0].body["system"] as? String == "Be brief.")
        let tool = try #require((sent[0].body["tools"] as? [[String: Any]])?.first)
        #expect(tool["name"] as? String == "list_to_sort" && tool["input_schema"] is [String: Any])
        let messages = try #require(sent[1].body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let echoed = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(echoed.first?["signature"] as? String == "sig-1")
        let result = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        #expect(result["type"] as? String == "tool_result" && result["tool_use_id"] as? String == "toolu_1")
        #expect(result["content"] as? String == #"{"total":0}"# && result["is_error"] == nil)
    }

    @Test func openAIStyleServersUseToolCallsAndToolMessages() async throws {
        AgentStub.script("chat.test", [
            #"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_9","type":"function","function":{"name":"list_to_sort","arguments":"{\"limit\": 20}"}}]}}]}"#,
            #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"All sorted."}}]}"#,
        ])
        var agent = OpenAIChatAgent(baseURL: URL(string: "https://chat.test/v1")!, apiKey: "xai-test", model: "grok-x", attribution: "by Grok", isLocal: false)
        agent.session = AgentStub.session
        let (outcome, calls) = try await run(agent)
        #expect(outcome.text == "All sorted.")
        #expect(calls.first?.arguments["limit"]?.int == 20)

        let sent = AgentStub.requests("chat.test")
        #expect(sent[0].url.path() == "/v1/chat/completions")
        #expect(sent[0].headers["Authorization"] == "Bearer xai-test")
        let tool = try #require((sent[0].body["tools"] as? [[String: Any]])?.first)
        #expect(tool["type"] as? String == "function" && (tool["function"] as? [String: Any])?["parameters"] is [String: Any])
        let messages = try #require(sent[1].body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        let call = try #require((messages[2]["tool_calls"] as? [[String: Any]])?.first)
        #expect(call["id"] as? String == "call_9")
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == #"{"limit": 20}"#)
        #expect(messages[3]["tool_call_id"] as? String == "call_9")
    }

    @Test func geminiUsesFunctionCallsAndKeepsThoughtSignatures() async throws {
        AgentStub.script("gemini.test", [
            #"{"candidates":[{"finishReason":"STOP","content":{"role":"model","parts":[{"functionCall":{"id":"fc1","name":"list_to_sort","args":{"limit":10}},"thoughtSignature":"c2lnbmF0dXJl"}]}}]}"#,
            #"{"candidates":[{"finishReason":"STOP","content":{"role":"model","parts":[{"text":"thinking…","thought":true},{"text":"Your inbox is sorted."}]}}]}"#,
        ])
        var agent = GeminiAgent(apiKey: "g-test", model: "models/gemini-x", baseURL: URL(string: "https://gemini.test/v1beta")!)
        agent.session = AgentStub.session
        let (outcome, calls) = try await run(agent)
        #expect(outcome.text == "Your inbox is sorted.")
        #expect(calls.first?.id == "fc1" && calls.first?.arguments["limit"]?.int == 10)

        let sent = AgentStub.requests("gemini.test")
        #expect(sent[0].url.path() == "/v1beta/models/gemini-x:generateContent")
        #expect(sent[0].headers["x-goog-api-key"] == "g-test")
        let declarations = try #require(((sent[0].body["tools"] as? [[String: Any]])?.first?["functionDeclarations"]) as? [[String: Any]])
        #expect(declarations.first?["parametersJsonSchema"] is [String: Any])
        #expect(((sent[0].body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String == "Be brief.")
        let contents = try #require(sent[1].body["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        let part = try #require((contents[1]["parts"] as? [[String: Any]])?.first)
        #expect(part["thoughtSignature"] as? String == "c2lnbmF0dXJl")
        let response = try #require(((contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"]) as? [String: Any])
        #expect(response["id"] as? String == "fc1" && response["name"] as? String == "list_to_sort")
        #expect((response["response"] as? [String: Any])?["result"] as? String == #"{"total":0}"#)
    }

    @Test func serversWithoutToolsAreRecognisedAndSaidPlainly() async throws {
        // Ollama, LM Studio, vLLM and llama.cpp each say it in their error.
        AgentStub.script("local.test", statuses: [(400, #"{"error":{"message":"registry.ollama.ai/library/gemma:2b does not support tools"}}"#)])
        var agent = OpenAIChatAgent(baseURL: URL(string: "http://local.test/v1")!, apiKey: nil, model: "gemma", name: "Ollama", attribution: "by Ollama", isLocal: true)
        agent.session = AgentStub.session
        await #expect(throws: AssistantError.toolsUnsupported("Ollama")) { _ = try await run(agent) }
        #expect(AssistantError.toolsUnsupported("Ollama").localizedDescription == "Ollama can answer questions but can't take actions.")
        #expect(OpenAIChatAgent.refusesTools(status: 400, message: "\"tools\" param requires --jinja flag"))
        #expect(OpenAIChatAgent.refusesTools(status: 400, message: "\"auto\" tool choice requires --enable-auto-tool-choice"))
        #expect(OpenAIChatAgent.refusesTools(status: 501, message: ""))
        #expect(!OpenAIChatAgent.refusesTools(status: 401, message: "bad key"))
        #expect(!OpenAIChatAgent.refusesTools(status: 400, message: "model not found"))

        // The check asks for a harmless call: made, refused, or ignored.
        AgentStub.script("local.test", [#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"1","type":"function","function":{"name":"check_connection","arguments":"{}"}}]}}]}"#])
        #expect(try await agent.checkActions())
        let probe = try #require((AgentStub.requests("local.test").first?.body["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        #expect(probe["name"] as? String == "check_connection")
        AgentStub.script("local.test", [#"{"choices":[{"message":{"role":"assistant","content":"Sure! check_connection()"}}]}"#])
        #expect(try await agent.checkActions() == false)
        AgentStub.script("local.test", statuses: [(422, #"{"error":{"message":"tools are not supported for this model"}}"#)])
        #expect(try await agent.checkActions() == false)
        AgentStub.script("local.test", statuses: [(401, #"{"error":{"message":"bad key"}}"#)])
        await #expect(throws: AssistantError.self) { _ = try await agent.checkActions() }
    }

    @Test func whichProvidersCanTakeActions() {
        #expect(AssistantProvider.grok.actionSupport == .yes && AssistantProvider.onDevice.actionSupport == .yes)
        #expect(AssistantProvider.lmStudio.actionSupport == .dependsOnModel && AssistantProvider.custom.actionSupport == .dependsOnModel)
        #expect(AssistantProvider.off.actionSupport == .no)
        #expect(AssistantProvider.actionOrder.first == .claude && AssistantProvider.actionOrder.last == .onDevice)
        #expect(AssistantSettings(provider: .custom, model: "m", baseURL: "https://llm.example.org/v1").displayName == "llm.example.org")
        let agent = AssistantSettings(provider: .lmStudio, model: "m").makeAgent(apiKey: nil) as? OpenAIChatAgent
        #expect(agent?.name == "LM Studio")
    }

    @Test func providerErrorsSurfaceInPlainWords() async throws {
        AgentStub.script("down.test", [])
        var agent = OpenAIChatAgent(baseURL: URL(string: "https://down.test/v1")!, apiKey: nil, model: "m", attribution: "", isLocal: true)
        agent.session = AgentStub.session
        await #expect(throws: AssistantError.http(500, "no script")) { _ = try await run(agent) }
    }
}
