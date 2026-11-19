import Foundation
import Testing
@testable import MailCore

@Suite struct MeetingTimesTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    let maya = EmailAddress(name: "Maya Chen", address: "maya@example.com")
    let sam = EmailAddress(name: "Sam Ortiz", address: "Sam@example.com")
    let lee = EmailAddress(name: "Lee", address: "lee@elsewhere.example")

    /// Times when you and everyone seen are free, from the next quarter hour, two a day at most
    /// (the start of a gap and, for a long gap, a later hour), weekdays only; anyone whose
    /// calendar can't be seen is unknown, not free.
    @Test func localSuggestionsSkipBusyTimesAndWeekends() {
        // Thursday 2026-11-19, 10:07.
        let now = Self.utc("2026-11-19T10:07:00Z")
        let busy = [
            "maya@example.com": [BusyTime(start: Self.utc("2026-11-19T10:00:00Z"), end: Self.utc("2026-11-19T12:00:00Z"))],
            "sam@example.com": [BusyTime(start: Self.utc("2026-11-19T13:00:00Z"), end: Self.utc("2026-11-19T17:00:00Z")),
                                BusyTime(start: Self.utc("2026-11-20T09:00:00Z"), end: Self.utc("2026-11-20T17:00:00Z"))],
        ]
        let mine = [DateInterval(start: Self.utc("2026-11-23T09:00:00Z"), end: Self.utc("2026-11-23T10:00:00Z"))]
        let times = MeetingTimes.suggest(people: [maya, sam, lee], busy: busy, mine: mine, length: 3600,
                                         from: now, now: now, calendar: Self.calendar)
        #expect(times.map(\.start) == [
            Self.utc("2026-11-19T12:00:00Z"),           // between Maya's and Sam's meetings
            Self.utc("2026-11-23T10:00:00Z"),           // Friday is full, the weekend skipped, after your own event
            Self.utc("2026-11-23T13:00:00Z"),           // the same long gap, the first hour past its middle
            Self.utc("2026-11-24T09:00:00Z"),
            Self.utc("2026-11-24T13:00:00Z"),
        ])
        #expect(times.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
        #expect(times[0].free == [maya, sam] && times[0].unknown == [lee] && times[0].busy.isEmpty)
        #expect(!times[0].fromCalendar)
    }

    /// Working elsewhere doesn't make anyone busy; with nobody seen, your own free time is suggested.
    @Test func workingElsewhereIsFreeAndNobodySeenStillSuggests() {
        let now = Self.utc("2026-11-19T08:00:00Z")
        let away = ["maya@example.com": [BusyTime(start: Self.utc("2026-11-19T09:00:00Z"), end: Self.utc("2026-11-19T17:00:00Z"),
                                                  kind: .workingElsewhere)]]
        let first = MeetingTimes.suggest(people: [maya], busy: away, mine: [], length: 1800, from: now, limit: 1, now: now,
                                         calendar: Self.calendar)
        #expect(first.map(\.start) == [Self.utc("2026-11-19T09:00:00Z")])
        let unseen = MeetingTimes.suggest(people: [lee], busy: [:], mine: [], length: 1800, from: now, limit: 1, now: now,
                                          calendar: Self.calendar)
        #expect(unseen.first?.unknown == [lee] && unseen.first?.free == [])
        #expect(MeetingTimes.busyPeople([maya, sam], busy: away, start: Self.utc("2026-11-19T10:00:00Z"),
                                        end: Self.utc("2026-11-19T11:00:00Z")).isEmpty)
    }

    /// The calendar service's times come first, unless they clash with your own events; the
    /// rest is filled from the local ones, soonest first.
    @Test func mergeKeepsCalendarTimesThatDontClash() {
        func at(_ hour: Int) -> Date { Self.utc("2026-11-20T00:00:00Z").addingTimeInterval(Double(hour) * 3600) }
        let calendar = [SuggestedTime(start: at(14), end: at(15), fromCalendar: true),
                        SuggestedTime(start: at(10), end: at(11), fromCalendar: true)]
        let local = [SuggestedTime(start: at(9), end: at(10)), SuggestedTime(start: at(14), end: at(15)),
                     SuggestedTime(start: at(16), end: at(17))]
        let mine = [DateInterval(start: at(10), end: at(10).addingTimeInterval(1800))]
        let merged = MeetingTimes.merged(calendar: calendar, local: local, mine: mine, limit: 3)
        #expect(merged.map(\.start) == [at(9), at(14), at(16)])
        #expect(merged[1].fromCalendar)
    }

    /// Microsoft 365's findMeetingTimes: the request asks for everyone, all free, in working
    /// hours; the answer (Graph's documented sample, in UTC) gives each time and who's free,
    /// busy or unknown.
    @Test func graphFindMeetingTimes() async throws {
        let api = GraphFakeAPI()
        api.on("/me/findMeetingTimes", #"""
        {"@odata.context":"https://graph.microsoft.com/v1.0/$metadata#microsoft.graph.meetingTimeSuggestionsResult",
         "emptySuggestionsReason":"",
         "meetingTimeSuggestions":[
          {"confidence":100,"order":1,"organizerAvailability":"free",
           "attendeeAvailability":[{"availability":"free","attendee":{"emailAddress":{"address":"maya@example.com"}}},
                                   {"availability":"workingElsewhere","attendee":{"emailAddress":{"address":"sam@example.com"}}}],
           "locations":[],
           "meetingTimeSlot":{"start":{"dateTime":"2026-11-20T15:00:00.0000000","timeZone":"UTC"},
                              "end":{"dateTime":"2026-11-20T16:00:00.0000000","timeZone":"UTC"}}},
          {"confidence":50,"order":2,"organizerAvailability":"tentative",
           "attendeeAvailability":[{"availability":"busy","attendee":{"emailAddress":{"address":"MAYA@example.com"}}},
                                   {"availability":"unknown","attendee":{"emailAddress":{"address":"sam@example.com"}}}],
           "locations":[],
           "meetingTimeSlot":{"start":{"dateTime":"2026-11-20T09:00:00.0000000","timeZone":"UTC"},
                              "end":{"dateTime":"2026-11-20T10:00:00.0000000","timeZone":"UTC"}}}]}
        """#)
        let client = MicrosoftGraphClient(accessToken: "t", send: api.send)
        let times = try await client.meetingTimes(with: [maya, sam], length: 3600, from: Self.utc("2026-11-19T10:15:00Z"),
                                                  to: Self.utc("2026-12-03T00:00:00Z"), limit: 5)
        #expect(times.map(\.start) == [Self.utc("2026-11-20T09:00:00Z"), Self.utc("2026-11-20T15:00:00Z")])
        #expect(times[0].busy == [maya] && times[0].unknown == [sam] && times[0].free.isEmpty)
        #expect(times[1].free == [maya, sam] && times[1].fromCalendar)

        let body = try #require(api.json(of: "findMeetingTimes"))
        #expect(body["meetingDuration"] as? String == "PT60M")
        #expect(body["isOrganizerOptional"] as? Bool == false)
        #expect(body["minimumAttendeePercentage"] as? Int == 100)
        let attendees = try #require(body["attendees"] as? [[String: Any]])
        #expect(attendees.map { ($0["emailAddress"] as? [String: String])?["address"] } == ["maya@example.com", "Sam@example.com"])
        let constraint = try #require(body["timeConstraint"] as? [String: Any])
        #expect(constraint["activityDomain"] as? String == "work")
        #expect(api.requests.first?.value(forHTTPHeaderField: "Prefer") == "outlook.timezone=\"UTC\"")

        let refused = GraphFakeAPI()
        refused.on("/me/findMeetingTimes", status: 403, "{}")
        await #expect(throws: MailError.self) {
            try await MicrosoftGraphClient(accessToken: "t", send: refused.send).meetingTimes(
                with: [maya], length: 1800, from: Self.utc("2026-11-19T10:00:00Z"), to: Self.utc("2026-11-20T10:00:00Z"), limit: 5)
        }
    }
}
