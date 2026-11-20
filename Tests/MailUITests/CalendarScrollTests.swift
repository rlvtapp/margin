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

@MainActor @Suite struct CalendarSpringTests {
    /// The snap comes to rest within about half a second, never past zero, even thrown hard.
    @Test func settlesSoftlyWithoutOvershoot() {
        // As `DaySlider.springHome` starts it: heading home no faster than it can stop.
        var offset: CGFloat = 80, velocity: CGFloat = -min(2500, CalendarScroll.springOmega * 80)
        var crossed = false
        for _ in 0..<120 {
            (offset, velocity) = CalendarScroll.springStep(offset: offset, velocity: velocity, dt: 1.0 / 120)
            if offset < -12 { crossed = true }
        }
        #expect(abs(offset) < 0.5)
        #expect(!crossed)
    }

    /// Up to a week the days move freely; past it they stretch; going back is free.
    @Test func weekEndStretches() {
        #expect(CalendarScroll.resisted(-10, travel: -600, cap: 700) == -10)
        #expect(abs(CalendarScroll.resisted(-10, travel: -700, cap: 700) + 1.5) < 0.01)
        #expect(CalendarScroll.resisted(10, travel: -700, cap: 700) == 10)
    }

    /// A gentle swipe lands a day or two on; a normal one carries past half a week to the week.
    @Test func swipesLandOnAWeekOrADay() {
        // 180-point days: a gentle swipe (80 points, 500 a second) moves one day.
        #expect(CalendarScroll.swipeDays(travel: -80, speed: -500, column: 180, days: 7) == 1)
        // A normal swipe (200 points, 1,500 a second) moves the week.
        #expect(CalendarScroll.swipeDays(travel: -200, speed: -1500, column: 180, days: 7) == 7)
        #expect(CalendarScroll.swipeDays(travel: 200, speed: 1500, column: 180, days: 7) == -7)
        // A slow drag stays where it's let go, on the nearer day.
        #expect(CalendarScroll.swipeDays(travel: -380, speed: 0, column: 180, days: 7) == 2)
        // Day: one day at a time.
        #expect(CalendarScroll.swipeDays(travel: -260, speed: 0, column: 400, days: 1) == 1)
    }

    /// A fast swipe in Week lands on the first day of a real week, wherever it began.
    @Test func fastSwipesLockToTheWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        // Thursday 19 November 2026: Monday the 23rd is 4 days on, Monday the 16th 3 days back.
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19))!
        let weeks = CalendarScroll.daysToWeekStart(from: thursday, calendar: calendar)
        #expect(weeks.next == 4 && weeks.previous == -3)
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        #expect(CalendarScroll.daysToWeekStart(from: monday, calendar: calendar) == (7, -7))
        #expect(CalendarScroll.swipeDays(travel: -100, speed: -1500, column: 100, days: 7, daysToWeekStart: weeks) == 4)
        #expect(CalendarScroll.swipeDays(travel: 100, speed: 1500, column: 100, days: 7, daysToWeekStart: weeks) == -3)
        // A gentle swipe: a day or two, never the week's start.
        #expect(CalendarScroll.swipeDays(travel: -60, speed: -300, column: 100, days: 7, daysToWeekStart: weeks) == 2)
    }
}
