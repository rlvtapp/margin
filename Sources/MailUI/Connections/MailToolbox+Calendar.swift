import Foundation
import MailCore

/// The calendar for AI apps (docs/calendar.md, "AI apps"): what's on from every calendar the
/// Calendar page shows, free time, colleagues' free/busy, and reminders. Reading is on whenever
/// the connection is. Making, moving and deleting events and changing reminders need "Allow
/// changes"; anything that tells other people (inviting guests, changing or deleting a meeting
/// that has guests, answering an invitation) needs "Allow sending" too. Calendars hidden in the
/// Calendar page and mailboxes hidden from AI apps are left out.
enum CalendarTools {
    private static let range = #""start":{"type":"string","description":"ISO 8601 date or date and time; defaults to now."},"end":{"type":"string","description":"ISO 8601; defaults to 7 days after start. At most 92 days after start."}"#
    private static let eventID = #""id":{"type":"string","description":"An event id from get_events."}"#

    static func tools(allowChanges: Bool) -> [MCPTool] {
        var tools = [
            MCPTool(name: "get_events",
                    description: "Events between two dates, soonest first, from every calendar Margin's Calendar shows: invitations in the mail, connected Microsoft 365 and Google calendars, and the device's Calendar app. Each has an id for get_event, its calendar, where it came from (source: account, invitation or calendar_app), the person's answer, and whether it can be answered or changed. Optionally only events whose title, place or people contain query.",
                    inputSchema: #"{"type":"object","properties":{"# + range + #","query":{"type":"string"},"calendar":{"type":"string","description":"A calendar id from list_calendars (or a name only one calendar has)."},"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Defaults to 50."}},"additionalProperties":false}"#),
            MCPTool(name: "get_event",
                    description: "One event in full: when and where, the join link, notes, the organizer, every guest with their answer, where it came from, and the conversation its invitation came in (for read_conversation).",
                    inputSchema: #"{"type":"object","properties":{"# + eventID + #"},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "list_calendars",
                    description: "The calendars Margin's Calendar shows: each mailbox (whether its own calendar is connected, so events can be added there and colleagues' free/busy looked up), the device's Calendar app calendars, and Reminders.",
                    inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
            MCPTool(name: "list_reminders",
                    description: "Reminders from the Reminders app that are due between two dates, with overdue ones when the range starts today or earlier. Ids work with set_reminder_done.",
                    inputSchema: #"{"type":"object","properties":{"# + range + #"},"additionalProperties":false}"#),
            MCPTool(name: "find_free_time",
                    description: "Open slots in the person's working hours (09:00 to 17:00 unless given), weekdays only unless asked, long enough for a meeting of the given minutes. Every event in the calendars Margin shows counts as busy, except all-day events and ones the person declined.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "minutes":{"type":"integer","minimum":5,"maximum":480},
                      "start":{"type":"string","description":"ISO 8601; defaults to now."},
                      "days":{"type":"integer","minimum":1,"maximum":31,"description":"How many days from start; defaults to 7."},
                      "work_start":{"type":"integer","minimum":0,"maximum":23,"description":"Hour the working day starts; defaults to 9."},
                      "work_end":{"type":"integer","minimum":1,"maximum":24,"description":"Hour it ends; defaults to 17."},
                      "include_weekends":{"type":"boolean"}},"required":["minutes"],"additionalProperties":false}
                    """#),
            MCPTool(name: "suggest_meeting_times",
                    description: "Up to 5 times for a meeting with these people when the person and everyone whose calendar can be seen are free: weekdays in working hours, soonest first, in the next two weeks. A connected Microsoft 365 calendar suggests them itself when it can; otherwise Margin works them out from every calendar it shows and everyone's free/busy. Each time says who's free, who's busy and whose calendar couldn't be seen (unknown, not free). Reading only: use create_event to book one.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "people":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":20,"description":"Email addresses."},
                      "minutes":{"type":"integer","minimum":5,"maximum":480},
                      "start":{"type":"string","description":"ISO 8601; the earliest time to suggest. Defaults to now."},
                      "calendar":{"type":"string","description":"A calendar id from list_calendars the meeting will go in; picks which mailbox asks."}},"required":["people","minutes"],"additionalProperties":false}
                    """#),
            MCPTool(name: "get_free_busy",
                    description: "When colleagues (or rooms) are busy, from their work calendars. Only works through a mailbox whose Microsoft 365 or Google Workspace calendar is connected in Margin; people outside the organization come back as unknown, not free.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "people":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":20,"description":"Email addresses."},
                      "start":{"type":"string","description":"ISO 8601; defaults to now."},
                      "end":{"type":"string","description":"ISO 8601; defaults to 7 days after start. At most 31 days after start."},
                      "mailbox":{"type":"string","description":"A mailbox name or address from list_calendars; the first connected one when left out."}},"required":["people"],"additionalProperties":false}
                    """#),
        ]
        guard allowChanges else { return tools }
        tools += [
            MCPTool(name: "create_event",
                    description: "Adds an event to one of the calendars from list_calendars (the Calendar app's or a connected mailbox's). Invitees get an invitation from the mailbox's calendar, which needs \"Allow sending\" and a mailbox calendar.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "title":{"type":"string"},"start":{"type":"string","description":"ISO 8601; a date alone for an all-day event."},
                      "end":{"type":"string","description":"ISO 8601; defaults to an hour after start (the same day for all-day events)."},
                      "all_day":{"type":"boolean"},"location":{"type":"string"},"notes":{"type":"string"},
                      "calendar":{"type":"string","description":"A calendar id from list_calendars (or a name only one calendar has); the person's usual one when left out."},
                      "invitees":{"type":"array","items":{"type":"string"},"maxItems":50,"description":"Email addresses to invite."}},"required":["title","start"],"additionalProperties":false}
                    """#),
            MCPTool(name: "move_event",
                    description: "Moves an event the person can change (can_change in get_events) to a new start, keeping its length unless end is given. For a repeating event only that date moves, unless all_dates. Guests are told by their calendar, which needs \"Allow sending\".",
                    inputSchema: #"{"type":"object","properties":{"# + eventID + #","start":{"type":"string","description":"ISO 8601"},"end":{"type":"string","description":"ISO 8601"},"all_dates":{"type":"boolean","description":"For a repeating event: move the whole series by as much."}},"required":["id","start"],"additionalProperties":false}"#),
            MCPTool(name: "update_event",
                    description: "Changes an event's title, place or notes (empty removes a place or notes). Guests are told by their calendar, which needs \"Allow sending\".",
                    inputSchema: #"{"type":"object","properties":{"# + eventID + #","title":{"type":"string"},"location":{"type":"string"},"notes":{"type":"string"},"all_dates":{"type":"boolean"}},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "delete_event",
                    description: "Deletes an event the person can change. For a repeating event only that date, unless all_dates. Deleting a meeting with guests cancels it for them, which needs \"Allow sending\". To say no to someone else's meeting, use respond_to_invite instead.",
                    inputSchema: #"{"type":"object","properties":{"# + eventID + #","all_dates":{"type":"boolean"}},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "set_reminder_done",
                    description: "Ticks a reminder done in the Reminders app, or not done again.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string","description":"A reminder id from list_reminders."},"done":{"type":"boolean"}},"required":["id","done"],"additionalProperties":false}"#),
            MCPTool(name: "create_reminder",
                    description: "Adds a reminder to the Reminders app, optionally due on a day (a date) or at a time (a date and time), in a list.",
                    inputSchema: #"{"type":"object","properties":{"title":{"type":"string"},"due":{"type":"string","description":"ISO 8601 date, or date and time."},"list":{"type":"string","description":"A Reminders list; the default one when left out."}},"required":["title"],"additionalProperties":false}"#),
        ]
        return tools
    }
}

