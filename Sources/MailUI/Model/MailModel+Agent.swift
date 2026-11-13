import Foundation
import MailCore

/// One request to Margin's own assistant ("Sort my mail", "Archive last week's newsletters"),
/// with every step it took, shown live and kept until dismissed.
public struct AgentRun: Identifiable, Sendable {
    public enum Kind: Sendable { case sort, request }
    public enum State: Equatable, Sendable { case working, finished, stopped, failed(String) }

    public let id = UUID()
    public var request: String
    public var kind: Kind
    /// "by Grok", "on this Mac".
    public var attribution: String
    public var steps: [AgentRunStep] = []
    public var state: State = .working
    /// The model's closing words, or what Margin can say for it.
    public var summary = ""
    public var reachedLimit = false
    /// The run only had read tools: the person hasn't allowed changes.
    public var couldOnlyLook = false
    /// "LM Studio can't take actions, so Grok took over."
    public var handoffs: [String] = []
    public var isUndone = false
    /// What was there before, so the whole run can be undone at once.
    var changeMark: Int
    var sortingBefore: [String: String]
    var groupsBefore: [EmailGroup]
    /// Conversations sorting still had to look at when the run began.
    var toSortAtStart: Int

    public var isWorking: Bool { state == .working }
}

public struct AgentRunStep: Identifiable, Sendable {
    public let id = UUID()
    public var tool: String
    public var isError: Bool
    public var title: String { ConnectionsSettingsView.describe(tool) }
}

extension MailModel {
    /// Tools that only read; the rest change something.
    static let readingTools: Set<String> = [
        "list_mailboxes", "search_mail", "list_folders", "read_conversation", "list_labels", "get_selection",
        "list_outbox", "list_templates", "list_newsletters", "list_waiting", "read_attachment", "get_settings",
        "list_to_sort", "list_groups", "list_rules", "preview_rule", "list_needs_you", "find_people",
        "list_drafts", "get_writing_style", "list_spam",
    ]

    /// "Sort my mail" may sort into Home's groups, and that's all: the same as Sort Now, which
    /// needs no switch either.
    static let sortingTools: Set<String> = ["list_groups", "list_to_sort", "sort_into_group", "skip_sorting", "read_conversation"]

    /// The few tools the on-device model gets: its context window can't hold them all.
    static let compactTools: Set<String> = [
        "search_mail", "read_conversation", "get_selection", "list_groups", "list_to_sort", "sort_into_group",
        "skip_sorting", "archive", "set_read", "set_starred", "snooze", "add_label", "create_draft", "list_needs_you",
    ]

    /// One provider a run can use: its name for messages, and the key its tool support is
    /// remembered under (nil when it's known, or for tests).
    struct AgentChoice {
        var name: String
        var supportKey: String?
        var model: any MailAgentModel
    }

    public var canAskAgent: Bool { isAssistantOn && assistantSettings.provider != .off }

    /// Sorts the inbox into Home's groups with the person's assistant, as a tool-using run.
    public func sortMailWithAssistant() {
        startAgent(.sort, request: String(localized: "Sort my mail"))
    }

    /// Does what the person typed, with the tools the switches in Settings allow.
    public func askAgent(_ request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startAgent(.request, request: trimmed)
    }

    /// `agent` replaces the person's providers (tests use a scripted one).
    func startAgent(_ kind: AgentRun.Kind, request: String, agent: any MailAgentModel) {
        startAgent(kind, request: request, choices: [AgentChoice(name: "script", supportKey: nil, model: agent)])
    }

