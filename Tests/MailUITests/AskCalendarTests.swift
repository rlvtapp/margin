import Foundation
@testable import MailCore
import Testing
@testable import MailUI

/// Plays the assistant's looking-up step: the calls it's given, in turn, then "done".
final class ScriptedAskAgent: AgentStepModel, @unchecked Sendable {
    let lock = NSLock()
    var attribution: String { "by script" }
    var resultBudget: Int { 100_000 }
    let steps: [[AgentToolCall]]
    private(set) var tools: [MCPTool] = []
    private(set) var instructions = ""
    private(set) var results: [AgentToolResult] = []

    init(_ steps: [[AgentToolCall]]) { self.steps = steps }

    func next(instructions: String, entries: [AgentEntry], tools: [MCPTool]) async throws -> AgentTurn {
        let done = entries.reduce(0) { count, entry in if case .results = entry { count + 1 } else { count } }
        lock.withLock {
            self.tools = tools
            self.instructions = instructions
            if case .results(let last)? = entries.last { results += last }
        }
        return done < steps.count ? AgentTurn(text: "", calls: steps[done]) : AgentTurn(text: "done", calls: [])
    }
}

/// Keeps the request the answer is written from, and plans from a fixed reply.
final class RecordingModel: MailLanguageModel, @unchecked Sendable {
    let lock = NSLock()
    let plan: String
    private(set) var answerPrompt = ""
    var attribution: String { "by recording" }
    var transcriptBudget: Int { 40_000 }

    init(plan: String = #"{"search": "", "calendar": false}"#) { self.plan = plan }

    func summary(_ request: ModelRequest) async throws -> ThreadSummary { ThreadSummary(headline: "", points: [], action: nil) }
    func labels(_ request: ModelRequest) async throws -> [String] { [] }
    func reply(_ request: ModelRequest) async throws -> String { plan }
    func answer(_ request: ModelRequest) async throws -> MailAnswer {
        lock.withLock { answerPrompt = request.instructions + "\n" + request.prompt }
        return MailAnswer(text: "From the calendar.", sources: [])
    }
}

@MainActor @Suite struct AskCalendarTests {
    func model(_ recording: RecordingModel) async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.addSampleCalendar()
        model.intelligence = MailIntelligence(model: recording)
        return model
    }

    var today: Date { Calendar.current.startOfDay(for: Date()) }

