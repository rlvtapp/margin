import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct ColleagueCalendarTests {
    /// Colleagues are added once each, never your own mailboxes, each in a colour of their own,
    /// and the list is kept.
    @Test func addsAndRemovesColleagues() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let own = try #require(model.accounts.first).address
        model.addColleague(EmailAddress(name: "Maya Chen", address: "maya@example.com"))
        model.addColleague(EmailAddress(name: "Maya", address: "MAYA@example.com"))
        model.addColleague(own)
        model.addColleague(EmailAddress(name: nil, address: "not an address"))
        model.addColleague(EmailAddress(name: "Sam", address: "sam@example.com"))
        #expect(model.comparedPeople.map(\.id) == ["maya@example.com", "sam@example.com"])
        let colors = model.comparedPeople.map(\.colorIndex) + model.accounts.map(\.colorIndex)
        #expect(Set(colors).count == colors.count)
        #expect(model.environment.defaults.data(forKey: "calendar.compare") != nil)

        model.removeColleague(model.comparedPeople[0])
        #expect(model.comparedPeople.map(\.id) == ["sam@example.com"])
    }

    /// A day shows the busy times that touch it, cut to the day.
    @Test func busyTimesOnADay() async {
        let model = MailModel(environment: .preview())
        let person = ComparedPerson(address: EmailAddress(name: "Sam", address: "sam@example.com"), colorIndex: 2)
        let day = Calendar.current.startOfDay(for: Date())
        model.comparedPeople = [person]
        model.colleagueBusy = [person.id: [
            BusyTime(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(3600)),
            BusyTime(start: day.addingTimeInterval(10 * 3600), end: day.addingTimeInterval(11 * 3600)),
            BusyTime(start: day.addingTimeInterval(30 * 3600), end: day.addingTimeInterval(31 * 3600)),
        ]]
        let busy = model.busyTimes(of: person, on: day)
        #expect(busy.count == 2)
        #expect(busy[0].start == day)
        #expect(busy[1].start == day.addingTimeInterval(10 * 3600))
    }

    /// Free together: working hours when you and everyone compared are free, half an hour or
    /// more; someone whose calendar can't be seen doesn't count as free or busy.
    @Test func freeTogether() async {
        let model = MailModel(environment: .preview())
        let day = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: Date()))!
        func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }
        let sam = ComparedPerson(address: EmailAddress(name: "Sam", address: "sam@example.com"), colorIndex: 2)
        let lee = ComparedPerson(address: EmailAddress(name: "Lee", address: "lee@example.com"), colorIndex: 3)
        model.comparedPeople = [sam, lee]
        model.colleaguesHidden = [lee.id]
        model.colleagueBusy = [sam.id: [BusyTime(start: at(8), end: at(12)), BusyTime(start: at(13), end: at(16.25))]]
        model.showsDeviceCalendar = true
        var mine = CalendarEvent(id: DeviceCalendar.idPrefix + "x", title: "Mine", start: at(16.5), end: at(17), isOrganizer: true)
        mine.calendarName = "Personal"
        model.deviceEvents = [mine]
        let slots = model.freeTogether(on: day, now: day)
        #expect(slots.map(\.start) == [at(12), at(17)])
        #expect(slots.map(\.end) == [at(13), at(18)])
        #expect(model.availability(of: sam, now: at(9)) != nil)
    }

    /// Out of office is read from the calendar, shown until its last day, and never free time;
    /// working elsewhere still counts as free for meetings.
    @Test func outOfOffice() async {
        let model = MailModel(environment: .preview())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let leo = ComparedPerson(address: EmailAddress(name: "Leo", address: "leo@example.com"), colorIndex: 2)
        let ana = ComparedPerson(address: EmailAddress(name: "Ana", address: "ana@example.com"), colorIndex: 3)
        model.comparedPeople = [leo, ana]
        let away = BusyTime(start: today, end: calendar.date(byAdding: .day, value: 2, to: today)!, kind: .outOfOffice)
        model.colleagueBusy = [leo.id: [away],
                               ana.id: [BusyTime(start: today.addingTimeInterval(8 * 3600), end: today.addingTimeInterval(18 * 3600), kind: .workingElsewhere)]]
        let now = today.addingTimeInterval(9 * 3600)
        #expect(model.outOfOffice(leo, at: now) != nil)
        let lastDay = calendar.date(byAdding: .day, value: 1, to: today)!
        #expect(model.availability(of: leo, now: now)?.contains(lastDay.formatted(.dateTime.weekday(.wide))) == true)
        #expect(model.outOfOffice(ana, at: now) == nil)
        model.comparedPeople = [ana]
        #expect(!model.freeTogether(on: today, now: today).isEmpty)
        model.comparedPeople = [leo, ana]
        #expect(model.freeTogether(on: today, now: today).isEmpty)
    }

}

@MainActor @Suite struct ColleagueSuggestionTests {
    /// A shared calendar that isn't a person (a family or group calendar) is never suggested;
    /// someone at your own organization who shared theirs is.
    @Test func leavesOutCalendarsThatArentPeople() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let domain = try #require(model.workDomains.first)
        model.calendarSharers = [
            EmailAddress(name: "Your family", address: "YourFamily_e93fe62429ac4f@outlook.com"),
            EmailAddress(name: "Noor Haddad", address: "noor@\(domain)"),
        ]
        let names = model.colleagueSuggestions(for: "").map(\.address)
        #expect(names == ["noor@\(domain)"])
        #expect(model.colleagueSuggestions(for: "fam").isEmpty)
    }
}
