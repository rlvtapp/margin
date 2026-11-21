import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct NextUpColumnTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func item(_ id: String, day: Int, _ hour: Double, _ hours: Double = 1, allDay: Bool = false,
                      response: CalendarInvite.Response? = nil, now: Date) -> AgendaItem {
        let start = calendar.startOfDay(for: now).addingTimeInterval(Double(day) * 86_400 + hour * 3600)
        return AgendaItem(id: id, title: id, start: start, end: start.addingTimeInterval(allDay ? 86_400 : hours * 3600),
                          isAllDay: allDay, response: response, isMine: true, repeats: false, source: .device(eventID: id))
    }

    /// The card gets the meeting on now; ended and declined ones are gone; the rest is by day,
    /// with an all-day item under today rather than on the card.
    @Test func nextMeetingThenTheRestByDay() throws {
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(10.5 * 3600)
        let items = [
            item("ended", day: 0, 9, now: now),
            item("freeze", day: 0, 0, allDay: true, now: now),
            item("on now", day: 0, 10, now: now),
            item("declined", day: 0, 12, response: .declined, now: now),
            item("standup", day: 0, 15, now: now),
            item("sync", day: 1, 10, now: now),
        ]
        let plan = NextUpColumn.plan(items, now: now, calendar: calendar)
        #expect(plan.next?.id == "on now")
        #expect(plan.days.map { $0.items.map(\.id) } == [["freeze", "standup"], ["sync"]])
        #expect(plan.days.first?.day == calendar.startOfDay(for: now))
    }

    /// Past the limit no more meetings are listed, and a later day doesn't start with room for
    /// its heading only.
    @Test func stopsAtTheLimit() {
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(8 * 3600)
        let items = [item("next", day: 0, 9, now: now)]
            + (0..<2).map { item("today \($0)", day: 0, 10 + Double($0), now: now) }
            + (0..<3).map { item("tomorrow \($0)", day: 1, 10 + Double($0), now: now) }
        let plan = NextUpColumn.plan(items, now: now, limit: 3, calendar: calendar)
        #expect(plan.days.map { $0.items.map(\.id) } == [["today 0", "today 1"]])
        let roomier = NextUpColumn.plan(items, now: now, limit: 4, calendar: calendar)
        #expect(roomier.days.map { $0.items.map(\.id) } == [["today 0", "today 1"], ["tomorrow 0", "tomorrow 1"]])
    }
}