    /// Runs with the first of `choices` (by default the providers set up for actions, best
    /// first). When one can't take actions, or Apple's model can't finish, the next takes over
    /// and the card says so; when none can, the card says what to set up.
    func startAgent(_ kind: AgentRun.Kind, request: String, choices given: [AgentChoice]? = nil) {
        guard agentTask == nil else { return }
        let choices = given ?? actionChoices()
        stopSorting()
        let toSort = allInboxesThreads(nil).filter { isVisible($0) && needsSorting($0) }.count
        var permissions = connectionSettings
        if kind == .sort {
            permissions.allowChanges = true
            permissions.allowSending = false
            permissions.allowSettings = false
        }
        agentRun = AgentRun(request: request, kind: kind, attribution: choices.first?.model.attribution ?? "",
                            couldOnlyLook: !permissions.allowChanges,
                            changeMark: agentChanges.count, sortingBefore: sortingChecked, groupsBefore: emailGroups,
                            toSortAtStart: toSort)
        guard !choices.isEmpty else {
            finishAgent(.failed(noActionProviderMessage), summary: "", reachedLimit: false)
            return
        }
        if kind == .sort { sortingProgress = (0, toSort) }
        agentTask = Task { [weak self] in
            guard let self else { return }
            var index = 0
            while true {
                let choice = choices[index]
                self.agentRun?.attribution = choice.model.attribution
                do {
                    let outcome = try await self.run(choice, kind: kind, request: request, permissions: permissions)
                    // A provider that might not support tools and did nothing for "Sort my mail"
                    // most likely ignored them.
                    if kind == .sort, outcome.toolCalls == 0, choice.supportKey != nil {
                        throw AssistantError.toolsUnsupported(choice.name)
                    }
                    if outcome.toolCalls > 0, let key = choice.supportKey { self.rememberActionSupport(true, key: key) }
                    self.finishAgent(.finished, summary: outcome.text, reachedLimit: outcome.reachedLimit)
                    return
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        self.finishAgent(.stopped, summary: "", reachedLimit: false)
                        return
                    }
                    let cantAct: Bool
                    if case AssistantError.toolsUnsupported = error { cantAct = true } else { cantAct = false }
                    if cantAct, let key = choice.supportKey { self.rememberActionSupport(false, key: key) }
                    // Apple's model runs out of room on big jobs; a bigger one carries on.
                    var tooBig = false
                    if case AssistantError.onDevice = error, choice.model.isCompact { tooBig = true }
                    if (cantAct || tooBig), index + 1 < choices.count {
                        let next = choices[index + 1].name
                        self.agentRun?.handoffs.append(cantAct
                            ? String(localized: "\(choice.name) can't take actions, so \(next) took over.")
                            : String(localized: "\(choice.name) couldn't finish, so \(next) took over."))
                        index += 1
                        continue
                    }
                    let message = cantAct ? error.localizedDescription + " " + String(localized: "To take actions, set up Claude, ChatGPT, Gemini or Grok in Settings → Assistant.")
                        : error.localizedDescription
                    self.finishAgent(.failed(message), summary: "", reachedLimit: false)
                    return
                }
            }
        }
    }

    /// One provider's go at the request, with the tools that suit it.
    private func run(_ choice: AgentChoice, kind: AgentRun.Kind, request: String, permissions: ConnectionSettings) async throws -> AgentOutcome {
        let agent = choice.model
        let only: Set<String>? = kind == .sort ? Self.sortingTools : agent.isCompact ? Self.compactTools : nil
        let toolbox = MailToolbox(model: self, permissions: permissions, only: only)
        let instructions = Self.agentInstructions(compact: agent.isCompact, canChange: permissions.allowChanges, canSend: permissions.allowSending)
        let task = kind == .sort ? Self.sortRequest(compact: agent.isCompact) : request
        let attribution = agent.attribution
        let tools = await toolbox.tools()
        let perform: AgentToolRunner = { [weak self] call in
            guard let self else { return AgentToolResult(callID: call.id, name: call.name, text: "Margin closed.", isError: true) }
            return await self.runAgentTool(call, toolbox: toolbox, attribution: attribution)
        }
        return try await agent.run(instructions: instructions, request: task, tools: tools,
                                   maxSteps: kind == .sort ? 40 : 25, perform: perform)
    }

    // MARK: Which provider takes actions

    /// Every provider set up and saved in Settings → Assistant, so one can take actions while
    /// another (Apple's on-device model, say) does everything else.
    public var assistantProfiles: [AssistantProvider: AssistantSettings] {
        _ = actionSettingsRevision
        var profiles: [AssistantProvider: AssistantSettings] = [:]
        if let data = environment.defaults.data(forKey: "assistantProfiles"),
           let saved = try? JSONDecoder().decode([String: AssistantSettings].self, from: data) {
            for (key, value) in saved { if let provider = AssistantProvider(rawValue: key) { profiles[provider] = value } }
        }
        if assistantSettings.provider != .off { profiles[assistantSettings.provider] = assistantSettings }
        if profiles[.onDevice] == nil, OnDeviceModel.isAvailable { profiles[.onDevice] = AssistantSettings(provider: .onDevice) }
        return profiles
    }

    func rememberAssistantProfile(_ settings: AssistantSettings) {
        guard settings.provider != .off else { return }
        var saved = (environment.defaults.data(forKey: "assistantProfiles")
            .flatMap { try? JSONDecoder().decode([String: AssistantSettings].self, from: $0) }) ?? [:]
        saved[settings.provider.rawValue] = settings
        environment.defaults.set(try? JSONEncoder().encode(saved), forKey: "assistantProfiles")
        actionSettingsRevision += 1
    }

    /// The provider picked for actions; nil is Automatic (the best one set up).
    public var actionProviderChoice: AssistantProvider? {
        get {
            _ = actionSettingsRevision
            return environment.defaults.string(forKey: "actionProvider").flatMap(AssistantProvider.init(rawValue:))
        }
        set {
            environment.defaults.set(newValue?.rawValue, forKey: "actionProvider")
            actionSettingsRevision += 1
        }
    }

    /// True or false once known: always for the hosted providers and Apple's model; for local
    /// and other servers after a check or a first try. Nil when not known yet.
    public func canTakeActions(_ settings: AssistantSettings) -> Bool? {
        switch settings.provider.actionSupport {
        case .yes: return true
        case .no: return false
        case .dependsOnModel:
            _ = actionSettingsRevision
            return (environment.defaults.dictionary(forKey: "actionSupport") as? [String: Bool])?[settings.actionKey]
        }
    }

    func rememberActionSupport(_ supported: Bool, key: String) {
        var known = (environment.defaults.dictionary(forKey: "actionSupport") as? [String: Bool]) ?? [:]
        known[key] = supported
        environment.defaults.set(known, forKey: "actionSupport")
        actionSettingsRevision += 1
    }

    func apiKey(for settings: AssistantSettings) -> String? {
        environment.keychain.read(key: settings.provider.keychainKey)
    }

    /// Providers that can take actions, in the order a run tries them: the one picked in
    /// Settings first, then hosted ones, then local ones, then Apple's model. Ones known not to
    /// support tools, or missing a key or model, are left out.
    public var actionProviders: [AssistantSettings] {
        guard usesAI, assistantSettings.provider != .off else { return [] }
        let profiles = assistantProfiles
        var ordered = AssistantProvider.actionOrder.compactMap { profiles[$0] }.filter { settings in
            canTakeActions(settings) != false && settings.makeAgent(apiKey: apiKey(for: settings)) != nil
        }
        if let choice = actionProviderChoice, let index = ordered.firstIndex(where: { $0.provider == choice }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        return ordered
    }

    /// The provider that takes actions now, if any.
    public var actionProvider: AssistantSettings? { actionProviders.first }

    func actionChoices() -> [AgentChoice] {
        actionProviders.compactMap { settings in
            settings.makeAgent(apiKey: apiKey(for: settings)).map { model in
                AgentChoice(name: settings.displayName,
                            supportKey: settings.provider.actionSupport == .dependsOnModel ? settings.actionKey : nil, model: model)
            }
        }
    }

    var noActionProviderMessage: String {
        let setUp = String(localized: "To take actions, set up Claude, ChatGPT, Gemini or Grok in Settings → Assistant.")
        guard usesAI, assistantSettings.provider != .off else { return String(localized: "Turn on the assistant in Settings first.") }
        return AssistantError.toolsUnsupported(assistantSettings.displayName).localizedDescription + " " + setUp
    }

    /// Asks a local or other server whether it can take actions, and remembers the answer.
    public func checkActions(_ settings: AssistantSettings) async -> Result<Bool, Error> {
        guard let agent = settings.makeAgent(apiKey: apiKey(for: settings)) else { return .failure(AssistantError.unavailable) }
        do {
            let supported = try await agent.checkActions()
            rememberActionSupport(supported, key: settings.actionKey)
            return .success(supported)
        } catch {
            return .failure(error)
        }
    }

    /// Runs one tool for the assistant: the same handler AI apps reach over MCP, logged in
    /// Recent activity and shown as a step.
    func runAgentTool(_ call: AgentToolCall, toolbox: MailToolbox, attribution: String) async -> AgentToolResult {
        var result: AgentToolResult
        do {
            result = AgentToolResult(callID: call.id, name: call.name, text: try await toolbox.call(call.name, arguments: call.arguments))
        } catch {
            result = AgentToolResult(callID: call.id, name: call.name, text: error.localizedDescription, isError: true)
        }
        // Stopped while the tool ran: it still happened, so it's still shown.
        agentRun?.steps.append(AgentRunStep(tool: call.name, isError: result.isError))
        if !result.isError { noteActivity(call.name, by: attribution) }
        if let run = agentRun, run.kind == .sort, run.isWorking {
            let left = allInboxesThreads(nil).filter { isVisible($0) && needsSorting($0) }.count
            sortingProgress = (min(max(run.toSortAtStart - left, 0), run.toSortAtStart), run.toSortAtStart)
        }
        return result
    }

    func finishAgent(_ state: AgentRun.State, summary: String, reachedLimit: Bool) {
        agentTask = nil
        guard var run = agentRun else { return }
        if run.kind == .sort { sortingProgress = nil }
        run.state = state
        run.reachedLimit = reachedLimit
        run.summary = summary
        agentRun = run
        if run.kind == .sort, run.steps.contains(where: { !Self.readingTools.contains($0.tool) }) {
            // Other devices pick up the sorting, as after Sort Now.
            Task { await syncNow() }
        }
    }

    /// Stops after the step in progress. What's done stays done (and can be undone).
    public func stopAgent() {
        agentTask?.cancel()
    }

    /// Whether the run changed anything that can be put back.
    public var canUndoAgentRun: Bool {
        guard let run = agentRun, !run.isWorking, !run.isUndone else { return false }
        return agentChanges.count > run.changeMark || sortingChecked != run.sortingBefore
            || Self.groupKey(emailGroups) != Self.groupKey(run.groupsBefore)
    }

    /// Groups by what they are, not their ids (the starter groups get new ids each time).
    static func groupKey(_ groups: [EmailGroup]) -> [[String]] { groups.map { [$0.name, $0.detail] } }

    /// Puts back everything the run changed that can be: labels and groups, snoozes, moves,
    /// read and star, folders, templates. Sent mail and unsubscribes stay.
    public func undoAgentRun() async {
        guard var run = agentRun, canUndoAgentRun else { return }
        while agentChanges.count > run.changeMark {
            if (try? await undoLastAgentChange()) == nil { break }
        }
        // Sorting forgets what this run looked at, so Sort Now looks at it again.
        var checked = sortingChecked
        for (key, value) in checked where run.sortingBefore[key] != value { checked[key] = run.sortingBefore[key] }
        for (key, value) in run.sortingBefore where checked[key] == nil { checked[key] = value }
        if checked != sortingChecked { sortingChecked = checked }
        if Self.groupKey(emailGroups) != Self.groupKey(run.groupsBefore) { emailGroups = run.groupsBefore }
        run.isUndone = true
        agentRun = run
        notice = Notice(text: String(localized: "Undid what the assistant did"))
    }

    public func dismissAgentRun() {
        guard agentRun?.isWorking != true else { return }
        agentRun = nil
    }

    // MARK: Prompts

    static func agentInstructions(compact: Bool, canChange: Bool, canSend: Bool, now: Date = Date()) -> String {
        let language = Locale(identifier: "en").localizedString(forLanguageCode: Locale.preferredLanguages.first ?? "en") ?? "English"
        var lines = [
            "You are the assistant inside Margin, the person's mail app. Do what they ask with the tools, then stop.",
            "Nobody can answer questions while you work: make sensible choices yourself and mention them at the end.",
            "Work in batches: list first, then act on many conversation ids in one call.",
            "Only use ids the tools gave you. If a tool returns an error, read it and try another way.",
        ]
        if !canChange {
            lines.append("You can only look, not change anything: the person hasn't allowed changes. Say so if they asked for one, and that they can allow it in Settings → Assistant.")
        }
        if !canSend { lines.append("You can't send email; create_draft opens one for the person to send.") } else {
            lines.append("Only send email when the person explicitly asked you to send.")
        }
        if compact { lines.append("Keep lists short: pass limit 10.") }
        lines.append("When you're done, answer in one or two short sentences, in \(language): what you did, with counts. No lists, no markdown.")
        lines.append("Now: \(ISO8601DateFormatter().string(from: now)) (\(TimeZone.current.identifier)).")
        return lines.joined(separator: "\n")
    }

    static func sortRequest(compact: Bool) -> String {
        """
        Sort my mail: put every inbox conversation that still needs sorting into one of Home's groups. \
        Call list_groups, then list_to_sort\(compact ? " with limit 10" : ""). Put conversations in groups with \
        sort_into_group, many ids per call; use skip_sorting for ones no group fits. Call list_to_sort again until \
        total is 0.
        """
    }
}