    func waitForAnswer(_ model: MailModel) async throws {
        for _ in 0..<500 where model.isWorking("ask") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isWorking("ask"))
    }

    /// "What's on my calendar this week?" is answered from the calendar the assistant read for
    /// the days it chose, every event in them, not from a mail search or the two weeks loaded.
    @Test func aCalendarQuestionIsAnsweredFromTheCalendar() async throws {
        let recording = RecordingModel()
        let model = await model(recording)
        let week = ["start": MCPValue.string(MailModel.iso(today)), "end": .string(MailModel.iso(today.addingTimeInterval(7 * 86_400)))]
        let agent = ScriptedAskAgent([[AgentToolCall(id: "1", name: "get_events", arguments: week)]])

        model.ask("What's on my calendar this week?", lookup: agent)
        try await waitForAnswer(model)

        let prompt = recording.answerPrompt
        // Earlier today, tomorrow and later in the week, from the mailbox's calendar and this Mac's.
        for title in ["Roadmap review", "Release freeze", "Weekly sync", "1:1 with Sam", "Focus time"] {
            #expect(prompt.contains(title), "\(title) missing from what the answer is written from")
        }
        #expect(prompt.contains("read just now for this question"))
        #expect(prompt.contains("Don't list them again"))
        // The calendar the assistant read stands in for the loaded fortnight, and no mail was searched.
        #expect(!prompt.contains("Upcoming meetings"))
        #expect(prompt.contains("(none found)"))
        #expect(agent.results.count == 1 && agent.results.allSatisfy { !$0.isError })
        #expect(model.currentAskChat?.turns.last?.answer == "From the calendar.")
        #expect(model.currentAskChat?.turns.last?.sources.isEmpty == true)
        // The events show under the answer as rows, soonest first.
        let events = try #require(model.currentAskChat?.turns.last?.events)
        #expect(events.contains { $0.title == "Weekly sync" } && events.contains { $0.title == "Focus time" })
        #expect(events.map(\.start) == events.map(\.start).sorted())
    }

    /// A server that might not support tools and calls none has ignored them: Ask plans and
    /// searches the mail instead of answering from nothing.
    @Test func aServerThatIgnoresToolsStillSearches() async throws {
        let recording = RecordingModel(plan: #"{"search": "Lisbon flat", "calendar": false}"#)
        let model = await model(recording)
        model.assistantSettings = AssistantSettings(provider: .ollama)
        model.ask("Where is the Lisbon flat?", lookup: ScriptedAskAgent([]))
        try await waitForAnswer(model)
        #expect(recording.answerPrompt.contains("Lisbon"))
        #expect(model.currentAskChat?.turns.last?.events == nil)
    }

    /// The model picks the calendar through what it's given: calendar tools whose descriptions
    /// say they read every calendar, and a mail search that says it's only for what emails say.
    @Test func theToolsSteerCalendarQuestionsToTheCalendar() {
        let tools = MailModel.askTools(compact: false)
        let names = tools.map(\.name)
        for name in ["search_mail", "get_events", "find_free_time", "suggest_meeting_times", "create_event", "move_event", "delete_event"] {
            #expect(names.contains(name))
        }
        #expect(!names.contains("update_event") && !names.contains("respond_to_invite"))
        let search = try? #require(tools.first { $0.name == "search_mail" })
        #expect(search?.description.contains("get_events") == true)
        #expect(tools.first { $0.name == "create_event" }?.description.contains("confirm") == true)
        let compact = MailModel.askTools(compact: true).map(\.name)
        #expect(Set(compact) == MailModel.askCompactTools)
        // The model is told when now is, so it works out "this week" itself.
        let instructions = MailModel.askLookupInstructions(compact: false)
        #expect(instructions.contains(TimeZone.current.identifier))
    }

    /// Adding an event is offered under the answer and only happens on the person's tap.
    @Test func changesWaitForTheTap() async throws {
        let recording = RecordingModel()
        let model = await model(recording)
        let noon = Calendar.current.date(byAdding: .hour, value: 36, to: today) ?? today
        let agent = ScriptedAskAgent([[AgentToolCall(id: "1", name: "create_event",
                                                     arguments: ["title": .string("Lunch with Sam"), "start": .string(MailModel.iso(noon))])]])

        model.ask("Put lunch with Sam on my calendar tomorrow at noon", lookup: agent)
        try await waitForAnswer(model)

        let action = try #require(model.currentAskChat?.turns.last?.actions?.first)
        #expect(action.kind == .add && action.state == .offered && action.start == noon)
        #expect(recording.answerPrompt.contains("not made yet"))
        let window = (today, today.addingTimeInterval(4 * 86_400))
        #expect(!model.agenda(from: window.0, to: window.1).contains { $0.title == "Lunch with Sam" })

        await model.confirm(action)
        #expect(model.agenda(from: window.0, to: window.1).contains { $0.title == "Lunch with Sam" })
        #expect(model.currentAskChat?.turns.last?.actions?.first?.state == .done)
    }

    /// Moving and deleting only take events the person can change; others go back to the model.
    @Test func movingChecksTheEventFirst() async throws {
        let model = await model(RecordingModel())
        let start = today.addingTimeInterval(2 * 86_400 + 9 * 3600)
        await model.confirm(try await model.askOffer("create_event", ["title": .string("Pick up keys"), "start": .string(MailModel.iso(start))]))
        let items = model.agenda(from: today, to: today.addingTimeInterval(7 * 86_400))
        let mine = try #require(items.first { $0.title == "Pick up keys" })
        let theirs = try #require(items.first { $0.title == "Weekly sync" })
        let later = mine.start.addingTimeInterval(3600)
        let moved = try await model.askOffer("move_event", ["id": .string(mine.id), "start": .string(MailModel.iso(later))])
        #expect(moved.kind == .move && moved.start == later && moved.end == later.addingTimeInterval(mine.end.timeIntervalSince(mine.start)))
        await #expect(throws: MCPToolError.self) { try await model.askOffer("delete_event", ["id": .string(theirs.id)]) }

        await model.confirm(moved)
        #expect(model.agenda(from: today, to: today.addingTimeInterval(7 * 86_400)).first { $0.title == "Pick up keys" }?.start == later)
    }

    /// An assistant without tools plans instead: it names the days, and those are read.
    @Test func withoutToolsThePlanNamesTheDays() async throws {
        let from = MailModel.day(today), to = MailModel.day(today.addingTimeInterval(6 * 86_400))
        let recording = RecordingModel(plan: #"{"search": "", "calendar": true, "from": "\#(from)", "to": "\#(to)"}"#)
        let model = await model(recording)
        model.ask("What's on my calendar this week?", lookup: nil)
        try await waitForAnswer(model)
        let prompt = recording.answerPrompt
        #expect(prompt.contains("1:1 with Sam") && prompt.contains("Roadmap review"))
        #expect(prompt.contains("read just now for this question"))
        #expect(MailIntelligence.parsePlan(#"{"search": "", "calendar": true, "from": "2026-11-16", "to": "2026-11-22"}"#)
            == AskPlan(search: "", calendar: true, from: "2026-11-16", to: "2026-11-22"))
    }

    /// An empty range says so in words, and a calendar that couldn't be read is named, so a
    /// gap isn't taken for a free day.
    @Test func emptyAndUnreadableAreToldApart() async {
        let model = await model(RecordingModel())
        let empty = model.askEventFacts([], from: today, to: today.addingTimeInterval(86_400), unreadable: [])
        #expect(empty.contains("no events"))
        let missing = model.askEventFacts([], from: today, to: today.addingTimeInterval(86_400), unreadable: ["Work"])
        #expect(missing.contains("couldn't be read") && missing.contains("Work"))
    }

    /// Chats saved before Ask offered calendar changes still load.
    @Test func olderChatsStillLoad() throws {
        let saved = #"[{"id":"\#(UUID())","date":0,"turns":[{"id":"\#(UUID())","question":"Hi","answer":"Hello","isError":false,"sources":[]}]}]"#
        let chats = try JSONDecoder().decode([AskChat].self, from: Data(saved.utf8))
        #expect(chats.first?.turns.first?.actions == nil)
    }
}