/// The switches for the tool call running now: the connection's, or Margin's own assistant's.
enum ToolPermissions {
    @TaskLocal static var current: ConnectionSettings?
}

/// The events each model last read for an AI app outside the Calendar page's months, so their
/// ids keep working with get_event and the change tools.
@MainActor private var lastToolEvents: [ObjectIdentifier: [AgendaItem]] = [:]

extension MailModel {
    /// Answers the calendar tools; nil for any other tool.
    func runCalendarTool(_ name: String, _ arguments: [String: MCPValue]) async throws -> String? {
        switch name {
        case "get_events":
            let found = try await eventsForTool(arguments)
            let limit = min(max(arguments["limit"]?.int ?? 50, 1), 200)
            var result: [String: Any] = ["events": found.items.prefix(limit).map { eventJSON($0) }, "total": found.items.count,
                                         "start": Self.iso(found.start), "end": Self.iso(found.end)]
            if !found.unreadable.isEmpty { result["unreadable_calendars"] = found.unreadable }
            return json(result)
        case "get_event":
            return json(eventJSON(try await toolEvent(arguments["id"]?.string), full: true))
        case "list_calendars":
            return json(calendarsJSON())
        case "list_reminders":
            guard showsReminders, isCalendarShown(Self.remindersKey) else {
                throw MCPToolError("Reminders aren't shown in Margin's Calendar. The person can press Show next to Reminders in the Calendar's list of calendars.")
            }
            let (start, end) = try toolRange(arguments, longest: 92)
            return json(await toolReminders(from: start, to: end).map(reminderJSON))
        case "find_free_time":
            return json(try await freeTime(arguments))
        case "get_free_busy":
            return json(try await freeBusy(arguments))
        case "suggest_meeting_times":
            return json(try await meetingTimesForTool(arguments))
        case "create_event":
            return try await createEventFromTool(arguments)
        case "move_event", "update_event":
            let item = try await changeableEvent(arguments)
            var draft = draft(of: item)
            if name == "move_event" {
                guard let start = try Self.toolDate(arguments["start"], "start") else { throw MCPToolError("“start” is needed.") }
                let end = try Self.toolDate(arguments["end"], "end") ?? start.addingTimeInterval(item.end.timeIntervalSince(item.start))
                guard end > start else { throw MCPToolError("“end” must be after “start”.") }
                draft.start = start
                draft.end = end
            } else {
                if let title = arguments["title"]?.string {
                    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw MCPToolError("A title can't be empty.") }
                    draft.title = title
                }
                if let location = arguments["location"]?.string { draft.location = location }
                if let notes = arguments["notes"]?.string { draft.notes = notes }
            }
            let scope: EventScope = arguments["all_dates"]?.bool == true ? .allEvents : .thisEvent
            guard await updateEvent(item, with: draft, scope: scope) else { throw MCPToolError(notice?.text ?? "The calendar didn't take the change.") }
            forgetToolEvents()
            let what = name == "move_event" ? "Moved “\(draft.title)” to \(draft.start.formatted())." : "Changed “\(draft.title)”."
            return what + (hasGuests(item) ? " The guests are told by the calendar." : "")
        case "delete_event":
            let item = try await changeableEvent(arguments)
            let scope: EventScope = arguments["all_dates"]?.bool == true ? .allEvents : .thisEvent
            guard await deleteEvent(item, scope: scope) else { throw MCPToolError(notice?.text ?? "The calendar didn't delete it.") }
            forgetToolEvents()
            return "Deleted “\(item.title)”." + (hasGuests(item) ? " The guests are told it's cancelled." : "")
        case "set_reminder_done":
            guard showsReminders else { throw MCPToolError("Reminders aren't shown in Margin's Calendar. The person can press Show next to Reminders there.") }
            guard let id = arguments["id"]?.string, let done = arguments["done"]?.bool else { throw MCPToolError("“id” and “done” are needed.") }
            if !dueReminders.contains(where: { $0.id == id }),
               let found = await toolReminders(from: Date().addingTimeInterval(-31 * 86_400), to: Date().addingTimeInterval(92 * 86_400)).first(where: { $0.id == id }) {
                dueReminders.append(found)
            }
            guard let reminder = dueReminders.first(where: { $0.id == id }) else { throw MCPToolError("No reminder with that id. Use list_reminders.") }
            setDone(done, reminder: reminder)
            guard dueReminders.first(where: { $0.id == id })?.isDone == done else { throw MCPToolError(notice?.text ?? "Reminders didn't take the change.") }
            return done ? "Ticked off “\(reminder.title)”." : "“\(reminder.title)” is to do again."
        case "create_reminder":
            return try createReminderFromTool(arguments)
        default:
            return nil
        }
    }

    /// Whether this call may tell other people: "Allow sending".
    private var sendingAllowed: Bool { (ToolPermissions.current ?? connectionSettings).allowSending }

    // MARK: Reading

    /// What get_events reads: the range asked for (read afresh when it's outside the loaded
    /// months), then only the calendar and words asked for. Ask reads its events the same way.
    func eventsForTool(_ arguments: [String: MCPValue]) async throws -> (items: [AgendaItem], start: Date, end: Date, unreadable: [String]) {
        let (start, end) = try toolRange(arguments, longest: 92)
        let read = await toolEventsReading(from: start, to: end)
        var items = read.items
        if let wanted = arguments["calendar"]?.string {
            let id = try calendarID(named: wanted)
            items = items.filter { calendarID(of: $0) == id }
        }
        if let query = arguments["query"]?.string?.lowercased(), !query.isEmpty {
            items = items.filter { item in
                ([item.title, item.location ?? "", item.organizer ?? ""] + item.attendees.map(\.address.headerValue))
                    .contains { $0.lowercased().contains(query) }
            }
        }
        return (items, start, end, read.unreadable)
    }

    /// What's on between two moments for AI apps: the Calendar page's agenda, read afresh when
    /// the range is outside the months the page has, without mailboxes hidden from AI apps.
    func toolEvents(from start: Date, to end: Date) async -> [AgendaItem] {
        await toolEventsReading(from: start, to: end).items
    }

    /// The same, with the calendars that couldn't be read just now (so an empty day isn't
    /// taken for a free one). `forAIApps: false` keeps mailboxes hidden from AI apps, for
    /// Margin's own use (suggesting meeting times).
    func toolEventsReading(from start: Date, to end: Date, forAIApps: Bool = true) async -> (items: [AgendaItem], unreadable: [String]) {
        var items: [AgendaItem]
        var unreadable: [String] = []
        let covered = { (range: ClosedRange<Date>?) in range.map { $0.contains(start) && $0.contains(end) } ?? false }
        let accountsCovered = covered(calendarEventsRange) || !readsAccountCalendars
        let deviceCovered = covered(deviceCalendarRange) || !showsDeviceCalendar
        if environment.isPreview || (accountsCovered && deviceCovered) {
            items = agenda(from: start, to: end)
        } else {
            var accountEvents: [UUID: [CalendarEvent]] = [:]
            for account in accounts where usesAccountCalendar(account) {
                do {
                    guard let reader = try await calendarAdapter(for: account) as? any CalendarReading else { throw CalendarWritingError.readOnly }
                    // Every calendar of the mailbox, as the Calendar page reads them, not just its main one.
                    accountEvents[account.id] = try await Self.readAll(reader, from: start, to: end).1
                } catch {
                    if !forAIApps || !connectionSettings.hiddenAccounts.contains(account.id) { unreadable.append(account.label) }
                }
            }
            let device = DeviceCalendar.shared, showsEvents = showsDeviceCalendar
            let events = await Task.detached { showsEvents ? device.events(from: start, to: end) : [] }.value
            items = agenda(from: start, to: end, accountEvents: accountEvents, deviceEvents: events, accountsRead: start...end)
            if forAIApps { lastToolEvents[ObjectIdentifier(self)] = items }
        }
        guard forAIApps else { return (items, unreadable) }
        return (items.filter { $0.accountID.map { !connectionSettings.hiddenAccounts.contains($0) } ?? true }, unreadable)
    }

    /// One event by id: from the last read, or the months around now.
    func toolEvent(_ id: String?) async throws -> AgendaItem {
        guard let id, !id.isEmpty else { throw MCPToolError("An event id from get_events is needed.") }
        let hidden = connectionSettings.hiddenAccounts
        let visible = { (item: AgendaItem) in item.accountID.map { !hidden.contains($0) } ?? true }
        if let found = (lastToolEvents[ObjectIdentifier(self)] ?? []).first(where: { $0.id == id && visible($0) }) { return found }
        if let range = [calendarEventsRange, deviceCalendarRange].compactMap({ $0 }).first,
           let found = agenda(from: range.lowerBound, to: range.upperBound).first(where: { $0.id == id && visible($0) }) {
            return found
        }
        let now = Date()
        if let found = await toolEvents(from: now.addingTimeInterval(-62 * 86_400), to: now.addingTimeInterval(92 * 86_400)).first(where: { $0.id == id }) {
            return found
        }
        throw MCPToolError("No event with that id. Find it with get_events first.")
    }

    private func forgetToolEvents() { lastToolEvents[ObjectIdentifier(self)] = nil }

    func toolReminders(from start: Date, to end: Date) async -> [DueReminder] {
        let today = Calendar.current.startOfDay(for: Date())
        let source: [DueReminder]
        if environment.isPreview || (deviceCalendarRange.map { $0.contains(start) && $0.contains(end) } ?? false) {
            source = dueReminders
        } else {
            let overdueFrom = start <= Date() ? Calendar.current.date(byAdding: .month, value: -1, to: today) ?? start : start
            source = await DeviceCalendar.shared.reminders(from: overdueFrom, to: end)
        }
        return source.filter { reminder in
            (reminder.due >= start && reminder.due < end) || (start <= Date() && !reminder.isDone && reminder.due < today)
        }.sorted { ($0.due, $0.title) < ($1.due, $1.title) }
    }

    func calendarName(of item: AgendaItem) -> String {
        switch item.source {
        case .account(let id, _): account(id)?.label ?? ""
        case .invite(_, let id): id.flatMap { account($0)?.label } ?? "Invitations"
        case .device: item.calendarName ?? ""
        }
    }

    func eventJSON(_ item: AgendaItem, full: Bool = false) -> [String: Any] {
        let source = switch item.source {
        case .account: "account"
        case .invite: "invitation"
        case .device: "calendar_app"
        }
        var result: [String: Any] = [
            "id": item.id, "title": item.title, "all_day": item.isAllDay,
            "start": item.isAllDay ? Self.day(item.start) : Self.iso(item.start),
            "end": item.isAllDay ? Self.day(item.end) : Self.iso(item.end),
            "calendar": calendarName(of: item), "calendar_id": calendarID(of: item), "source": source,
            "organized_by_me": item.isMine, "repeats": item.repeats,
            "can_answer": item.canAnswer, "can_change": canChange(item),
        ]
        if let location = item.location, !location.isEmpty { result["location"] = location }
        if let link = item.joinURL { result["join_url"] = link.absoluteString }
        if let organizer = item.organizer, !item.isMine { result["organizer"] = organizer }
        if item.canAnswer { result["my_response"] = item.response.map(Self.responseName) ?? "not_answered" }
        if let thread = item.invitationThreadID, !thread.isEmpty { result["conversation_id"] = thread }
        let guests = item.attendees.filter { $0.kind != .room }
        if !full {
            if !guests.isEmpty { result["guests"] = guests.count }
            return result
        }
        result["guests"] = guests.map { guest -> [String: Any] in
            var entry: [String: Any] = ["email": guest.address.address, "response": guest.response.map(Self.responseName) ?? "not_answered",
                                        "optional": guest.kind == .optional]
            if let name = guest.address.name, !name.isEmpty { entry["name"] = name }
            return entry
        }
        let rooms = item.attendees.filter { $0.kind == .room }.map { $0.address.name ?? $0.address.address }
        if !rooms.isEmpty { result["rooms"] = rooms }
        if let notes = item.notes, !notes.isEmpty { result["notes"] = String(notes.prefix(4000)) }
        if let uid = item.uid { result["uid"] = uid }
        return result
    }

    private func calendarsJSON() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for account in visibleAccounts where isCalendarShown(Self.calendarKey(account: account.id)) {
            let connected = usesAccountCalendar(account)
            result.append(["id": EventDestination.account(account.id).id, "name": account.label, "address": account.address.address, "kind": "mailbox",
                           "connected": connected, "can_add_events": connected || eventDestinations.contains(.account(account.id)),
                           "free_busy": connected])
        }
        if isCalendarShown("invitations") { result.append(["id": "invitations", "name": "Invitations", "kind": "invitations", "can_add_events": false]) }
        if showsDeviceCalendar {
            for calendar in deviceCalendars where isCalendarShown(Self.calendarKey(device: calendar.title)) {
                result.append(["id": Self.deviceCalendarID(calendar), "name": calendar.title, "account": calendar.source, "kind": "calendar_app", "can_add_events": calendar.allowsChanges])
            }
        }
        if showsReminders, isCalendarShown(Self.remindersKey) { result.append(["id": "reminders", "name": "Reminders", "kind": "reminders"]) }
        return result
    }

    private func reminderJSON(_ reminder: DueReminder) -> [String: Any] {
        var result: [String: Any] = ["id": reminder.id, "title": reminder.title, "done": reminder.isDone,
                                     "due": reminder.hasTime ? Self.iso(reminder.due) : Self.day(reminder.due),
                                     "overdue": !reminder.isDone && reminder.due < (reminder.hasTime ? Date() : Calendar.current.startOfDay(for: Date()))]
        if let list = reminder.list { result["list"] = list }
        return result
    }

    private func freeTime(_ arguments: [String: MCPValue]) async throws -> [String: Any] {
        guard let minutes = arguments["minutes"]?.int, (5...480).contains(minutes) else { throw MCPToolError("“minutes” between 5 and 480 is needed.") }
        let from = try Self.toolDate(arguments["start"], "start") ?? Date()
        let days = min(max(arguments["days"]?.int ?? 7, 1), 31)
        let workStart = arguments["work_start"]?.int ?? 9, workEnd = arguments["work_end"]?.int ?? 17
        guard (0...23).contains(workStart), (1...24).contains(workEnd), workEnd > workStart else {
            throw MCPToolError("“work_start” must be an hour before “work_end”.")
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
        let read = await toolEventsReading(from: start, to: end)
        let busy = read.items
            .filter { !$0.isAllDay && $0.response != .declined }
            .map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }
        let slots = FreeTime.slots(busy: busy, in: DateInterval(start: start, end: end), duration: TimeInterval(minutes * 60),
                                   workday: workStart...workEnd, includeWeekends: arguments["include_weekends"]?.bool ?? false,
                                   now: max(from, Date()), calendar: calendar)
        var result: [String: Any] = [
            "working_hours": String(format: "%02d:00–%02d:00", workStart, workEnd),
            "slots": slots.map { ["start": Self.iso($0.start), "end": Self.iso($0.end), "minutes": Int($0.duration / 60)] as [String: Any] },
        ]
        if !read.unreadable.isEmpty {
            result["unreadable_calendars"] = read.unreadable
            result["note"] = "These calendars couldn't be read just now, so their events aren't counted as busy."
        }
        return result
    }

    private func freeBusy(_ arguments: [String: MCPValue]) async throws -> [String: Any] {
        guard case .array(let values)? = arguments["people"] else { throw MCPToolError("“people” is needed: email addresses.") }
        let people = values.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !people.isEmpty, people.count <= 20 else { throw MCPToolError("Give between 1 and 20 email addresses.") }
        if let wrong = people.first(where: { !EmailAddress.isValid($0) }) { throw MCPToolError("“\(wrong)” isn't an email address.") }
        let (start, end) = try toolRange(arguments, longest: 31)
        let account: MailAccount
        if let name = arguments["mailbox"]?.string {
            guard let found = matchAccount(name) else { throw MCPToolError("No mailbox by that name. Use list_calendars.") }
            guard usesAccountCalendar(found) else { throw MCPToolError(Self.noFreeBusy(found.label)) }
            account = found
        } else {
            guard let found = visibleAccounts.first(where: usesAccountCalendar) else { throw MCPToolError(Self.noFreeBusy(nil)) }
            account = found
        }
        let found = try await busyTimes(for: people, from: start, to: end, account: account)
        return Self.freeBusyJSON(people: people, found: found, mailbox: account.label)
    }

    private func meetingTimesForTool(_ arguments: [String: MCPValue]) async throws -> [String: Any] {
        guard case .array(let values)? = arguments["people"] else { throw MCPToolError("“people” is needed: email addresses.") }
        let people = values.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !people.isEmpty, people.count <= 20 else { throw MCPToolError("Give between 1 and 20 email addresses.") }
        if let wrong = people.first(where: { !EmailAddress.isValid($0) }) { throw MCPToolError("“\(wrong)” isn't an email address.") }
        guard let minutes = arguments["minutes"]?.int, (5...480).contains(minutes) else { throw MCPToolError("“minutes” between 5 and 480 is needed.") }
        let from = try Self.toolDate(arguments["start"], "start") ?? Date()
        var destination: EventDestination?
        if let wanted = arguments["calendar"]?.string {
            let id = try calendarID(named: wanted)
            destination = eventDestinations.first { $0.id == id }
        }
        let times = await suggestTimes(with: people.map { EmailAddress(address: $0) }, length: TimeInterval(minutes * 60),
                                       from: from, in: destination, forAIApps: true)
        let names = { (list: [EmailAddress]) in list.map(\.address) }
        return ["times": times.map { time -> [String: Any] in
            ["start": Self.iso(time.start), "end": Self.iso(time.end), "free": names(time.free), "busy": names(time.busy),
             "unknown": names(time.unknown), "suggested_by": time.fromCalendar ? "calendar" : "margin"]
        }]
    }

    static func noFreeBusy(_ mailbox: String?) -> String {
        (mailbox.map { "“\($0)” can't look up other people's calendars. " } ?? "None of the person's mailboxes can look up other people's calendars. ")
            + "Only a Microsoft 365 or Google Workspace mailbox whose calendar is connected in Margin (Calendar → Connect) can; other mail accounts have no way to ask."
    }

    /// Each person's busy times; anyone the calendar said nothing about is unknown, not free.
    static func freeBusyJSON(people: [String], found: [String: [BusyTime]], mailbox: String) -> [String: Any] {
        let lowered = Dictionary(found.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $0 + $1 })
        return [
            "mailbox": mailbox,
            "people": people.map { person -> [String: Any] in
                guard let busy = lowered[person.lowercased()] else { return ["email": person, "status": "unknown"] }
                return ["email": person, "status": "known",
                        "busy": busy.sorted { $0.start < $1.start }.map { ["start": iso($0.start), "end": iso($0.end)] }]
            },
        ]
    }

    // MARK: Changing

    private func createEventFromTool(_ arguments: [String: MCPValue]) async throws -> String {
        let title = (arguments["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MCPToolError("A title is needed.") }
        let dateOnly = arguments["start"]?.string.map { $0.count == 10 } ?? false
        let allDay = arguments["all_day"]?.bool ?? dateOnly
        guard var start = try Self.toolDate(arguments["start"], "start") else { throw MCPToolError("“start” is needed.") }
        var end = try Self.toolDate(arguments["end"], "end")
        let calendar = Calendar.current
        if allDay {
            start = calendar.startOfDay(for: start)
            let lastDay = calendar.startOfDay(for: end ?? start)
            end = calendar.date(byAdding: .day, value: 1, to: max(lastDay, start))
        }
        let finish = end ?? start.addingTimeInterval(3600)
        guard finish > start else { throw MCPToolError("“end” must be after “start”.") }
        var invitees: [EmailAddress] = []
        if case .array(let values)? = arguments["invitees"] {
            for value in values {
                guard let address = value.string?.trimmingCharacters(in: .whitespaces), EmailAddress.isValid(address) else {
                    throw MCPToolError("Each invitee must be an email address.")
                }
                invitees.append(EmailAddress(name: nil, address: address))
            }
        }
        if !invitees.isEmpty && !sendingAllowed {
            throw MCPToolError("Inviting people sends them an invitation, which needs \"Allow sending\" in Margin's settings. Leave out invitees to add the event just for the person.")
        }
        let destinations = eventDestinations.filter { destination in
            if case .account(let id) = destination { !connectionSettings.hiddenAccounts.contains(id) } else { true }
        }
        guard !destinations.isEmpty else {
            throw MCPToolError("There's no calendar to add events to. The person can connect a mailbox's calendar (Calendar → Connect) or show the Calendar app's calendars in Margin's Calendar.")
        }
        let destination: EventDestination
        if let wanted = arguments["calendar"]?.string {
            let id = try calendarID(named: wanted)
            guard let found = destinations.first(where: { $0.id == id }) else {
                throw MCPToolError("Events can't be added to “\(wanted)”. Use a calendar from list_calendars with can_add_events.")
            }
            destination = found
        } else if !invitees.isEmpty {
            guard let found = destinations.first(where: { if case .account = $0 { true } else { false } }) else {
                throw MCPToolError("Invitations go out from a mailbox's calendar, and none is connected. The person can connect one in Margin's Calendar.")
            }
            destination = found
        } else {
            destination = defaultEventDestination.flatMap { wanted in destinations.first { $0 == wanted } } ?? destinations[0]
        }
        if !invitees.isEmpty, case .device = destination {
            throw MCPToolError("The Calendar app's calendars can't send invitations from Margin. Pick a mailbox's calendar from list_calendars.")
        }
        let location = arguments["location"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let notes = arguments["notes"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let draft = EventDraft(title: title, start: start, end: finish, isAllDay: allDay, location: location, notes: notes, invitees: invitees)
        guard await createEvent(draft, in: destination) else { throw MCPToolError(notice?.text ?? "The calendar didn't take the event.") }
        forgetToolEvents()
        let when = allDay ? start.formatted(date: .complete, time: .omitted) : start.formatted()
        return "Added “\(title)” to \(describe(destination)), \(when)." + (invitees.isEmpty ? "" : " The invitees get an invitation.")
    }

    /// Answers an event from get_events through the same once-per-answer path as the Calendar
    /// page: the account's calendar for its events, a reply email for invitations from the mail.
    func respondToEvent(_ arguments: [String: MCPValue], with response: CalendarInvite.Response) async throws -> String {
        let item = try await toolEvent(arguments["event_id"]?.string)
        guard item.canAnswer else {
            if item.isMine { throw MCPToolError("The person organized “\(item.title)”, so there's nothing to answer.") }
            throw MCPToolError("“\(item.title)” is in the Calendar app, which can't send answers. Answer it there, or the invitation in the mail.")
        }
        guard !isAnswering(item) else { throw MCPToolError("An answer to “\(item.title)” is already on its way.") }
        let before = notice?.id
        guard let task = respond(to: item, with: response) else { throw MCPToolError("An answer to “\(item.title)” is already on its way.") }
        await task.value
        // Every path records the answer once it's out; a refusal leaves a notice saying why.
        forgetToolEvents()
        let now = agenda(from: item.start.addingTimeInterval(-1), to: item.end.addingTimeInterval(1)).first { $0.id == item.id }
        if let notice, notice.id != before, notice.isError || (now != nil && now?.response != response) {
            throw MCPToolError(notice.text)
        }
        return "\(response.verb) “\(item.title)”. The organizer is told."
    }

    /// "the Calendar app's “Work” calendar" or "the calendar of the mailbox “Work”", so it's clear which.
    private func describe(_ destination: EventDestination) -> String {
        switch destination {
        case .device(_, let title, _): "the Calendar app's “\(title)” calendar"
        case .account(let id): "the calendar of the mailbox “\(account(id)?.label ?? title(of: destination))”"
        }
    }

    static func deviceCalendarID(_ calendar: DeviceCalendarInfo) -> String {
        EventDestination.device(identifier: calendar.identifier ?? calendar.title, title: calendar.title, color: nil).id
    }

    /// The id list_calendars gives the calendar an event is in.
    func calendarID(of item: AgendaItem) -> String {
        switch item.source {
        case .account(let id, _): EventDestination.account(id).id
        case .invite(_, let id): id.map { EventDestination.account($0).id } ?? "invitations"
        case .device:
            deviceCalendars.first { $0.title == item.calendarName }.map(Self.deviceCalendarID) ?? "device:" + (item.calendarName ?? "")
        }
    }

    /// A calendar from list_calendars, by id, or by name or address when only one has it.
    func calendarID(named wanted: String) throws -> String {
        let calendars = calendarsJSON()
        if let exact = calendars.first(where: { $0["id"] as? String == wanted }) { return exact["id"] as? String ?? wanted }
        let named = calendars.filter { entry in
            [entry["name"], entry["address"]].compactMap { $0 as? String }.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        guard !named.isEmpty else { throw MCPToolError("No calendar “\(wanted)”. Use an id from list_calendars.") }
        guard named.count == 1, let id = named[0]["id"] as? String else {
            let choices = named.map { "\($0["id"] as? String ?? "") (\($0["kind"] as? String ?? ""))" }.joined(separator: ", ")
            throw MCPToolError("More than one calendar is called “\(wanted)”: \(choices). Pass one of these ids.")
        }
        return id
    }

    /// The event named in `id`, which the person can change; one with guests needs sending too.
    private func changeableEvent(_ arguments: [String: MCPValue]) async throws -> AgendaItem {
        let item = try await toolEvent(arguments["id"]?.string)
        guard canChange(item) else {
            if case .invite = item.source {
                throw MCPToolError("This event is only known from an invitation in the mail, so only its organizer can change it. Answer it with respond_to_invite instead.")
            }
            if !item.isMine { throw MCPToolError("Someone else organized this event, so only they can change it. Answer it with respond_to_invite instead.") }
            throw MCPToolError("This event's calendar can only be read.")
        }
        if hasGuests(item) && !sendingAllowed {
            throw MCPToolError("This event has guests, who'd be told of the change, which needs \"Allow sending\" in Margin's settings.")
        }
        return item
    }

    /// Whether anyone besides the person (and rooms) is on the event.
    func hasGuests(_ item: AgendaItem) -> Bool {
        let mine = Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() })
        return item.attendees.contains { $0.kind != .room && !mine.contains($0.address.address.lowercased()) }
    }

    private func createReminderFromTool(_ arguments: [String: MCPValue]) throws -> String {
        guard showsReminders else { throw MCPToolError("Reminders aren't shown in Margin's Calendar. The person can press Show next to Reminders there.") }
        let title = (arguments["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MCPToolError("A title is needed.") }
        let due = try Self.toolDate(arguments["due"], "due")
        let hasTime = (arguments["due"]?.string?.count ?? 0) > 10
        let list = arguments["list"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if environment.isPreview {
            if let due { dueReminders.append(DueReminder(id: UUID().uuidString, title: title, due: due, hasTime: hasTime, list: list)) }
        } else {
            do {
                if let added = try DeviceCalendar.shared.addReminder(title: title, due: due, hasTime: hasTime, list: list) { dueReminders.append(added) }
            } catch CalendarWritingError.notFound {
                throw MCPToolError("No Reminders list “\(list ?? "")”. Lists: \(DeviceCalendar.shared.reminderLists().joined(separator: ", ")).")
            }
        }
        return "Added “\(title)” to Reminders" + (due.map { " for " + (hasTime ? $0.formatted() : $0.formatted(date: .complete, time: .omitted)) } ?? "") + "."
    }

    // MARK: Dates

    /// The range in `start` and `end`: now and a week on by default, at most `longest` days.
    func toolRange(_ arguments: [String: MCPValue], longest: Int) throws -> (Date, Date) {
        let start = try Self.toolDate(arguments["start"], "start") ?? Date()
        let end = try Self.toolDate(arguments["end"], "end") ?? start.addingTimeInterval(7 * 86_400)
        guard end > start else { throw MCPToolError("“end” must be after “start”.") }
        guard end.timeIntervalSince(start) <= Double(longest) * 86_400 + 3600 else { throw MCPToolError("Ask for at most \(longest) days at a time.") }
        return (start, end)
    }

    /// ISO 8601 with or without a zone or seconds; a date alone is the start of that day here.
    static func toolDate(_ value: MCPValue?, _ name: String) throws -> Date? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) ?? looseDate(text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        throw MCPToolError("“\(name)” must be an ISO 8601 date or date and time.")
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func responseName(_ response: CalendarInvite.Response) -> String {
        switch response {
        case .accepted: "accepted"
        case .tentative: "tentative"
        case .declined: "declined"
        }
    }
}
