import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct EventEditingTests {
    private func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.addSampleCalendar()
        return model
    }

    private func item(_ model: MailModel, _ title: String) throws -> AgendaItem {
        let now = Date()
        return try #require(model.agenda(from: now.addingTimeInterval(-40 * 86_400), to: now.addingTimeInterval(60 * 86_400))
            .first { $0.title == title })
    }

    /// New events can go in this device's writable calendars and connected mailboxes; read-only
    /// ones (birthdays) aren't offered.
    @Test func destinations() async {
        let model = await model()
        let titles = model.eventDestinations.map { model.title(of: $0) }
        #expect(titles.contains("Personal"))
        #expect(titles.contains("Work"))
        #expect(!titles.contains("Birthdays"))
        #expect(model.defaultEventDestination != nil)
    }

    /// Making an event puts it on the page, in the calendar picked, remembered for next time.
    @Test func createsAnEvent() async throws {
        let model = await model()
        let work = try #require(model.eventDestinations.first { model.title(of: $0) == "Work" })
        let start = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(11 * 3600)
        let made = await model.createEvent(EventDraft(title: "Budget review", start: start, end: start.addingTimeInterval(3600)), in: work)
        #expect(made)
        let event = try item(model, "Budget review")
        #expect(event.calendarName == "Work")
        #expect(model.canChange(event))
        #expect(model.defaultEventDestination == work)
    }

    /// Moving and editing change the page at once; invitations from the mail and other
    /// people's meetings can't be changed.
    @Test func movesAndEdits() async throws {
        let model = await model()
        let gym = try item(model, "Gym")
        var draft = model.draft(of: gym)
        draft.start = gym.start.addingTimeInterval(3600)
        draft.end = gym.end.addingTimeInterval(3600)
        draft.title = "Gym and stretch"
        #expect(await model.updateEvent(gym, with: draft))
        let moved = try item(model, "Gym and stretch")
        #expect(moved.start == gym.start.addingTimeInterval(3600))

        let critique = try item(model, "Design critique")
        #expect(!model.canChange(critique))
        #expect(!(await model.updateEvent(critique, with: model.draft(of: critique).withTitle("Nope"))))
    }

    @Test func deletes() async throws {
        let model = await model()
        let lunch = try item(model, "Lunch with Maya")
        #expect(await model.deleteEvent(lunch))
        #expect(!model.agenda(from: Date().addingTimeInterval(-86_400), to: Date().addingTimeInterval(86_400)).contains { $0.title == "Lunch with Maya" })
    }

    /// Only what changed is sent, so what Margin can't see of an event stays as it was.
    @Test func sendsOnlyChanges() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let before = EventDraft(title: "Standup", start: start, end: start.addingTimeInterval(900), location: "Room 4", notes: nil)
        var after = before
        after.title = "Daily standup"
        let renamed = MailModel.changes(from: before, to: after)
        #expect(renamed.title == "Daily standup")
        #expect(renamed.start == nil && renamed.end == nil && renamed.location == nil && renamed.notes == nil)

        after = before
        after.start = start.addingTimeInterval(1800)
        after.end = start.addingTimeInterval(2700)
        let moved = MailModel.changes(from: before, to: after)
        #expect(moved.title == nil)
        #expect(moved.start == after.start && moved.end == after.end)
    }

    /// All-day events end at midnight after their last day.
    @Test func allDayEnds() {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let draft = EventDraft(title: "Offsite", start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(86_400 + 3600), isAllDay: true)
        let normalized = MailModel.normalized(draft)
        #expect(normalized.start == day)
        #expect(normalized.end == calendar.date(byAdding: .day, value: 2, to: day))
    }

    /// A repeating event's series change moves the series by as much as the occurrence moved.
    @Test func seriesShift() {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let occurrence = first.addingTimeInterval(7 * 86_400)
        let changes = EventChanges(start: occurrence.addingTimeInterval(1800), end: occurrence.addingTimeInterval(3600))
        let series = changes.forSeries(starting: first, occurrenceStart: occurrence)
        #expect(series.start == first.addingTimeInterval(1800))
        #expect(series.end == first.addingTimeInterval(3600))
    }
}

@MainActor @Suite struct VideoCallTests {
    /// Turning on a video call for an event without one asks the calendar to add it; an event
    /// that already has one isn't given another.
    @Test func addsACallOnlyWhenNew() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let without = EventDraft(title: "Sync", start: start, end: start.addingTimeInterval(1800))
        var with = without
        with.videoCall = true
        #expect(MailModel.changes(from: without, to: with).addVideoCall)
        #expect(!MailModel.changes(from: with, to: with).addVideoCall)
    }

    /// Google makes a Meet call when asked, each request with its own id.
    @Test func meetRequest() throws {
        let body = GoogleCalendarClient.videoBody(EventChanges(title: "Sync", addVideoCall: true))
        let conference = try #require(body["conferenceData"] as? [String: Any])
        let request = try #require(conference["createRequest"] as? [String: Any])
        #expect((request["conferenceSolutionKey"] as? [String: String])?["type"] == "hangoutsMeet")
        #expect(request["requestId"] as? String != nil)
        #expect(GoogleCalendarClient.videoBody(EventChanges(title: "Sync"))["conferenceData"] == nil)
    }

    /// The service a calendar offers, and none for this device's calendars.
    @Test func services() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.addSampleCalendar()
        let device = try #require(model.eventDestinations.first { if case .device = $0 { true } else { false } })
        #expect(await model.videoCallService(for: device) == nil)
        let account = try #require(model.eventDestinations.first { if case .account = $0 { true } else { false } })
        #expect(await model.videoCallService(for: account) != nil)
        var draft = EventDraft(title: "Kickoff", start: Date().addingTimeInterval(86_400), end: Date().addingTimeInterval(86_400 + 1800))
        draft.videoCall = true
        #expect(await model.createEvent(draft, in: account))
        let made = model.agenda(from: Date(), to: Date().addingTimeInterval(2 * 86_400)).first { $0.title == "Kickoff" }
        #expect(made?.joinURL != nil)
    }
}

private extension EventDraft {
    func withTitle(_ title: String) -> EventDraft {
        var copy = self
        copy.title = title
        return copy
    }
}
