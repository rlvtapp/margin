import Foundation
import Testing
@testable import MailCore

@Suite struct GoogleCalendarTests {
    @Test func listsRoomsFromTheWorkspaceDirectory() async throws {
        let api = GraphFakeAPI()
        api.on("resources/calendars", #"""
        {"items": [
          {"resourceEmail": "c_2@resource.calendar.google.com", "resourceName": "Studio", "generatedResourceName": "HQ-2-Studio (8)", "capacity": 8, "floorName": "2"},
          {"resourceEmail": "c_1@resource.calendar.google.com", "resourceName": "Atrium", "capacity": 20},
          {"resourceEmail": "c_3@resource.calendar.google.com", "resourceName": "Projector", "resourceCategory": "OTHER"}
        ]}
        """#)
        let rooms = try await GoogleCalendarClient(accessToken: "t", send: api.send).rooms()
        #expect(rooms.map(\.name) == ["Atrium", "HQ-2-Studio (8)"])
        #expect(rooms.last?.capacity == 8)
        #expect(rooms.last?.floor == "2")
    }

    @Test func roomListingForbiddenSaysToAddByAddress() async {
        let api = GraphFakeAPI()
        api.on("resources/calendars", status: 403, #"{"error":{"message":"Not Authorized to access this resource/api"}}"#)
        await #expect(throws: MailError.self) { try await GoogleCalendarClient(accessToken: "t", send: api.send).rooms() }
    }

    @Test func readsFreeBusy() async throws {
        let api = GraphFakeAPI()
        api.on("freeBusy", #"""
        {"calendars": {"Room@resource.calendar.google.com": {"busy": [{"start": "2026-11-10T09:00:00Z", "end": "2026-11-10T10:00:00Z"}]},
                       "maya@example.com": {"busy": []}}}
        """#)
        let start = ISO8601DateFormatter().date(from: "2026-11-10T08:00:00Z")!
        let busy = try await GoogleCalendarClient(accessToken: "t", send: api.send)
            .busyTimes(for: ["Room@resource.calendar.google.com", "maya@example.com"], from: start, to: start.addingTimeInterval(4 * 3600))
        #expect(busy["room@resource.calendar.google.com"]?.count == 1)
        #expect(busy["maya@example.com"]?.isEmpty == true)
        let body = try #require(api.json(of: "freeBusy"))
        #expect(body["timeMin"] as? String == "2026-11-10T08:00:00Z")
        #expect((body["items"] as? [[String: String]])?.count == 2)
    }

    @Test func createsTheEventWithTheRoomAsAResource() async throws {
        let api = GraphFakeAPI()
        api.on("calendars/primary/events", #"{"id": "e1"}"#)
        let start = ISO8601DateFormatter().date(from: "2026-11-10T09:00:00Z")!
        let meeting = MeetingRequest(uid: "u1", title: "Planning", start: start, end: start.addingTimeInterval(1800), notes: "Agenda",
                                     organizer: EmailAddress(address: "me@example.com"),
                                     attendees: [EmailAddress(name: "Maya", address: "maya@example.com")],
                                     rooms: [MeetingRoom(email: "c_1@resource.calendar.google.com", name: "Atrium")])
        try await GoogleCalendarClient(accessToken: "t", send: api.send).createEvent(meeting)
        #expect(api.urls().first?.contains("sendUpdates=all") == true)
        let body = try #require(api.json(of: "calendars/primary/events"))
        let attendees = try #require(body["attendees"] as? [[String: Any]])
        #expect(attendees.count == 2)
        #expect(attendees.last?["resource"] as? Bool == true)
        #expect(body["location"] as? String == "Atrium")
        #expect((body["start"] as? [String: String])?["dateTime"] == "2026-11-10T09:00:00Z")
    }

    @Test func contactsFillInNamesAndComeAfterPeopleFromMail() {
        let me = EmailAddress(address: "alex@example.com")
        let noor = EmailAddress(address: "noor@postbox.example")
        let sent = MailMessage(id: "1", mailboxID: "Sent", from: me, to: [noor], subject: "Hi", date: Date())
        let book = AddressBook(threads: [MailThread(id: "a", messages: [sent])], me: [me.address],
                               contacts: [EmailAddress(name: "Noor Haddad", address: "noor@postbox.example"),
                                          EmailAddress(name: "Nina Berg", address: "nina@berg.example")])
        #expect(book.entries.map(\.address) == ["noor@postbox.example", "nina@berg.example"])
        #expect(book.entries.first?.name == "Noor Haddad")
        #expect(book.suggestions(for: "ni").map(\.address) == ["nina@berg.example"])
    }
}
