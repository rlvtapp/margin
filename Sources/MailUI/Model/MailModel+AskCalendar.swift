import Foundation
import MailCore

/// A calendar change Ask offers: the model asked for it, and it only happens when the person
/// taps to confirm, the way Ask's other actions (archive these, mark read) wait for a tap.
public struct AskCalendarAction: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case add, move, delete }
    public enum State: String, Codable, Sendable { case offered, done, failed }

    public var id = UUID()
    public var kind: Kind
    public var title: String
    /// Where the event will be (add, move) or is (delete).
    public var start: Date
    public var end: Date
    public var isAllDay = false
    /// The event's id from get_events, for move and delete.
    public var eventID: String?
    public var calendar: String?
    public var location: String?
    public var notes: String?
    public var invitees: [String] = []
    public var allDates = false
    /// Guests are told: invitations go out, or a meeting with guests changes for them.
    public var tellsGuests = false
    public var state: State = .offered
}

/// An event an answer was written from, kept with the chat so the answer shows it as a row.
public struct AskEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var colorIndex: Int
    public var declined: Bool
    /// The conversation its invitation came in, opened on a tap.
    public var invitationThreadID: String?

    init(_ item: AgendaItem) {
        id = item.id
        title = item.title
        start = item.start
        end = item.end
        isAllDay = item.isAllDay
        location = item.location.flatMap { $0.isEmpty ? nil : $0 }
        colorIndex = item.colorIndex
        declined = item.response == .declined
        invitationThreadID = item.invitationThreadID.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// What the assistant looked up for one question: conversations it searched for, the calendar
/// as it read it, and changes it offered.
@MainActor final class AskLookup {
    var threads: [MailThread] = []
    var facts: [String] = []
    var actions: [AskCalendarAction] = []
    /// Every event get_events read, soonest first, each once.
    var events: [AskEvent] = []
    var readCalendar = false
    /// How many tools the assistant called: none from a server that ignores tools.
    var toolCalls = 0
}

extension MailModel {
    /// Calendar tools Ask can use. The reading ones are the AI-app tools themselves; the change
    /// ones are offered to the person rather than run.
    static let askCalendarReading: Set<String> = [
        "get_events", "get_event", "list_calendars", "list_reminders", "find_free_time", "suggest_meeting_times", "get_free_busy",
    ]
    static let askCalendarChanges: [String: AskCalendarAction.Kind] = ["create_event": .add, "move_event": .move, "delete_event": .delete]
    /// What a small model (Apple's on this Mac) gets: its context window can't hold them all.
    static let askCompactTools: Set<String> = ["search_mail", "get_events", "find_free_time", "create_event", "move_event", "delete_event"]

    /// The tools Ask's assistant is given to look things up with. Their descriptions say which
    /// questions each is for, so the model picks the calendar for calendar questions.
    static func askTools(compact: Bool) -> [MCPTool] {
        var tools = [MCPTool(
            name: "search_mail",
            description: "Searches the text of the person's saved email for words, and adds the conversations found to what the answer can read and cite. Only for what emails say: for anything on the calendar (events, meetings, schedule, free time), use get_events or find_free_time, which read every calendar directly.",
            inputSchema: #"{"type":"object","properties":{"words":{"type":"string","description":"A few words to find the mail (names, places, things), in the language that mail would be written in."}},"required":["words"],"additionalProperties":false}"#)]
        for tool in CalendarTools.tools(allowChanges: true) {
            if askCalendarReading.contains(tool.name) {
                tools.append(tool)
            } else if askCalendarChanges[tool.name] != nil {
                var offered = tool
                offered.description += " In Ask this doesn't happen yet: it's offered to the person below the answer, and only happens when they confirm it."
                tools.append(offered)
            }
        }
        return compact ? tools.filter { askCompactTools.contains($0.name) } : tools
    }

    /// What the looking-up step is told: find what the question needs, don't answer it.
    static func askLookupInstructions(now: Date = Date(), compact: Bool) -> String {
        let english = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = english
        let weekday = calendar.weekdaySymbols[Calendar.current.component(.weekday, from: now) - 1]
        let weekStarts = calendar.weekdaySymbols[Calendar.current.firstWeekday - 1]
        var lines = [
            "You look things up for the person's question in Margin, their mail and calendar app. Call the tools that find what the question needs. You don't write the answer: another step writes it from what you looked up.",
            "Questions about their calendar, schedule, meetings, events, reminders or free time are answered from the calendar tools, which read every calendar for any dates. Email is only searched for what emails say.",
            "Work out the dates the question means yourself, from now. Today is \(MailModel.day(now)). A period that includes today (this week, this month) starts at the beginning of today, so today's events count; pass both start and end.",
            "When the person asks to add, move or delete an event, call create_event, move_event or delete_event: nothing changes until they confirm it. Use event ids from get_events.",
            "When you have what's needed, or nothing needs looking up, reply with just: done.",
            "Now: \(MailModel.iso(now)), a \(weekday), time zone \(TimeZone.current.identifier). Weeks start on \(weekStarts).",
        ]
        if compact { lines.append("Keep lists short: pass limit 20.") }
        return lines.joined(separator: "\n")
    }

    /// The assistant that answers Ask, ready to look things up with tools; nil when it can't
    /// call tools (Claude Code, Codex, a server without tools), and Ask plans instead. Only
    /// when the answer is written by the assistant these settings make, so one assistant both
    /// looks up and answers.
    func askLookupAgent() -> (any MailAgentModel)? {
        let key = apiKey(for: assistantSettings)
        guard let intelligence, canTakeActions(assistantSettings) != false,
              intelligence.model.attribution == assistantSettings.makeModel(apiKey: key)?.attribution else { return nil }
        return assistantSettings.makeAgent(apiKey: key)
    }

    /// Lets the assistant call Ask's tools until it has what the question needs.
    func lookUp(_ question: String, with agent: any MailAgentModel) async throws -> AskLookup {
        let lookup = AskLookup()
        let perform: AgentToolRunner = { [weak self] call in
            guard let self else { return AgentToolResult(callID: call.id, name: call.name, text: "Margin closed.", isError: true) }
            return await self.runAskTool(call, into: lookup)
        }
        lookup.toolCalls = try await agent.run(instructions: Self.askLookupInstructions(compact: agent.isCompact), request: question,
                                tools: Self.askTools(compact: agent.isCompact), maxSteps: agent.isCompact ? 4 : 6, perform: perform).toolCalls
        return lookup
    }

    /// One of Ask's tools: mail search adds conversations, the calendar is read with the AI-app
    /// tools, and changes are checked and offered.
    func runAskTool(_ call: AgentToolCall, into lookup: AskLookup) async -> AgentToolResult {
        func result(_ text: String, error: Bool = false) -> AgentToolResult {
            AgentToolResult(callID: call.id, name: call.name, text: text, isError: error)
        }
        if let problem = call.problem { return result(problem, error: true) }
        do {
            switch call.name {
            case "search_mail":
                askProgress = .searching
                let words = (call.arguments["words"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else { throw MCPToolError("“words” is needed.") }
                let found = await askConversations(for: words, limit: 10)
                for thread in found where !lookup.threads.contains(where: { $0.id == thread.id }) && lookup.threads.count < 10 {
                    lookup.threads.append(thread)
                }
                return result(json(found.map { ["from": $0.latest.from.displayName, "subject": $0.subject, "date": Self.iso($0.date)] }))
            case "get_events":
                askProgress = .calendar
                let found = try await eventsForTool(call.arguments)
                lookup.readCalendar = true
                for item in found.items where !lookup.events.contains(where: { $0.id == item.id }) { lookup.events.append(AskEvent(item)) }
                lookup.events.sort { ($0.start, $0.title) < ($1.start, $1.title) }
                lookup.facts.append(askEventFacts(found.items, from: found.start, to: found.end, unreadable: found.unreadable,
                                                  query: call.arguments["query"]?.string, calendar: call.arguments["calendar"]?.string))
                let limit = min(max(call.arguments["limit"]?.int ?? 50, 1), 200)
                var answer: [String: Any] = ["events": found.items.prefix(limit).map { eventJSON($0) }, "total": found.items.count,
                                             "start": Self.iso(found.start), "end": Self.iso(found.end)]
                if !found.unreadable.isEmpty { answer["unreadable_calendars"] = found.unreadable }
                return result(json(answer))
            case let name where Self.askCalendarReading.contains(name):
                askProgress = .calendar
                lookup.readCalendar = true
                let text = try await ToolPermissions.$current.withValue(connectionSettings) {
                    try await runCalendarTool(name, call.arguments) ?? ""
                }
                lookup.facts.append("Looked up with \(name) \(Self.argumentsText(call.arguments)):\n" + String(text.prefix(4_000)))
                return result(text)
            case let name where Self.askCalendarChanges[name] != nil:
                let action = try await askOffer(name, call.arguments)
                lookup.actions.append(action)
                return result("Offered to the person to confirm: \(Self.describe(action)). Nothing has changed yet.")
            default:
                throw MCPToolError("“\(call.name)” isn't one of Ask's tools.")
            }
        } catch {
            return result(error.localizedDescription, error: true)
        }
    }

    /// Checks a change the assistant asked for, as the AI-app tool would, without making it.
    func askOffer(_ name: String, _ arguments: [String: MCPValue]) async throws -> AskCalendarAction {
        guard let kind = Self.askCalendarChanges[name] else { throw MCPToolError("Unknown change.") }
        switch kind {
        case .add:
            let title = (arguments["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw MCPToolError("A title is needed.") }
            let dateOnly = arguments["start"]?.string.map { $0.count == 10 } ?? false
            let allDay = arguments["all_day"]?.bool ?? dateOnly
            guard var start = try Self.toolDate(arguments["start"], "start") else { throw MCPToolError("“start” is needed.") }
            var end = try Self.toolDate(arguments["end"], "end")
            if allDay {
                start = Calendar.current.startOfDay(for: start)
                end = Calendar.current.date(byAdding: .day, value: 1, to: max(Calendar.current.startOfDay(for: end ?? start), start))
            }
            let finish = end ?? start.addingTimeInterval(3600)
            guard finish > start else { throw MCPToolError("“end” must be after “start”.") }
            var invitees: [String] = []
            if case .array(let values)? = arguments["invitees"] {
                for value in values {
                    guard let address = value.string?.trimmingCharacters(in: .whitespaces), EmailAddress.isValid(address) else {
                        throw MCPToolError("Each invitee must be an email address.")
                    }
                    invitees.append(address)
                }
            }
            guard !eventDestinations.isEmpty else {
                throw MCPToolError("There's no calendar to add events to. The person can connect a mailbox's calendar (Calendar → Connect) or show the Calendar app's calendars in Margin's Calendar.")
            }
            let wanted = arguments["calendar"]?.string
            if let wanted { _ = try calendarID(named: wanted) }
            return AskCalendarAction(kind: .add, title: title, start: start, end: finish, isAllDay: allDay, calendar: wanted,
                                     location: arguments["location"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                     notes: arguments["notes"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                     invitees: invitees, tellsGuests: !invitees.isEmpty)
        case .move, .delete:
            let item = try await toolEvent(arguments["id"]?.string)
            guard canChange(item) else {
                throw MCPToolError("Someone else organized “\(item.title)”, or its calendar can only be read, so it can't be changed from Margin.")
            }
            var action = AskCalendarAction(kind: kind, title: item.title, start: item.start, end: item.end, isAllDay: item.isAllDay,
                                           eventID: item.id, allDates: arguments["all_dates"]?.bool == true, tellsGuests: hasGuests(item))
            if kind == .move {
                guard let start = try Self.toolDate(arguments["start"], "start") else { throw MCPToolError("“start” is needed.") }
                let end = try Self.toolDate(arguments["end"], "end") ?? start.addingTimeInterval(item.end.timeIntervalSince(item.start))
                guard end > start else { throw MCPToolError("“end” must be after “start”.") }
                action.start = start
                action.end = end
            }
            return action
        }
    }

    /// Makes a change Ask offered, now that the person confirmed it: through the same handler
    /// as the AI-app tools, with the person's own say-so (their tap) in place of the switches.
    public func confirm(_ action: AskCalendarAction) async {
        guard action.state != .done else { return }
        var arguments: [String: MCPValue] = [:]
        let name: String
        switch action.kind {
        case .add:
            name = "create_event"
            arguments["title"] = .string(action.title)
            arguments["start"] = .string(action.isAllDay ? Self.day(action.start) : Self.iso(action.start))
            arguments["end"] = .string(action.isAllDay ? Self.day(action.end.addingTimeInterval(-1)) : Self.iso(action.end))
            arguments["all_day"] = .bool(action.isAllDay)
            if let calendar = action.calendar { arguments["calendar"] = .string(calendar) }
            if let location = action.location { arguments["location"] = .string(location) }
            if let notes = action.notes { arguments["notes"] = .string(notes) }
            if !action.invitees.isEmpty { arguments["invitees"] = .array(action.invitees.map(MCPValue.string)) }
        case .move:
            name = "move_event"
            arguments["id"] = .string(action.eventID ?? "")
            arguments["start"] = .string(Self.iso(action.start))
            arguments["end"] = .string(Self.iso(action.end))
            arguments["all_dates"] = .bool(action.allDates)
        case .delete:
            name = "delete_event"
            arguments["id"] = .string(action.eventID ?? "")
            arguments["all_dates"] = .bool(action.allDates)
        }
        var settings = connectionSettings
        settings.allowChanges = true
        settings.allowSending = true
        let before = notice?.id
        do {
            _ = try await ToolPermissions.$current.withValue(settings) { try await runCalendarTool(name, arguments) }
            // The calendar's own notice says what changed, with Undo.
            setState(.done, of: action)
        } catch {
            setState(.failed, of: action)
            // The calendar's own words when it said why; otherwise Margin's.
            if notice?.id == before || notice?.isError != true {
                notice = Notice(text: String(localized: "Couldn't change “\(action.title)” in your calendar.", table: "Calendar"), isError: true)
            }
        }
    }

    private func setState(_ state: AskCalendarAction.State, of action: AskCalendarAction) {
        for chat in askChats.indices {
            for turn in askChats[chat].turns.indices {
                guard let index = askChats[chat].turns[turn].actions?.firstIndex(where: { $0.id == action.id }) else { continue }
                askChats[chat].turns[turn].actions?[index].state = state
                saveAskChats()
                return
            }
        }
    }

    // MARK: Facts for the answer

    /// Events read for the question, for the answer: every one in the range, with "no events"
    /// said in words, and calendars that couldn't be read named, so a gap isn't taken for a free day.
    func askEventFacts(_ items: [AgendaItem], from start: Date, to end: Date, unreadable: [String],
                       query: String? = nil, calendar: String? = nil) -> String {
        let range = "\(start.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())) to \(end.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))"
        var scope = "every calendar"
        if let calendar, !calendar.isEmpty { scope = "the calendar “\(calendar)”" }
        if let query, !query.isEmpty { scope += ", only events matching “\(query)”" }
        var lines: [String]
        if items.isEmpty {
            lines = ["Calendar from \(range) (\(scope)), read just now for this question: no events."]
        } else {
            lines = ["Calendar from \(range) (\(scope)), read just now for this question, \(items.count) events:"]
            for item in items.prefix(60) { lines.append("- " + askLine(item)) }
            if items.count > 60 { lines.append("- and \(items.count - 60) more") }
        }
        if !unreadable.isEmpty {
            lines.append("These calendars couldn't be read just now, so events from them may be missing: \(unreadable.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    /// "Weekly sync, Thursday 20 November 10:00–10:30, at Room 4, calendar Work".
    func askLine(_ item: AgendaItem) -> String {
        let when: String
        if item.isAllDay {
            let last = item.end.addingTimeInterval(-1)
            when = Calendar.current.isDate(item.start, inSameDayAs: last)
                ? item.start.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ", all day"
                : "\(item.start.formatted(.dateTime.weekday(.wide).day().month(.wide))) to \(last.formatted(.dateTime.weekday(.wide).day().month(.wide))), all day"
        } else {
            when = item.start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()) + "–" + item.end.formatted(.dateTime.hour().minute())
        }
        var line = "\(item.title), \(when)"
        if let place = item.location, !place.isEmpty { line += ", at \(place)" }
        let name = calendarName(of: item)
        if !name.isEmpty { line += ", calendar \(name)" }
        if item.response == .declined { line += " (declined)" } else if item.response == .tentative { line += " (maybe)" }
        if item.repeats { line += " (repeats)" }
        return line
    }

    /// "Add “Lunch”, Thursday 20 November 12:00–13:00", for the answer to mention.
    static func describe(_ action: AskCalendarAction) -> String {
        let when = action.isAllDay ? action.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : action.start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
        return switch action.kind {
        case .add: "add “\(action.title)”, \(when)" + (action.invitees.isEmpty ? "" : ", inviting \(action.invitees.joined(separator: ", "))")
        case .move: "move “\(action.title)” to \(when)"
        case .delete: "delete “\(action.title)”"
        }
    }

    static func argumentsText(_ arguments: [String: MCPValue]) -> String {
        let pairs = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.string ?? "\($0.value)")" }
        return pairs.isEmpty ? "" : "(" + pairs.joined(separator: ", ") + ")"
    }

    /// For assistants without tools: the days the plan names, read the way get_events reads
    /// them (a week from now when the plan gave none).
    func askPlannedCalendar(_ plan: AskPlan) async -> (facts: String, events: [AskEvent])? {
        guard plan.calendar else { return nil }
        var arguments: [String: MCPValue] = [:]
        if let from = plan.from { arguments["start"] = .string(from) }
        if let to = plan.to, let last = try? Self.toolDate(.string(to), "to") {
            // "to" is the last day the question is about, so the range runs to its end.
            let end = to.count == 10 ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: last)) ?? last : last
            arguments["end"] = .string(Self.iso(end))
        }
        let found: (items: [AgendaItem], start: Date, end: Date, unreadable: [String])
        if let read = try? await eventsForTool(arguments) {
            found = read
        } else if let read = try? await eventsForTool([:]) {
            found = read
        } else {
            return nil
        }
        return (askEventFacts(found.items, from: found.start, to: found.end, unreadable: found.unreadable), found.items.map(AskEvent.init))
    }
}
