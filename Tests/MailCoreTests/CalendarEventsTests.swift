import Foundation
import Testing
@testable import MailCore

@Suite struct CalendarEventsTests {
    /// Graph's calendar view: UTC times, your answer, the Teams link, all-day days.
    @Test func readsMicrosoftEvents() throws {
        let json = """
        {"value":[
          {"id":"AAMk1","iCalUId":"uid-1","subject":"Design review","isAllDay":false,
           "start":{"dateTime":"2026-11-12T09:00:00.0000000","timeZone":"UTC"},
           "end":{"dateTime":"2026-11-12T09:30:00.0000000","timeZone":"UTC"},
           "location":{"displayName":"Room 4"},"onlineMeeting":{"joinUrl":"https://teams.example/join"},
           "organizer":{"emailAddress":{"name":"Noor","address":"noor@example.com"}},
           "responseStatus":{"response":"tentativelyAccepted"},"isCancelled":false,"isOrganizer":false,"type":"occurrence"},
          {"id":"AAMk2","subject":"Release freeze","isAllDay":true,
           "start":{"dateTime":"2026-11-13T00:00:00.0000000","timeZone":"UTC"},
           "end":{"dateTime":"2026-11-14T00:00:00.0000000","timeZone":"UTC"},
           "responseStatus":{"response":"organizer"},"isOrganizer":true}
        ]}
        """
        let events = try MicrosoftGraphClient.events(from: Data(json.utf8))
        #expect(events.count == 2)
        let review = events[0]
        #expect(review.start == ISO8601DateFormatter().date(from: "2026-11-12T09:00:00Z"))
        #expect(review.response == .tentative)
        #expect(review.joinURL?.host() == "teams.example")
        #expect(review.location == "Room 4")
        #expect(review.repeats)
        let freeze = events[1]
        #expect(freeze.isAllDay && freeze.isOrganizer && freeze.response == nil)
        #expect(Calendar.current.component(.day, from: freeze.start) == 13)
    }

    /// Google's events: RFC 3339 times, all-day dates, your own attendee entry, Meet links.
    @Test func readsGoogleEvents() throws {
        let json = """
        {"items":[
          {"id":"g1","iCalUID":"uid-2@google.com","summary":"Standup","status":"confirmed",
           "start":{"dateTime":"2026-11-12T10:00:00+01:00"},"end":{"dateTime":"2026-11-12T10:15:00+01:00"},
           "hangoutLink":"https://meet.example/abc","organizer":{"email":"sam@example.com"},
           "attendees":[{"email":"me@example.com","self":true,"responseStatus":"accepted"}],"recurringEventId":"r1"},
          {"id":"g2","summary":"Offsite","status":"cancelled","start":{"date":"2026-11-20"},"end":{"date":"2026-11-21"}}
        ]}
        """
        let events = try GoogleCalendarClient.events(from: Data(json.utf8))
        #expect(events[0].start == ISO8601DateFormatter().date(from: "2026-11-12T09:00:00Z"))
        #expect(events[0].response == .accepted)
        #expect(events[0].joinURL?.absoluteString == "https://meet.example/abc")
        #expect(events[0].repeats)
        #expect(events[1].isAllDay && events[1].isCancelled)
    }
}
