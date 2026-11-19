import Foundation
import MailCore
import Testing
@testable import MailUI

/// Suggested times (docs/calendar.md): times that suit you and the people invited.
@MainActor @Suite struct SuggestedTimesTests {
    /// A Monday well away from the sample mail's events.
    var monday: Date {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2030, month: 3, day: 4))!
        return calendar.startOfDay(for: start)
    }

    func at(_ day: Int, _ hour: Double) -> Date { monday.addingTimeInterval(Double(day) * 86_400 + hour * 3600) }

    let sam = EmailAddress(name: "Sam", address: "sam@example.com")
    let lee = EmailAddress(name: "Lee", address: "lee@elsewhere.example")

    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.colleagueBusy = ["sam@example.com": [BusyTime(start: at(0, 9), end: at(0, 12)), BusyTime(start: at(1, 9), end: at(1, 17))]]
        model.showsDeviceCalendar = true
        var mine = CalendarEvent(id: DeviceCalendar.idPrefix + "x", title: "Dentist", start: at(0, 12), end: at(0, 13), isOrganizer: true)
        mine.calendarName = "Personal"
        model.deviceEvents = [mine]
        return model
    }

    /// Your own events in any calendar and everyone's busy times are skipped; the busy day
    /// is passed over; whoever can't be seen is said to be unknown.
    @Test func suggestsTimesThatSuitEveryone() async {
        let model = await model()
        let times = await model.suggestTimes(with: [sam, lee], length: 3600, from: at(0, 8), in: nil, now: at(0, 8))
        #expect(times.count == 5)
        #expect(times.first?.start == at(0, 13))
        for time in times {
            #expect(!(time.start < at(0, 13) && time.start >= at(0, 9)))
            #expect(Calendar.current.startOfDay(for: time.start) != at(1, 0))
            #expect(time.unknown == [lee] && time.free == [sam])
        }
        #expect(times.map(\.start) == times.map(\.start).sorted())
    }

    /// "Sam is busy then" follows the time chosen.
    @Test func saysWhoIsBusyThen() async {
        let model = await model()
        #expect(await model.busyPeople([sam, lee], from: at(0, 10), to: at(0, 11), in: nil) == [sam])
        #expect(await model.busyPeople([sam, lee], from: at(0, 14), to: at(0, 15), in: nil).isEmpty)
    }

    /// The chips say a day and a time in the person's own words.
    @Test func chipLabels() {
        let now = at(0, 8)
        #expect(SuggestedTimesRow.label(at(3, 14.5), now: now) == at(3, 14.5).formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        #expect(SuggestedTimesRow.label(at(10, 9), now: now) == at(10, 9).formatted(.dateTime.day().month(.abbreviated).hour().minute()))
    }

    /// AI apps get the same times over MCP, reading only.
    @Test func mcpTool() async throws {
        let model = await model()
        var settings = model.connectionSettings
        settings.enabled = true
        model.connectionSettings = settings
        let text = try await MailToolbox(model: model).call("suggest_meeting_times", arguments: [
            "people": .array([.string("sam@example.com"), .string("lee@elsewhere.example")]), "minutes": .number(60),
            "start": .string(MailModel.iso(at(0, 8))),
        ])
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let times = try #require(answer["times"] as? [[String: Any]])
        #expect(times.first?["start"] as? String == MailModel.iso(at(0, 13)))
        #expect(times.first?["unknown"] as? [String] == ["lee@elsewhere.example"])
        #expect(times.first?["suggested_by"] as? String == "margin")
        await #expect(throws: MCPToolError.self) {
            try await MailToolbox(model: model).call("suggest_meeting_times", arguments: ["people": .array([.string("nope")]), "minutes": .number(30)])
        }
    }
}
