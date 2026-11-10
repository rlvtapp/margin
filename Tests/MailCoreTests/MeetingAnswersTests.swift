import Foundation
import Testing
@testable import MailCore

@Suite struct MeetingAnswersTests {
    static let request = """
    BEGIN:VCALENDAR\r
    METHOD:REQUEST\r
    BEGIN:VEVENT\r
    UID:m-1\r
    SUMMARY:Planning\r
    DTSTART:20261110T090000Z\r
    DTEND:20261110T093000Z\r
    ORGANIZER;CN=Alex:mailto:alex@example.com\r
    ATTENDEE;CN=Maya Lind;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:maya@example.com\r
    ATTENDEE;CN=Noor;ROLE=OPT-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:noor@example.com\r
    ATTENDEE;CUTYPE=ROOM;CN=Atrium;PARTSTAT=ACCEPTED:mailto:atrium@example.com\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    @Test func readsWhoIsInvitedAndTheirAnswers() throws {
        let invite = try #require(CalendarInvite.parse(Self.request))
        #expect(invite.attendees.map(\.address.address) == ["maya@example.com", "noor@example.com", "atrium@example.com"])
        #expect(invite.attendees[0].response == .accepted)
        #expect(invite.attendees[1].kind == .optional)
        #expect(invite.attendees[1].response == nil)
        #expect(invite.attendees[2].kind == .room)
        let tally = invite.attendees.tally
        #expect(tally.yes == 1 && tally.waiting == 1 && tally.no == 0)
    }

    @Test func aReplyUpdatesOnePersonsAnswer() throws {
        let invite = try #require(CalendarInvite.parse(Self.request))
        let reply = try #require(CalendarInvite.parse(invite.reply(from: EmailAddress(address: "Noor@example.com"), status: .declined)))
        #expect(reply.method == "REPLY")
        let updated = invite.attendees.updating(with: reply.attendees)
        #expect(updated.first { $0.id == "noor@example.com" }?.response == .declined)
        #expect(updated.first { $0.id == "noor@example.com" }?.address.name == "Noor")
        #expect(updated.count == 3)
    }

    @Test func aSentMeetingReadsBackWithEveryoneWaiting() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = MeetingRequest(uid: "m-2", title: "Sync", start: start, end: start.addingTimeInterval(1800),
                                     organizer: EmailAddress(address: "alex@example.com"),
                                     attendees: [EmailAddress(name: "Maya", address: "maya@example.com")],
                                     rooms: [MeetingRoom(email: "atrium@example.com", name: "Atrium")])
        let invite = try #require(CalendarInvite.parse(meeting.iCalendar()))
        #expect(invite.attendees.map(\.kind) == [.required, .room])
        #expect(invite.attendees.allSatisfy { $0.response == nil })
    }

    @Test func emailCalendarSendsTheInvitationAsMail() async throws {
        actor Box { var drafts: [Draft] = []; func add(_ draft: Draft) { drafts.append(draft) } }
        let box = Box()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let adapter = EmailCalendar(organizer: EmailAddress(address: "alex@example.com")) { await box.add($0) }
        try await adapter.createEvent(MeetingRequest(title: "Sync", start: start, end: start.addingTimeInterval(1800),
                                                     organizer: EmailAddress(address: "alex@example.com"),
                                                     attendees: [EmailAddress(address: "maya@example.com")]))
        let draft = try #require(await box.drafts.first)
        #expect(draft.to.map(\.address) == ["maya@example.com"])
        #expect(draft.calendar?.contains("METHOD:REQUEST") == true)
        #expect(try await adapter.rooms().isEmpty)
        #expect(try await adapter.attendees(ofEventWithUID: "x") == nil)
    }

    @Test func microsoftAnswersComeFromTheEvent() async throws {
        let api = GraphFakeAPI()
        api.on("/me/events", #"""
        {"value": [{"attendees": [
          {"type": "required", "status": {"response": "accepted"}, "emailAddress": {"name": "Maya", "address": "maya@example.com"}},
          {"type": "optional", "status": {"response": "notResponded"}, "emailAddress": {"address": "noor@example.com"}},
          {"type": "resource", "status": {"response": "accepted"}, "emailAddress": {"name": "Atrium", "address": "atrium@example.com"}},
          {"type": "required", "status": {"response": "tentativelyAccepted"}, "emailAddress": {"address": "sam@example.com"}}
        ]}]}
        """#)
        let found = try #require(try await MicrosoftGraphClient(accessToken: "t", send: api.send).attendees(ofEventWithUID: "m-1"))
        #expect(found.map(\.response) == [.accepted, nil, .accepted, .tentative])
        #expect(found.map(\.kind) == [.required, .optional, .room, .required])
        #expect(api.urls().first?.contains("iCalUId eq 'm-1'") == true)
    }

    @Test func googleAnswersComeFromTheEvent() async throws {
        let api = GraphFakeAPI()
        api.on("calendars/primary/events", #"""
        {"items": [{"attendees": [
          {"email": "maya@example.com", "displayName": "Maya", "responseStatus": "declined"},
          {"email": "c_1@resource.calendar.google.com", "resource": true, "responseStatus": "accepted"},
          {"email": "noor@example.com", "optional": true, "responseStatus": "needsAction"}
        ]}]}
        """#)
        let found = try #require(try await GoogleCalendarClient(accessToken: "t", send: api.send).attendees(ofEventWithUID: "m-1"))
        #expect(found.map(\.response) == [.declined, .accepted, nil])
        #expect(found.map(\.kind) == [.required, .room, .optional])
    }
}
