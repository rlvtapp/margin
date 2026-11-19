import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct DeviceCalendarTests {
    private func deviceEvent(_ id: String, _ title: String, _ start: Date, uid: String? = nil, calendar: String = "Personal") -> CalendarEvent {
        var event = CalendarEvent(id: DeviceCalendar.idPrefix + id, uid: uid, title: title, start: start,
                                  end: start.addingTimeInterval(1800), isOrganizer: true)
        event.calendarName = calendar
        event.calendarColor = 0x34C759
        return event
    }

    /// The Calendar app's events join the agenda, read-only; one already known from an account
    /// (same UID) or from the mail (same title and time) isn't shown twice.
    @Test func deviceEventsMergeWithoutDuplicates() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Date().addingTimeInterval(3600)
        model.calendarEvents[account.id] = [CalendarEvent(id: "e1", uid: "shared", title: "Design review", start: start, end: start.addingTimeInterval(1800))]
        model.showsDeviceCalendar = true
        model.deviceEvents = [
            deviceEvent("a", "Design review", start, uid: "shared"),
            deviceEvent("b", "design review ", start),
            deviceEvent("c", "Gym", start.addingTimeInterval(7200)),
        ]
        let items = model.agenda(from: Date(), to: Date().addingTimeInterval(86_400))
        #expect(items.map(\.title) == ["Design review", "Gym"])
        let gym = try #require(items.last)
        #expect(gym.isFromDevice)
        #expect(!gym.canAnswer)
        #expect(gym.calendarName == "Personal")
        #expect(gym.colorIndex == Palette.nearestAccountIndex(to: 0x34C759))

        model.showsDeviceCalendar = false
        #expect(model.agenda(from: Date(), to: Date().addingTimeInterval(86_400)).map(\.title) == ["Design review"])
    }

    /// Unticking a calendar in the list hides its events everywhere, and it's remembered.
    @Test func hiddenCalendarsAreLeftOut() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let start = Date().addingTimeInterval(3600)
        model.showsDeviceCalendar = true
        model.deviceEvents = [deviceEvent("a", "Gym", start), deviceEvent("b", "Standup", start, calendar: "Work")]
        model.setCalendarShown(MailModel.calendarKey(device: "Personal"), false)
        #expect(model.agenda(from: Date(), to: Date().addingTimeInterval(86_400)).map(\.title) == ["Standup"])
        #expect(model.environment.defaults.stringArray(forKey: "calendar.hidden") == ["device:Personal"])
        model.setCalendarShown(MailModel.calendarKey(device: "Personal"), true)
        #expect(model.agenda(from: Date(), to: Date().addingTimeInterval(86_400)).count == 2)
    }

    /// Reminders show on their day, overdue ones on today, and not when Reminders is unticked.
    @Test func remindersByDay() async throws {
        let model = MailModel(environment: .preview())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        let lastWeek = try #require(calendar.date(byAdding: .day, value: -7, to: today))
        model.dueReminders = [
            DueReminder(id: "1", title: "Late", due: lastWeek, hasTime: false),
            DueReminder(id: "2", title: "Tomorrow", due: tomorrow.addingTimeInterval(9 * 3600), hasTime: true),
        ]
        #expect(model.reminders(on: today).map(\.title) == ["Late"])
        #expect(model.reminders(on: tomorrow).map(\.title) == ["Tomorrow"])
        #expect(model.daysWithEvents(from: today, to: tomorrow.addingTimeInterval(86_400)).contains(tomorrow))
        model.setCalendarShown(MailModel.remindersKey, false)
        #expect(model.reminders(on: tomorrow).isEmpty)
        model.setDone(true, reminder: model.dueReminders[1])
        #expect(model.dueReminders[1].isDone)
    }

    /// Overlapping meetings sit side by side; ones that don't overlap get the full width.
    @Test func overlappingMeetingsShareLanes() {
        let day = Calendar.current.startOfDay(for: Date())
        func item(_ id: String, _ hour: Double, _ hours: Double) -> AgendaItem {
            AgendaItem(id: id, title: id, start: day.addingTimeInterval(hour * 3600), end: day.addingTimeInterval((hour + hours) * 3600),
                       isAllDay: false, isMine: true, repeats: false, source: .device(eventID: id))
        }
        let placed = PlacedMeeting.layout([item("a", 9, 1), item("b", 9.5, 1), item("c", 10, 1), item("d", 13, 1)], on: day)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
        #expect(byID["a"]?.lane == 0)
        #expect(byID["b"]?.lane == 1)
        // c starts when a ends, so it takes a's lane.
        #expect(byID["c"]?.lane == 0)
        #expect(byID["a"]?.lanes == 2)
        #expect(byID["d"]?.lanes == 1)
    }

    /// Calendar colours become the nearest of the app's own.
    @Test func calendarColoursMapToThePalette() {
        #expect(Palette.nearestAccountIndex(to: 0x2F6FEB) == 0)
        #expect(Palette.nearestAccountIndex(to: 0x10A070) == 1)
        #expect(Palette.nearestAccountIndex(to: 0xFF9500) == 3)
    }

    #if os(macOS)
    /// Text going into the Notes script can't break out of its string.
    @Test func notesTextIsEscaped() {
        #expect(MailModel.appleScriptString(#"say "hi" \ bye"#) == #"say \"hi\" \\ bye"#)
        #expect(MailModel.html("<b>&\"") == "&lt;b&gt;&amp;&quot;")
    }
    #endif
}
