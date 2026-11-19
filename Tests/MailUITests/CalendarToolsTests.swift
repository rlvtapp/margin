import Foundation
import MailCore
import Testing
@testable import MailUI

/// The calendar tools AI apps use over MCP (docs/calendar.md, "AI apps").
@MainActor @Suite struct CalendarToolsTests {
    func model(changes: Bool = false, sending: Bool = false) async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        await model.findInvites()
        model.addSampleCalendar()
        var settings = model.connectionSettings
        settings.enabled = true
        settings.allowChanges = changes
        settings.allowSending = sending
        model.connectionSettings = settings
        return model
    }

    var today: Date { Calendar.current.startOfDay(for: Date()) }
    var week: [String: MCPValue] {
        ["start": .string(MailModel.iso(today)), "end": .string(MailModel.iso(today.addingTimeInterval(7 * 86_400)))]
    }

    func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func events(_ toolbox: MailToolbox, _ arguments: [String: MCPValue]) async throws -> [[String: Any]] {
        try #require(try object(try await toolbox.call("get_events", arguments: arguments))["events"] as? [[String: Any]])
    }

    func id(of title: String, in model: MailModel) async throws -> String {
        let all = try await events(MailToolbox(model: model), week)
        return try #require(all.first { $0["title"] as? String == title }?["id"] as? String)
    }

    @Test func readingIsAlwaysOnAndChangingNeedsItsSwitch() async {
        let reading = ["get_events", "get_event", "list_calendars", "list_reminders", "find_free_time", "get_free_busy",
                       "suggest_meeting_times"]
        let changing = ["create_event", "move_event", "update_event", "delete_event", "set_reminder_done", "create_reminder"]
        let off = await MailToolbox(model: await model()).tools().map(\.name)
        #expect(reading.allSatisfy(off.contains))
        #expect(!changing.contains(where: off.contains))
        let on = await MailToolbox(model: await model(changes: true)).tools().map(\.name)
        #expect(changing.allSatisfy(on.contains))
        await #expect(throws: MCPToolError.self) {
            try await MailToolbox(model: await model()).call("create_event", arguments: ["title": .string("Lunch"), "start": .string("2030-01-01T12:00")])
        }
        for tool in reading + changing { #expect(ConnectionsSettingsView.describe(tool) != tool) }
    }

    @Test func eventsComeFromEveryShownCalendar() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        let all = try await events(toolbox, week)
        let titles = all.compactMap { $0["title"] as? String }
        #expect(titles.contains("Weekly sync") && titles.contains("Focus time"))
        #expect(Set(all.compactMap { $0["source"] as? String }).isSuperset(of: ["account", "calendar_app"]))
        let sync = try #require(all.first { $0["title"] as? String == "Weekly sync" })
        #expect(sync["my_response"] as? String == "accepted")
        #expect(sync["calendar"] as? String == model.accounts.first?.label)
        #expect(sync["can_change"] as? Bool == false)
        let focus = try #require(all.first { $0["title"] as? String == "Focus time" })
        #expect(focus["calendar"] as? String == "Work" && focus["can_change"] as? Bool == true)

        // Only one calendar, by its id; a name two calendars share is refused rather than guessed.
        let workID = try #require(focus["calendar_id"] as? String)
        let work = try await events(toolbox, week.merging(["calendar": .string(workID)]) { $1 })
        #expect(!work.isEmpty && work.allSatisfy { $0["calendar_id"] as? String == workID && $0["source"] as? String == "calendar_app" })
        do {
            _ = try await toolbox.call("get_events", arguments: week.merging(["calendar": .string("work")]) { $1 })
            Issue.record("“Work” is a mailbox and a Calendar app calendar")
        } catch let error as MCPToolError {
            #expect(error.message.contains(workID))
        }
        let birthdays = try await events(toolbox, week.merging(["calendar": .string("Birthdays")]) { $1 })
        #expect(birthdays.compactMap { $0["title"] as? String } == ["Leo's birthday"])
        let found = try await events(toolbox, week.merging(["query": .string("noor")]) { $1 })
        #expect(found.compactMap { $0["title"] as? String } == ["Design critique"])

        // Too long a range is refused.
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("get_events", arguments: ["start": .string("2030-01-01"), "end": .string("2030-12-01")])
        }
    }

    @Test func hiddenCalendarsAndMailboxesAreLeftOut() async throws {
        let model = await model()
        model.setCalendarShown(MailModel.calendarKey(device: "Personal"), false)
        var titles = try await events(MailToolbox(model: model), week).compactMap { $0["title"] as? String }
        #expect(!titles.contains("Gym") && titles.contains("Focus time"))
        let calendars = try #require(try JSONSerialization.jsonObject(with: Data(try await MailToolbox(model: model).call("list_calendars", arguments: [:]).utf8)) as? [[String: Any]])
        #expect(!calendars.contains { $0["name"] as? String == "Personal" && $0["kind"] as? String == "calendar_app" })
        #expect(calendars.contains { $0["name"] as? String == "Work" && $0["kind"] as? String == "calendar_app" })

        var settings = model.connectionSettings
        settings.hiddenAccounts = [try #require(model.accounts.first?.id)]
        model.connectionSettings = settings
        titles = try await events(MailToolbox(model: model), week).compactMap { $0["title"] as? String }
        #expect(!titles.contains("Weekly sync") && titles.contains("Focus time"))
    }

    @Test func oneEventInFull() async throws {
        let model = await model()
        let id = try await id(of: "Design critique", in: model)
        let event = try object(try await MailToolbox(model: model).call("get_event", arguments: ["id": .string(id)]))
        let guests = try #require(event["guests"] as? [[String: Any]])
        #expect(guests.count == 6)
        #expect(guests.contains { $0["name"] as? String == "Noor Haddad" && $0["response"] as? String == "not_answered" })
        #expect(event["join_url"] as? String == "https://meet.example.com/room")
        #expect(event["organizer"] as? String == "Noor Haddad" && event["can_answer"] as? Bool == true)
        await #expect(throws: MCPToolError.self) { try await MailToolbox(model: model).call("get_event", arguments: ["id": .string("nope")]) }
    }

    @Test func freeTimeSkipsBusyAndAllDayCounts() async throws {
        let model = await model()
        let tomorrow = today.addingTimeInterval(86_400)
        let answer = try object(try await MailToolbox(model: model).call("find_free_time", arguments: [
            "minutes": .number(30), "start": .string(MailModel.day(tomorrow)), "days": .number(1), "include_weekends": .bool(true),
        ]))
        #expect(answer["working_hours"] as? String == "09:00–17:00")
        let slots = try #require(answer["slots"] as? [[String: Any]]).compactMap { slot -> DateInterval? in
            guard let start = (slot["start"] as? String).flatMap(ISO8601DateFormatter().date), let end = (slot["end"] as? String).flatMap(ISO8601DateFormatter().date) else { return nil }
            return DateInterval(start: start, end: end)
        }
        #expect(!slots.isEmpty)
        // Tomorrow has Focus time 8:30–10, Weekly sync 10–10:30 and planning 14–15.
        let busy = model.agenda(from: tomorrow, to: tomorrow.addingTimeInterval(86_400)).filter { !$0.isAllDay }
        for slot in slots { #expect(!busy.contains { $0.start < slot.end && slot.start < $0.end }) }
        #expect(slots.first?.start == tomorrow.addingTimeInterval(10.5 * 3600))
    }

    @Test func otherMonthsAreReadWithoutMovingThePage() async throws {
        let model = await model()
        let account = try #require(model.accounts.first)
        let later = today.addingTimeInterval(200 * 86_400)
        let stored = model.calendarEvents
        var far = CalendarEvent(id: "far", title: "Far off", start: later, end: later.addingTimeInterval(3600), isOrganizer: true)
        far.canChange = true
        let device = CalendarEvent(id: DeviceCalendar.idPrefix + "x|1", title: "Far off", start: later, end: later.addingTimeInterval(3600))
        let items = model.agenda(from: later.addingTimeInterval(-3600), to: later.addingTimeInterval(7200),
                                 accountEvents: [account.id: [far]], deviceEvents: [device])
        // The same meeting from the account and the Calendar app shows once.
        #expect(items.map(\.title) == ["Far off"])
        #expect(items.first?.canChange == true)
        #expect(model.calendarEvents == stored)
    }

    @Test func freeTimeSlotsAreWholeGaps() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 2_000_000_000))
        let meeting = DateInterval(start: day.addingTimeInterval(10 * 3600 + 7 * 60), duration: 3600)
        let slots = FreeTime.slots(busy: [meeting], in: DateInterval(start: day, duration: 86_400), duration: 1800,
                                   includeWeekends: true, now: day)
        #expect(slots.map(\.start) == [day.addingTimeInterval(9 * 3600), day.addingTimeInterval(11 * 3600 + 15 * 60)])
        #expect(slots.last?.end == day.addingTimeInterval(17 * 3600))
    }

    @Test func freeBusyNeedsAWorkCalendar() async throws {
        let model = await model()
        do {
            _ = try await MailToolbox(model: model).call("get_free_busy", arguments: ["people": .array([.string("sam@example.com")])])
            Issue.record("Should have said no mailbox can")
        } catch let error as MCPToolError {
            #expect(error.message.contains("Microsoft 365 or Google Workspace"))
        }
        let shaped = MailModel.freeBusyJSON(people: ["Sam@example.com", "out@else.com"],
                                            found: ["sam@example.com": [BusyTime(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60))]],
                                            mailbox: "Work")
        let people = try #require(shaped["people"] as? [[String: Any]])
        #expect(people[0]["status"] as? String == "known" && (people[0]["busy"] as? [[String: Any]])?.count == 1)
        #expect(people[1]["status"] as? String == "unknown")
    }

    @Test func eventsAreMadeMovedAndDeletedWhereTheyLive() async throws {
        let model = await model(changes: true)
        let toolbox = MailToolbox(model: model)
        let deviceBefore = model.deviceEvents.count
        let accountBefore = model.calendarEvents.values.map(\.count).reduce(0, +)
        let start = today.addingTimeInterval(86_400 + 16 * 3600)
        let calendars = try #require(try JSONSerialization.jsonObject(with: Data(try await toolbox.call("list_calendars", arguments: [:]).utf8)) as? [[String: Any]])
        let personal = try #require(calendars.first { $0["name"] as? String == "Personal" && $0["kind"] as? String == "calendar_app" }?["id"] as? String)
        let work = try #require(calendars.first { $0["name"] as? String == "Work" && $0["kind"] as? String == "calendar_app" }?["id"] as? String)
        // “Personal” is a mailbox too, so the name alone isn't enough.
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("create_event", arguments: ["title": .string("Pick up keys"), "start": .string(MailModel.iso(start)), "calendar": .string("Personal")])
        }
        #expect(model.deviceEvents.count == deviceBefore)
        let made = try await toolbox.call("create_event", arguments: [
            "title": .string("Pick up keys"), "start": .string(MailModel.iso(start)), "calendar": .string(personal),
        ])
        #expect(made.contains("Calendar app's “Personal”"))
        // Only the calendar asked for has it.
        #expect(model.deviceEvents.count == deviceBefore + 1)
        #expect(model.calendarEvents.values.map(\.count).reduce(0, +) == accountBefore)
        let added = try #require(model.deviceEvents.first { $0.title == "Pick up keys" })
        #expect(added.calendarName == "Personal" && added.end == start.addingTimeInterval(3600))

        let id = try await id(of: "Pick up keys", in: model)
        _ = try await toolbox.call("move_event", arguments: ["id": .string(id), "start": .string(MailModel.iso(start.addingTimeInterval(1800)))])
        let moved = try #require(model.deviceEvents.first { $0.title == "Pick up keys" })
        #expect(moved.start == start.addingTimeInterval(1800) && moved.end == start.addingTimeInterval(5400))

        _ = try await toolbox.call("update_event", arguments: ["id": .string(id), "title": .string("Pick up the keys"), "location": .string("Front desk")])
        #expect(model.deviceEvents.contains { $0.title == "Pick up the keys" && $0.location == "Front desk" })

        _ = try await toolbox.call("delete_event", arguments: ["id": .string(try await self.id(of: "Pick up the keys", in: model))])
        #expect(model.deviceEvents.count == deviceBefore)

        // An all-day event from a date alone.
        _ = try await toolbox.call("create_event", arguments: ["title": .string("Offsite"), "start": .string(MailModel.day(start)), "calendar": .string(work)])
        let offsite = try #require(model.deviceEvents.first { $0.title == "Offsite" })
        #expect(offsite.isAllDay && offsite.start == Calendar.current.startOfDay(for: start))
    }

    @Test func otherPeoplesEventsAndGuestsAreProtected() async throws {
        let model = await model(changes: true)
        let toolbox = MailToolbox(model: model)
        // Someone else's meeting can only be answered.
        let standup = try await id(of: "Standup", in: model)
        do {
            _ = try await toolbox.call("move_event", arguments: ["id": .string(standup), "start": .string(MailModel.iso(today.addingTimeInterval(2 * 86_400)))])
            Issue.record("Should have refused")
        } catch let error as MCPToolError {
            #expect(error.message.contains("respond_to_invite"))
        }
        // Read-only calendars.
        let birthday = try await id(of: "Leo's birthday", in: model)
        await #expect(throws: MCPToolError.self) { try await toolbox.call("delete_event", arguments: ["id": .string(birthday)]) }
        // Inviting people needs Allow sending, and a mailbox's calendar.
        let invite: [String: MCPValue] = ["title": .string("Kickoff"), "start": .string("2030-01-07T10:00"), "invitees": .array([.string("sam@example.com")])]
        await #expect(throws: MCPToolError.self) { try await toolbox.call("create_event", arguments: invite) }
        let sending = MailToolbox(model: await self.model(changes: true, sending: true))
        await #expect(throws: MCPToolError.self) {
            try await sending.call("create_event", arguments: invite.merging(["calendar": .string("device:Personal")]) { $1 })
        }
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("create_event", arguments: ["title": .string("x"), "start": .string("2030-01-07T10:00"), "calendar": .string("Birthdays")])
        }
    }

    @Test func assistantUsesItsOwnSwitches() async throws {
        // The connection allows sending, but the assistant's run only allows changes.
        let model = await model(changes: true, sending: true)
        var permissions = ConnectionSettings()
        permissions.allowChanges = true
        let toolbox = MailToolbox(model: model, permissions: permissions)
        do {
            _ = try await toolbox.call("create_event", arguments: ["title": .string("Kickoff"), "start": .string("2030-01-07T10:00"),
                                                                    "invitees": .array([.string("sam@example.com")])])
            Issue.record("Inviting should need sending")
        } catch let error as MCPToolError {
            #expect(error.message.contains("Allow sending"))
        }
    }

    @Test func answeringAnEventNeedsSendingAndSomethingToAnswer() async throws {
        #expect(await !MailToolbox(model: await model(changes: true)).tools().contains { $0.name == "respond_to_invite" })
        let model = await model(changes: true, sending: true)
        let toolbox = MailToolbox(model: model)
        let all = try await events(toolbox, week)
        // The invitation in the sample mail, answered with a reply email.
        let planning = try #require(all.first { $0["title"] as? String == "Quarterly planning" })
        #expect(planning["source"] as? String == "invitation" && planning["my_response"] as? String == "not_answered")
        #expect(planning["conversation_id"] is String)
        let id = try #require(planning["id"] as? String)
        let answer = try await toolbox.call("respond_to_invite", arguments: ["event_id": .string(id), "response": .string("accept")])
        #expect(answer.contains("Quarterly planning"))
        let after = try await events(toolbox, week).first { $0["id"] as? String == id }
        #expect(after?["my_response"] as? String == "accepted")
        // The same answer again isn't sent twice, and still says where it stands.
        _ = try await toolbox.call("respond_to_invite", arguments: ["event_id": .string(id), "response": .string("accept")])
        // Nothing to answer: the person's own event from the Calendar app.
        let focus = try await self.id(of: "Focus time", in: model)
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("respond_to_invite", arguments: ["event_id": .string(focus), "response": .string("decline")])
        }
    }

    @Test func remindersAreListedTickedAndAdded() async throws {
        let model = await model(changes: true)
        let toolbox = MailToolbox(model: model)
        let list = try #require(try JSONSerialization.jsonObject(with: Data(try await toolbox.call("list_reminders", arguments: week).utf8)) as? [[String: Any]])
        let contract = try #require(list.first { $0["title"] as? String == "Send the signed contract" })
        #expect(contract["list"] as? String == "Work" && contract["done"] as? Bool == false)
        #expect(list.first { $0["title"] as? String == "Book flights for Lisbon" }?["due"] as? String == MailModel.day(today.addingTimeInterval(86_400)))

        _ = try await toolbox.call("set_reminder_done", arguments: ["id": .string(try #require(contract["id"] as? String)), "done": .bool(true)])
        #expect(model.dueReminders.first { $0.title == "Send the signed contract" }?.isDone == true)
        await #expect(throws: MCPToolError.self) { try await toolbox.call("set_reminder_done", arguments: ["id": .string("nope"), "done": .bool(true)]) }

        _ = try await toolbox.call("create_reminder", arguments: ["title": .string("Water plants"), "due": .string(MailModel.day(today.addingTimeInterval(2 * 86_400)))])
        let added = try #require(model.dueReminders.first { $0.title == "Water plants" })
        #expect(!added.hasTime)

        await model.setShowsReminders(false)
        await #expect(throws: MCPToolError.self) { try await toolbox.call("list_reminders", arguments: [:]) }
    }

    @Test func calendarWorksOverTheMCPProtocol() async throws {
        let model = await model()
        let server = MCPServer(toolbox: MailToolbox(model: model), name: "Margin", version: "test")
        func send(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let reply = try #require(await server.handle(body))
            return try #require((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["result"] as? [String: Any])
        }
        let names = (try await send("tools/list", [:])["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names.contains("get_events") && !names.contains("create_event"))
        let called = try await send("tools/call", ["name": "get_events", "arguments": ["start": MailModel.iso(today)]])
        #expect(called["isError"] as? Bool == false)
        let text = try #require((called["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(text.contains("Weekly sync"))
    }
}
