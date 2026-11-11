import Foundation
import Testing
@testable import MailCore

/// A pretend server: answers each request from a route table and remembers what was sent.
final class GraphFakeAPI: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(match: String, status: Int, body: String)] = []
    private(set) var requests: [URLRequest] = []

    /// Answers requests whose URL contains `match`; the first matching route wins.
    func on(_ match: String, status: Int = 200, _ body: String) {
        lock.withLock { routes.append((match, status, body)) }
    }

    var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { [self] request in
            let url = request.url!.absoluteString.removingPercentEncoding ?? request.url!.absoluteString
            let route = lock.withLock { () -> (Int, String)? in
                requests.append(request)
                return routes.first { url.contains($0.match) }.map { ($0.status, $0.body) }
            }
            let (status, body) = route ?? (404, #"{"error":{"message":"not found"}}"#)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    func json(of match: String) -> [String: Any]? {
        lock.withLock {
            requests.first { $0.url!.absoluteString.contains(match) }?.httpBody
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func urls() -> [String] { lock.withLock { requests.map { $0.url!.absoluteString.removingPercentEncoding! } } }
}

@Suite struct GraphAndPeopleTests {
    static func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    // MARK: Microsoft Graph

    @Test func graphContactsFollowPagesAndMergePeople() async throws {
        let api = GraphFakeAPI()
        api.on("/me/contacts?$skip=1", #"{"value":[{"id":"c2","displayName":"Sam Lee","emailAddresses":[{"address":"sam@k.example"}]}]}"#)
        api.on("/me/contacts", #"""
        {"value":[{"id":"c1","displayName":"Noor Haddad","companyName":"Postbox","emailAddresses":[{"address":"Noor@postbox.example"},{"address":"not an address"}]}],
         "@odata.nextLink":"https://graph.microsoft.com/v1.0/me/contacts?$skip=1"}
        """#)
        api.on("/me/people", #"""
        {"value":[{"id":"p1","displayName":"Noor H.","scoredEmailAddresses":[{"address":"noor@postbox.example"}]},
                  {"id":"p2","displayName":"Nick Vos","companyName":"Vos","scoredEmailAddresses":[{"address":"nick@vos.example"}]}]}
        """#)
        let client = MicrosoftGraphClient(accessToken: "token", send: api.send)
        let contacts = try await client.contacts()
        #expect(contacts.map(\.id) == ["microsoft:c1", "microsoft:c2", "microsoft:p2"])
        #expect(contacts[0].name == "Noor Haddad" && contacts[0].emails == ["Noor@postbox.example"] && contacts[0].organization == "Postbox")
        #expect(contacts.allSatisfy { $0.source == .microsoft })
        #expect(api.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(api.urls().filter { $0.contains("/me/contacts") }.count == 2)
    }

    @Test func graphRoomsFromPlaces() async throws {
        let api = GraphFakeAPI()
        api.on("/places/microsoft.graph.room", #"""
        {"value":[{"emailAddress":"oak@rooms.example","displayName":"Oak","capacity":8,"building":"North","floorNumber":2},
                  {"emailAddress":"elm@rooms.example","displayName":"Elm","capacity":4,"floorLabel":"Ground"}]}
        """#)
        let rooms = try await MicrosoftGraphClient(accessToken: "t", send: api.send).rooms()
        #expect(rooms == [
            MeetingRoom(email: "elm@rooms.example", name: "Elm", capacity: 4, floor: "Ground"),
            MeetingRoom(email: "oak@rooms.example", name: "Oak", capacity: 8, building: "North", floor: "2"),
        ])
    }

    @Test func graphRoomsFallBackToFindRoomsWhenPlacesIsForbidden() async throws {
        let api = GraphFakeAPI()
        api.on("/places/", status: 403, #"{"error":{"message":"Forbidden"}}"#)
        api.on("/beta/me/findRooms", #"{"value":[{"name":"Willow","address":"willow@rooms.example"},{"name":"Ash","address":"ash@rooms.example"}]}"#)
        let rooms = try await MicrosoftGraphClient(accessToken: "t", send: api.send).rooms()
        #expect(rooms.map(\.name) == ["Ash", "Willow"])

        let denied = GraphFakeAPI()
        denied.on("/places/", status: 403, "{}")
        denied.on("/beta/me/findRooms", status: 403, "{}")
        await #expect(throws: MailError.authenticationFailed(MicrosoftGraphClient.roomsForbidden)) {
            try await MicrosoftGraphClient(accessToken: "t", send: denied.send).rooms()
        }
    }

    @Test func graphScheduleCountsEverythingButFree() async throws {
        let api = GraphFakeAPI()
        api.on("/me/calendar/getSchedule", #"""
        {"value":[{"scheduleId":"Noor@postbox.example","scheduleItems":[
            {"status":"busy","start":{"dateTime":"2026-11-09T10:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-11-09T11:00:00.0000000","timeZone":"UTC"}},
            {"status":"free","start":{"dateTime":"2026-11-09T12:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-11-09T13:00:00.0000000","timeZone":"UTC"}},
            {"status":"oof","start":{"dateTime":"2026-11-09T08:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-11-09T09:30:00.0000000","timeZone":"UTC"}}]},
          {"scheduleId":"oak@rooms.example","scheduleItems":[
            {"status":"tentative","start":{"dateTime":"2026-11-09T14:15:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-11-09T15:00:00.0000000","timeZone":"UTC"}}]}]}
        """#)
        let client = MicrosoftGraphClient(accessToken: "t", send: api.send)
        let busy = try await client.busyTimes(for: ["Noor@postbox.example", "oak@rooms.example"],
                                              from: Self.utc("2026-11-09T00:00:00Z"), to: Self.utc("2026-11-10T00:00:00Z"))
        #expect(busy["noor@postbox.example"] == [
            BusyTime(start: Self.utc("2026-11-09T08:00:00Z"), end: Self.utc("2026-11-09T09:30:00Z")),
            BusyTime(start: Self.utc("2026-11-09T10:00:00Z"), end: Self.utc("2026-11-09T11:00:00Z")),
        ])
        #expect(busy["oak@rooms.example"] == [BusyTime(start: Self.utc("2026-11-09T14:15:00Z"), end: Self.utc("2026-11-09T15:00:00Z"))])

        let body = try #require(api.json(of: "getSchedule"))
        #expect(body["schedules"] as? [String] == ["Noor@postbox.example", "oak@rooms.example"])
        #expect((body["startTime"] as? [String: String]) == ["dateTime": "2026-11-09T00:00:00", "timeZone": "UTC"])
        #expect(body["availabilityViewInterval"] as? Int == 15)
        #expect(api.requests.first?.httpMethod == "POST")
    }

    @Test func graphCreateEventInvitesPeopleAndBooksRooms() async throws {
        let api = GraphFakeAPI()
        api.on("/me/events", status: 201, #"{"id":"e1"}"#)
        let meeting = MeetingRequest(
            uid: "m-1", title: "Planning", start: Self.utc("2026-11-12T09:00:00Z"), end: Self.utc("2026-11-12T10:00:00Z"),
            notes: "Agenda to follow", organizer: EmailAddress(name: "Alex", address: "alex@example.com"),
            attendees: [EmailAddress(name: "Noor Haddad", address: "noor@postbox.example")],
            rooms: [MeetingRoom(email: "oak@rooms.example", name: "Oak")])
        try await MicrosoftGraphClient(accessToken: "t", send: api.send).createEvent(meeting)

        let body = try #require(api.json(of: "/me/events"))
        #expect(body["subject"] as? String == "Planning")
        #expect((body["start"] as? [String: String]) == ["dateTime": "2026-11-12T09:00:00", "timeZone": "UTC"])
        #expect((body["location"] as? [String: String])?["displayName"] == "Oak")
        let attendees = try #require(body["attendees"] as? [[String: Any]])
        #expect(attendees.map { $0["type"] as? String } == ["required", "resource"])
        #expect((attendees[1]["emailAddress"] as? [String: String])?["address"] == "oak@rooms.example")
    }

    @Test func expiredTokenIsAnAuthenticationError() async {
        let api = GraphFakeAPI()
        api.on("/", status: 401, #"{"error":{"message":"InvalidAuthenticationToken"}}"#)
        await #expect(throws: MailError.self) { try await MicrosoftGraphClient(accessToken: "old", send: api.send).contacts() }
        do {
            _ = try await GooglePeopleClient(accessToken: "old", send: api.send).contacts()
            Issue.record("expected an error")
        } catch let error as MailError {
            guard case .authenticationFailed = error else { Issue.record("wrong error \(error)"); return }
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func graphDatesWithSevenFractionDigits() {
        let date = MicrosoftGraphClient.parseGraphDate(GraphDateTime(dateTime: "2026-11-09T10:00:00.0000000", timeZone: "UTC"))
        #expect(date == Self.utc("2026-11-09T10:00:00Z"))
        let amsterdam = MicrosoftGraphClient.parseGraphDate(GraphDateTime(dateTime: "2026-11-09T11:00:00.0000000", timeZone: "Europe/Amsterdam"))
        #expect(amsterdam == Self.utc("2026-11-09T10:00:00Z"))
    }

    // MARK: Google People

    @Test func googleConnectionsAndOtherContactsFollowPageTokens() async throws {
        let api = GraphFakeAPI()
        api.on("connections?personFields=names,emailAddresses,organizations,photos&pageSize=1000&pageToken=two", #"""
        {"connections":[{"resourceName":"people/c2","names":[{"displayName":"Sam Lee"}],"emailAddresses":[{"value":"sam@k.example"}]}]}
        """#)
        api.on("connections", #"""
        {"connections":[{"resourceName":"people/c1","names":[{"displayName":"Noor Haddad"}],"emailAddresses":[{"value":"noor@postbox.example"}],"organizations":[{"name":"Postbox"}]},
                        {"resourceName":"people/c9","names":[{"displayName":"No Mail"}]}],
         "nextPageToken":"two"}
        """#)
        api.on("otherContacts", #"""
        {"otherContacts":[{"resourceName":"otherContacts/o1","emailAddresses":[{"value":"NOOR@postbox.example"}]},
                          {"resourceName":"otherContacts/o2","names":[{"displayName":"Nick Vos"}],"emailAddresses":[{"value":"nick@vos.example"}]}]}
        """#)
        let contacts = try await GooglePeopleClient(accessToken: "t", send: api.send).contacts()
        #expect(contacts.map(\.id) == ["google:people/c1", "google:people/c2", "google:otherContacts/o2"])
        #expect(contacts[0].organization == "Postbox" && contacts.allSatisfy { $0.source == .google })
        #expect(api.urls().contains { $0.contains("otherContacts?readMask=names,emailAddresses,photos&pageSize=1000") })
    }

    // MARK: Invitations

    static let meeting = MeetingRequest(
        uid: "plan-42@margin", title: "Quarterly planning, with everyone; bring notes",
        start: utc("2026-11-12T09:00:00Z"), end: utc("2026-11-12T10:30:00Z"), location: "Somewhere",
        notes: "First line\nSecond line", organizer: EmailAddress(name: "Alex Example", address: "alex@example.com"),
        attendees: [EmailAddress(name: "Noor Haddad", address: "noor@postbox.example")],
        rooms: [MeetingRoom(email: "oak-conference-room-north-building@rooms.example", name: "Oak Conference Room (North Building, 2nd floor)")])

    @Test func meetingRequestIsAFoldedICalendarRequest() throws {
        let text = Self.meeting.iCalendar(now: Self.utc("2026-11-09T08:00:00Z"))
        #expect(text.hasSuffix("\r\n"))
        let lines = text.components(separatedBy: "\r\n").dropLast()
        #expect(lines.allSatisfy { $0.utf8.count <= 75 })
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(lines.contains("METHOD:REQUEST"))
        #expect(lines.contains("DTSTART:20261112T090000Z") && lines.contains("DTEND:20261112T103000Z"))
        #expect(lines.contains("DTSTAMP:20261109T080000Z") && lines.contains("SEQUENCE:0"))

        let unfolded = CalendarInvite.unfold(text)
        #expect(unfolded.contains("ORGANIZER;CN=\"Alex Example\":mailto:alex@example.com"))
        #expect(unfolded.contains("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=\"Noor Haddad\":mailto:noor@postbox.example"))
        #expect(unfolded.contains(
            "ATTENDEE;CUTYPE=ROOM;ROLE=NON-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=\"Oak Conference Room (North Building, 2nd floor)\":mailto:oak-conference-room-north-building@rooms.example"))
        #expect(unfolded.contains("LOCATION:Oak Conference Room (North Building\\, 2nd floor)"))
        #expect(unfolded.contains("DESCRIPTION:First line\\nSecond line"))

        let invite = try #require(CalendarInvite.parse(text))
        #expect(invite.uid == "plan-42@margin" && invite.method == "REQUEST" && invite.sequence == 0)
        #expect(invite.summary == "Quarterly planning, with everyone; bring notes")
        #expect(invite.start == Self.utc("2026-11-12T09:00:00Z") && invite.end == Self.utc("2026-11-12T10:30:00Z"))
        #expect(invite.location == "Oak Conference Room (North Building, 2nd floor)")
        #expect(invite.organizer == EmailAddress(name: "Alex Example", address: "alex@example.com"))
    }

    @Test func foldingNeverSplitsACharacter() {
        let line = "SUMMARY:" + String(repeating: "é", count: 80)
        let folded = MeetingRequest.fold(line)
        let pieces = folded.components(separatedBy: "\r\n")
        #expect(pieces.count > 1 && pieces.allSatisfy { $0.utf8.count <= 75 })
        #expect(CalendarInvite.unfold(folded) == [line])
    }

    @Test func messageBuilderUsesTheCalendarsMethod() {
        var draft = Draft(from: EmailAddress(address: "alex@example.com"), to: [EmailAddress(address: "noor@postbox.example")],
                          subject: "Planning", text: "See you there")
        draft.calendar = Self.meeting.iCalendar()
        let request = String(decoding: MessageBuilder.build(draft, boundary: "b"), as: UTF8.self)
        #expect(request.contains("Content-Type: text/calendar; method=REQUEST; charset=utf-8"))

        draft.calendar = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let unnamed = String(decoding: MessageBuilder.build(draft, boundary: "b"), as: UTF8.self)
        #expect(unnamed.contains("Content-Type: text/calendar; method=REPLY; charset=utf-8"))
    }
}

@Suite struct DirectorySearchTests {
    @Test func searchesTheOrganizationsPeople() async throws {
        let api = GraphFakeAPI()
        api.on("me/people", #"{"value":[{"id":"1","displayName":"Gillian de Vries","scoredEmailAddresses":[{"address":"gillian@relevate.app"}]},{"id":"2","displayName":"No mail","scoredEmailAddresses":[]}]}"#)
        let found = try await MicrosoftGraphClient(accessToken: "t", send: api.send).searchPeople("gil")
        #expect(found == [EmailAddress(name: "Gillian de Vries", address: "gillian@relevate.app")])
        let url = try #require(api.requests.first?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains(#"$search="gil""#))
        #expect(url.contains("$top=8"))
    }
}
