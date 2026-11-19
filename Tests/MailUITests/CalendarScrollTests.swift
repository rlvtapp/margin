import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct CalendarScrollTests {
    /// Letting go past half a column moves a day; short of it, the days spring back.
    @Test func settlesOnTheNearerDay() {
        #expect(CalendarScroll.settle(slide: -60, column: 100) == (1, 40))
        #expect(CalendarScroll.settle(slide: 60, column: 100) == (-1, -40))
        #expect(CalendarScroll.settle(slide: 30, column: 100) == (0, 30))
        #expect(CalendarScroll.settle(slide: -49, column: 100) == (0, -49))
    }

    /// A pinch never makes hours shorter than the view or taller than 120 points.
    @Test func zoomStaysInBounds() {
        #expect(CalendarScroll.zoomed(48, by: 2, smallest: 30) == 96)
        #expect(CalendarScroll.zoomed(48, by: 5, smallest: 30) == 120)
        #expect(CalendarScroll.zoomed(48, by: 0.2, smallest: 30) == 30)
    }

    /// Zooming keeps the time under the fingers (or the middle) where it was.
    @Test func zoomKeepsTheAnchor() {
        // 9:00 at 48pt an hour is 432; 100pt down the view. Doubled, 9:00 is at 864.
        let scroll = CalendarScroll.anchoredScroll(scroll: 332, anchor: 100, ratio: 2)
        #expect(scroll + 100 == 864)
        #expect(CalendarScroll.anchoredScroll(scroll: 0, anchor: 100, ratio: 0.5) == 0)
    }

    /// ⌘+ and ⌘− step the hours, within bounds, and Actual Size goes back.
    @Test func zoomCommands() {
        let model = MailModel(environment: .preview())
        model.smallestHourHeight = 30
        model.calendarHourHeight = 48
        model.zoomCalendar(1)
        #expect(model.calendarHourHeight == 56)
        for _ in 0..<20 { model.zoomCalendar(-1) }
        #expect(model.calendarHourHeight == 30)
        model.zoomCalendar(0)
        #expect(model.calendarHourHeight == MailModel.defaultHourHeight)
    }
}

@MainActor @Suite struct CalendarSnapTests {
    /// A swipe still moving locks onto the day it was heading for, even short of halfway.
    @Test func followsTheSwipe() {
        #expect(CalendarScroll.settle(slide: -30, column: 100, velocity: -3).days == 1)
        #expect(CalendarScroll.settle(slide: 30, column: 100, velocity: 3).days == -1)
        // Flicked back: it returns to where it was.
        #expect(CalendarScroll.settle(slide: -60, column: 100, velocity: 4).days == 0)
    }
}

@MainActor @Suite struct MonthSheetTests {
    /// Events are shared out by day once: a two-day all-day event is on both days, a meeting on its own.
    @Test func sharesEventsOutByDay() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(5 * 86_400)
        model.calendarEvents[account.id] = [
            CalendarEvent(id: "a", title: "Offsite", start: day, end: day.addingTimeInterval(2 * 86_400), isAllDay: true),
            CalendarEvent(id: "b", title: "Sync", start: day.addingTimeInterval(10 * 3600), end: day.addingTimeInterval(11 * 3600)),
        ]
        let byDay = MonthBoard.byDay(model.agenda(from: day, to: day.addingTimeInterval(3 * 86_400)))
        #expect(byDay[day]?.map(\.title) == ["Offsite", "Sync"])
        #expect(byDay[day.addingTimeInterval(86_400)]?.map(\.title) == ["Offsite"])
        #expect(byDay[day.addingTimeInterval(2 * 86_400)] == nil)
    }
}
