import Foundation
import Testing
@testable import MailCore

/// A model that records what it was asked and answers from a script.
final class FakeModel: MailLanguageModel, @unchecked Sendable {
    let lock = NSLock()
    var requests: [ModelRequest] = []
    var summaryAnswer = ThreadSummary(headline: "  Trip to Lisbon is booked. ", points: ["Flat by the river", " ", "May 14–17"], action: "none")
    var labelAnswer = ["travel", " Lisbon ", "Travel", "#Holidays", "A label that is far too long to be useful"]
    var replyAnswer = "Sounds great!\n\nAlex\n"
    var attribution: String { "by fake" }
    var transcriptBudget: Int { 500 }

    func summary(_ request: ModelRequest) async throws -> ThreadSummary { record(request); return summaryAnswer }
    func labels(_ request: ModelRequest) async throws -> [String] { record(request); return labelAnswer }
    func reply(_ request: ModelRequest) async throws -> String { record(request); return replyAnswer }
    func answer(_ request: ModelRequest) async throws -> MailAnswer { record(request); return MailAnswer(text: "", sources: []) }
    private func record(_ request: ModelRequest) { lock.withLock { requests.append(request) } }
}

@Suite struct IntelligenceTests {
    let me = EmailAddress(name: "Alex Rivera", address: "alex@home.example")
    let noor = EmailAddress(name: "Noor Haddad", address: "noor@post.example")

    func thread() -> MailThread {
        let first = MailMessage(id: "1", mailboxID: "INBOX", messageID: "a", from: noor, to: [me], subject: "Lisbon in May?",
                                date: Date(timeIntervalSince1970: 0), body: MessageBody(text: "Flights are cheap. Are you in?"))
        let second = MailMessage(id: "2", mailboxID: "INBOX", messageID: "b", inReplyTo: "a", from: me, to: [noor], subject: "Re: Lisbon in May?",
                                 date: Date(timeIntervalSince1970: 60),
                                 body: MessageBody(text: "Yes! Book it.\n\nOn Tue, Noor wrote:\n> Flights are cheap."))
        return MailThread(id: "t", messages: [first, second])
    }

    @Test func summariesAreTidiedUp() async throws {
        let fake = FakeModel()
        let summary = try await MailIntelligence(model: fake).summarize(thread(), bodies: [:], me: me)
        #expect(summary.headline == "Trip to Lisbon is booked.")
        #expect(summary.points == ["Flat by the river", "May 14–17"])
        #expect(summary.action == nil)
        let request = try #require(fake.requests.first)
        #expect(request.task == .summary)
        #expect(request.instructions.contains("Alex Rivera"))
        #expect(request.prompt.contains("Flights are cheap"))
        // Quoted history is dropped from the transcript.
        #expect(!request.prompt.contains("> Flights"))
    }

    @Test func labelsAreNormalized() async throws {
        let fake = FakeModel()
        let labels = try await MailIntelligence(model: fake)
            .suggestLabels(thread(), bodies: [:], existing: ["Travel", "Invoices"], current: ["Holidays"])
        #expect(labels == ["Travel", "Lisbon"])
        #expect(fake.requests.first?.prompt.contains("Existing labels: Travel, Invoices") == true)
    }

    @Test func rewritesSendTheDraft() async throws {
        let fake = FakeModel()
        let text = try await MailIntelligence(model: fake).write(.shorter, thread: thread(), bodies: [:], me: me, draft: "My long draft")
        #expect(text == "Sounds great!\n\nAlex")
        #expect(fake.requests.first?.prompt.contains("My draft:\nMy long draft") == true)
        let draft = MailIntelligence.replyRequest(.draft(note: "say yes"), thread: thread(), bodies: [:], me: me, draft: "", budget: 1000)
        #expect(draft.prompt.hasPrefix("Write my reply. What I want to say: say yes"))
    }

    @Test func transcriptKeepsNewestWhenCut() {
        let text = Transcript.build(thread(), bodies: [:], budget: 200)
        #expect(text.contains("Yes! Book it."))
        #expect(!text.contains("Are you in?"))
    }

    @Test func claudeRequestsUseStructuredOutputAndFallback() throws {
        let request = try AnthropicModel(apiKey: "sk-test", model: "claude-opus-5-5").makeRequest(
            MailIntelligence.summaryRequest(thread(), bodies: [:], me: me, budget: 1000))
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        let output = try #require(body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "low")
        let format = try #require(output["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(body["thinking"] == nil)

        let haiku = try AnthropicModel(apiKey: "k", model: "claude-haiku-5-5").makeRequest(
            MailIntelligence.summaryRequest(thread(), bodies: [:], me: me, budget: 1000))
        #expect(haiku.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func claudeAnswersAreRead() throws {
        let ok = #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"body\":\"Hi\"}"}]}"#
        #expect(try AnswerSchema.decodeReply(AnthropicModel.answerText(from: Data(ok.utf8))) == "Hi")
        let refused = #"{"stop_reason":"refusal","content":[]}"#
        #expect(throws: AssistantError.refused) { try AnthropicModel.answerText(from: Data(refused.utf8)) }
    }

    @Test func openAICompatibleRequestsAndAnswers() throws {
        let model = OpenAICompatibleModel(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, model: "llama",
                                          attribution: "by Ollama", isLocal: true)
        let labels = MailIntelligence.labelRequest(thread(), bodies: [:], existing: [], budget: 1000)
        let strict = try model.makeRequest(labels, strictSchema: true)
        #expect(strict.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(strict.value(forHTTPHeaderField: "Authorization") == nil)
        let strictBody = try #require(try JSONSerialization.jsonObject(with: strict.httpBody ?? Data()) as? [String: Any])
        #expect((strictBody["response_format"] as? [String: Any])?["type"] as? String == "json_schema")

        let loose = try model.makeRequest(labels, strictSchema: false)
        let looseBody = try #require(try JSONSerialization.jsonObject(with: loose.httpBody ?? Data()) as? [String: Any])
        #expect((looseBody["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        let system = ((looseBody["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        #expect(system.contains("JSON Schema"))

        let answer = #"{"choices":[{"message":{"content":"Sure! ```json\n{\"labels\":[\"Travel\"]}\n```"}}]}"#
        #expect(try AnswerSchema.decodeLabels(OpenAICompatibleModel.answerText(from: Data(answer.utf8))) == ["Travel"])
    }

    @Test func settingsMakeTheRightModel() {
        #expect(AssistantSettings(provider: .claude).makeModel(apiKey: nil) == nil)
        #expect(AssistantSettings(provider: .claude).makeModel(apiKey: "k")?.attribution == "by Claude")
        #expect(AssistantSettings(provider: .ollama, model: "llama").makeModel(apiKey: nil)?.transcriptBudget == 12_000)
        #expect(AssistantSettings(provider: .chatGPT, model: "m").makeModel(apiKey: nil) == nil)
        #expect(AssistantSettings(provider: .off).makeModel(apiKey: "k") == nil)
        #expect(AssistantProvider.claude.defaultModel == "claude-opus-5-5")
    }
}
