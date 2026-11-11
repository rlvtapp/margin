import Foundation
import MailCore
import Testing
@testable import MailUI

/// A provider that plays the model's part: it reads the real tools' results and decides the
/// next call from them, the way a hosted model would.
final class ScriptedMailAgent: AgentStepModel, @unchecked Sendable {
    let lock = NSLock()
    var attribution: String { "by script" }
    var resultBudget: Int { 100_000 }
    let isCompact: Bool
    let delay: Duration?
    /// Thrown on the first request, as a provider without tools (or out of room) would.
    let failure: Error?
    /// Answers without calling any tool, as a server that ignores tools does.
    let ignoresTools: Bool
    /// What to do on the first step; the default sorts the inbox.
    let first: [AgentToolCall]?
    private(set) var toolNames: [String] = []

    init(isCompact: Bool = false, delay: Duration? = nil, first: [AgentToolCall]? = nil, failure: Error? = nil, ignoresTools: Bool = false) {
        self.isCompact = isCompact
        self.delay = delay
        self.first = first
        self.failure = failure
        self.ignoresTools = ignoresTools
    }

    func next(instructions: String, entries: [AgentEntry], tools: [MCPTool]) async throws -> AgentTurn {
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        if ignoresTools { return AgentTurn(text: "I would sort your mail into groups.", calls: []) }
        lock.withLock { toolNames = tools.map(\.name) }
        let results = entries.compactMap { entry -> [AgentToolResult]? in
            if case .results(let results) = entry { return results }
            return nil
        }
        switch results.count {
        case 0:
            return AgentTurn(text: "", calls: first ?? [
                AgentToolCall(id: "a", name: "list_groups", arguments: [:]),
                AgentToolCall(id: "b", name: "list_to_sort", arguments: ["limit": .number(200)]),
            ])
        case 1 where first == nil:
            let groups = try JSONSerialization.jsonObject(with: Data(results[0][0].text.utf8)) as? [[String: Any]] ?? []
            let toSort = try JSONSerialization.jsonObject(with: Data(results[0][1].text.utf8)) as? [String: Any] ?? [:]
            let ids = (toSort["conversations"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            let group = groups.first?["name"] as? String ?? ""
            return AgentTurn(text: "", calls: [AgentToolCall(id: "c", name: "sort_into_group",
                                                             arguments: ["ids": .array(ids.map(MCPValue.string)), "group": .string(group)])])
        default:
            return AgentTurn(text: "Sorted \(results.count) batches.", calls: [])
        }
    }
}

@MainActor @Suite struct AssistantAgentTests {
    func model(allowChanges: Bool = false) async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        var settings = model.connectionSettings
        settings.allowChanges = allowChanges
        model.connectionSettings = settings
        return model
    }

    @Test func sortMyMailRunsTheRealToolsShowsProgressAndCanBeUndone() async throws {
        let model = await model()
        let todo = model.allInboxesThreads(nil).filter { model.isVisible($0) && model.needsSorting($0) }
        #expect(!todo.isEmpty)
        let agent = ScriptedMailAgent()

        model.startAgent(.sort, request: "Sort my mail", agent: agent)
        // Home's sorting progress and Stop button follow the run.
        #expect(model.isSorting)
        #expect(model.sortingProgress?.total == todo.count)
        await model.agentTask?.value

        let run = try #require(model.agentRun)
        #expect(run.state == .finished)
        #expect(run.summary == "Sorted 2 batches.")
        #expect(run.steps.map(\.tool) == ["list_groups", "list_to_sort", "sort_into_group"])
        #expect(run.steps.allSatisfy { !$0.isError })
        // Sorting is allowed for "Sort my mail" even with changes off; nothing else is offered.
        #expect(Set(agent.toolNames) == MailModel.sortingTools)
        #expect(model.allInboxesThreads(nil).filter(model.needsSorting).isEmpty)
        #expect(!model.isSorting && model.sortingProgress == nil)
        // Logged like an AI app's calls, with who did it.
        #expect(model.connectionActivity.first?.tool == "sort_into_group")
        #expect(model.connectionActivity.first?.by == "by script")

        #expect(model.canUndoAgentRun)
        await model.undoAgentRun()
        #expect(model.agentRun?.isUndone == true)
        #expect(!model.canUndoAgentRun)
        #expect(model.allInboxesThreads(nil).filter(model.needsSorting).count == todo.count)
        model.dismissAgentRun()
        #expect(model.agentRun == nil)
    }

    @Test func requestsOnlyGetTheToolsTheSwitchesAllow() async throws {
        let model = await model(allowChanges: false)
        let thread = try #require(model.inboxThreads(nil).first)
        let agent = ScriptedMailAgent(first: [AgentToolCall(id: "x", name: "archive", arguments: ["ids": .array([.string(thread.id)])])])
        model.startAgent(.request, request: "Archive the newest", agent: agent)
        await model.agentTask?.value

        #expect(!agent.toolNames.contains("archive") && !agent.toolNames.contains("send_email"))
        #expect(agent.toolNames.contains("search_mail"))
        let run = try #require(model.agentRun)
        #expect(run.couldOnlyLook)
        #expect(run.steps.first?.isError == true)
        #expect(model.inboxThreads(nil).contains { $0.id == thread.id })
        #expect(!model.canUndoAgentRun)

        // Allowed: the same request gets the changing tools, but never sending.
        model.dismissAgentRun()
        var settings = model.connectionSettings
        settings.allowChanges = true
        model.connectionSettings = settings
        let allowed = ScriptedMailAgent(first: [AgentToolCall(id: "y", name: "list_labels", arguments: [:])])
        model.startAgent(.request, request: "Look", agent: allowed)
        await model.agentTask?.value
        #expect(allowed.toolNames.contains("archive") && !allowed.toolNames.contains("send_email"))
        #expect(model.agentRun?.couldOnlyLook == false)
    }

    @Test func stopEndsTheRunFromTheCardOrFromHome() async throws {
        let model = await model()
        model.startAgent(.request, request: "Slow", agent: ScriptedMailAgent(delay: .seconds(5)))
        #expect(model.agentRun?.isWorking == true)
        // A second request waits for the first.
        model.startAgent(.request, request: "Another", agent: ScriptedMailAgent())
        #expect(model.agentRun?.request == "Slow")
        let task = model.agentTask
        model.stopAgent()
        await task?.value
        #expect(model.agentRun?.state == .stopped)

        model.dismissAgentRun()
        model.startAgent(.sort, request: "Sort my mail", agent: ScriptedMailAgent(delay: .seconds(5)))
        #expect(model.isSorting)
        let sorting = model.agentTask
        model.stopSorting()
        await sorting?.value
        #expect(model.agentRun?.state == .stopped)
        #expect(!model.isSorting)
    }

    @Test func smallModelsGetAShortList() async throws {
        let model = await model(allowChanges: true)
        let agent = ScriptedMailAgent(isCompact: true, first: [AgentToolCall(id: "z", name: "list_groups", arguments: [:])])
        model.startAgent(.request, request: "Tidy up", agent: agent)
        await model.agentTask?.value
        #expect(Set(agent.toolNames).isSubset(of: MailModel.compactTools))
        #expect(agent.toolNames.count >= 10)
    }

    @Test func theNamedToolListsMatchTheToolbox() async throws {
        let model = await model()
        var everything = ConnectionSettings()
        everything.allowChanges = true
        everything.allowSending = true
        everything.allowSettings = true
        let names = Set(await MailToolbox(model: model, permissions: everything).tools().map(\.name))
        #expect(MailModel.sortingTools.isSubset(of: names))
        #expect(MailModel.compactTools.isSubset(of: names))
        #expect(MailModel.readingTools.isSubset(of: names))
        // Every tool has words for the activity list and the run card.
        for name in names { #expect(ConnectionsSettingsView.describe(name) != name, "\(name)") }
    }

    @Test func thePaletteOffersWhatWasTypedToTheAssistant() {
        #expect(CommandPalette.agentRequest("Ask Margin to archive old newsletters") == ("archive old newsletters", true))
        #expect(CommandPalette.agentRequest("archive old newsletters") == ("archive old newsletters", false))
        #expect(CommandPalette.agentRequest("Ask Margin to ") == ("", true))
    }

    @Test func aProviderWithoutToolsHandsOffToOneWithThem() async throws {
        let model = await model()
        let local = ScriptedMailAgent(failure: AssistantError.toolsUnsupported("LM Studio"))
        model.startAgent(.sort, request: "Sort my mail", choices: [
            .init(name: "LM Studio", supportKey: "lmStudio|x|m", model: local),
            .init(name: "Grok", supportKey: nil, model: ScriptedMailAgent()),
        ])
        await model.agentTask?.value
        let run = try #require(model.agentRun)
        #expect(run.state == .finished)
        #expect(run.handoffs == ["LM Studio can't take actions, so Grok took over."])
        #expect(run.steps.map(\.tool) == ["list_groups", "list_to_sort", "sort_into_group"])
        // Remembered, so the next run goes straight to one that can.
        #expect((model.environment.defaults.dictionary(forKey: "actionSupport") as? [String: Bool])?["lmStudio|x|m"] == false)
    }

    @Test func aServerThatIgnoresToolsForSortingCountsAsUnableAndSaysSo() async throws {
        let model = await model()
        model.startAgent(.sort, request: "Sort my mail", choices: [.init(name: "my-server.example", supportKey: "custom|k", model: ScriptedMailAgent(ignoresTools: true))])
        await model.agentTask?.value
        let run = try #require(model.agentRun)
        guard case .failed(let message) = run.state else { Issue.record("not failed: \(run.state)"); return }
        #expect(message.hasPrefix("my-server.example can answer questions but can't take actions."))
        #expect(message.contains("Settings → Assistant"))
        #expect(!model.isSorting)
    }

    @Test func appleModelOutOfRoomHandsOffAndNoProviderIsSaidPlainly() async throws {
        let model = await model()
        model.startAgent(.request, request: "Archive old newsletters", choices: [
            .init(name: "Apple Intelligence", supportKey: nil, model: ScriptedMailAgent(isCompact: true, failure: AssistantError.onDevice("Too long."))),
            .init(name: "Claude", supportKey: nil, model: ScriptedMailAgent(first: [AgentToolCall(id: "1", name: "list_labels", arguments: [:])])),
        ])
        await model.agentTask?.value
        #expect(model.agentRun?.handoffs == ["Apple Intelligence couldn't finish, so Claude took over."])
        #expect(model.agentRun?.state == .finished)

        model.dismissAgentRun()
        model.startAgent(.request, request: "Anything", choices: [])
        guard case .failed(let message)? = model.agentRun?.state else { Issue.record("not failed"); return }
        #expect(!message.isEmpty)
        #expect(model.agentTask == nil)
    }

    @Test func actionsGoToTheProviderPickedOrTheBestOneSetUp() async throws {
        let model = await model()
        // Two local servers set up and saved; neither needs a key.
        model.applyAssistant(AssistantSettings(provider: .lmStudio, model: "qwen-tools"), apiKey: nil)
        model.applyAssistant(AssistantSettings(provider: .ollama, model: "gemma"), apiKey: nil)
        #expect(model.assistantSettings.provider == .ollama)
        #expect(model.assistantProfiles[.lmStudio]?.model == "qwen-tools")
        // Automatic: LM Studio comes before Ollama in the order; nothing is known about either yet.
        #expect(model.actionProviders.prefix(2).map(\.provider) == [.lmStudio, .ollama])
        #expect(model.canTakeActions(model.assistantSettings) == nil)

        model.actionProviderChoice = .ollama
        #expect(model.actionProvider?.provider == .ollama)
        // Ollama turns out not to support tools: it drops out, even though it was picked.
        model.rememberActionSupport(false, key: model.assistantSettings.actionKey)
        #expect(model.canTakeActions(model.assistantSettings) == false)
        #expect(model.actionProvider?.provider == .lmStudio)
        #expect(model.actionChoices().first?.name == "LM Studio")
        #expect(model.actionChoices().first?.supportKey == AssistantSettings(provider: .lmStudio, model: "qwen-tools").actionKey)
        if !OnDeviceModel.isAvailable {
            model.rememberActionSupport(false, key: AssistantSettings(provider: .lmStudio, model: "qwen-tools").actionKey)
            #expect(model.actionProvider == nil)
            #expect(model.noActionProviderMessage.hasPrefix("Ollama can answer questions but can't take actions."))
        }
    }

    @Test func instructionsFollowThePermissions() {
        let looking = MailModel.agentInstructions(compact: true, canChange: false, canSend: false)
        #expect(looking.contains("only look"))
        #expect(looking.contains("limit 10"))
        #expect(looking.contains("can't send"))
        let sending = MailModel.agentInstructions(compact: false, canChange: true, canSend: true)
        #expect(sending.contains("explicitly asked you to send"))
        #expect(!sending.contains("only look"))
    }
}
