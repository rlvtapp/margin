import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct CalendarPageTests {
    /// The same meeting in the account's calendar and as an invitation shows once; an invitation
    /// only in the mail shows too; cancelled ones don't.
    @Test func mergesCalendarAndInvitations() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Date().addingTimeInterval(3600)
        model.calendarEvents[account.id] = [
            CalendarEvent(id: "e1", uid: "shared-uid", title: "Design review", start: start, end: start.addingTimeInterval(1800)),
            CalendarEvent(id: "e2", title: "Called off", start: start, end: start.addingTimeInterval(1800), isCancelled: true),
        ]
        var shared = CalendarEntry(id: "shared-uid", title: "Design review", start: start, end: start.addingTimeInterval(1800),
                                   isAllDay: false, threadID: "t1", cancelled: false)
        shared.accountID = account.id
        var mailOnly = CalendarEntry(id: "mail-uid", title: "Lunch", start: start.addingTimeInterval(7200), end: nil,
                                     isAllDay: false, threadID: "t2", cancelled: false)
        mailOnly.accountID = account.id
        model.saveCalendar([shared, mailOnly])

        let items = model.agenda(from: Date(), to: Date().addingTimeInterval(86_400 * 2))
        #expect(items.map(\.title) == ["Design review", "Lunch"])
        #expect(items[0].source == .account(account.id, eventID: "e1"))
        #expect(items[1].source == .invite(threadID: "t2", accountID: account.id))
        #expect(model.daysWithEvents(from: Calendar.current.startOfDay(for: Date()), to: Date().addingTimeInterval(86_400 * 2))
            .contains(Calendar.current.startOfDay(for: start)))
    }

    /// A meeting declined in another app leaves its mailbox's calendar but its invitation stays in
    /// the mail: once it was seen on that calendar and is gone from it, the old invitation doesn't
    /// bring it back. One never seen there (not answered yet) still shows.
    @Test func aMeetingDeclinedElsewhereGoes() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Date().addingTimeInterval(3 * 86_400)
        var declined = CalendarEntry(id: "declined-uid", title: "Vendor call", start: start, end: start.addingTimeInterval(1800),
                                     isAllDay: false, threadID: "t1", cancelled: false)
        declined.accountID = account.id
        model.saveCalendar([declined])
        let range = { model.agenda(from: Date(), to: Date().addingTimeInterval(7 * 86_400)).map(\.title) }
        #expect(range() == ["Vendor call"])

        model.calendarEventsRange = Date().addingTimeInterval(-86_400)...Date().addingTimeInterval(30 * 86_400)
        model.calendarEvents[account.id] = []
        model.noteInvitationsOnCalendars()
        #expect(range() == ["Vendor call"], "not on the calendar yet: still an invitation to answer")

        model.calendarEvents[account.id] = [CalendarEvent(id: "e1", uid: "declined-uid", title: "Vendor call",
                                                          start: start, end: start.addingTimeInterval(1800))]
        model.noteInvitationsOnCalendars()
        model.calendarEvents[account.id] = []
        #expect(range().isEmpty)
        #expect(model.upcomingEvents.isEmpty)

        model.calendarEvents[account.id] = nil
        #expect(range() == ["Vendor call"], "a calendar that wasn't read says nothing")

        // Declined here or elsewhere (the answer is in the mail): off the Calendar page, still known.
        model.calendarEvents[account.id] = nil
        var answered = declined
        answered.attendees = [MeetingAttendee(address: account.address, response: .declined)]
        model.saveCalendar([answered])
        let week = (Date(), Date().addingTimeInterval(7 * 86_400))
        #expect(model.calendarItems(from: week.0, to: week.1).isEmpty)
        #expect(model.agenda(from: week.0, to: week.1).map(\.response) == [.declined])
    }

    /// Microsoft gives a meeting from elsewhere its own id, carrying the invitation's UID, and
    /// a different id per occurrence: the invitation and the calendar's event are still one item,
    /// which opens the invitation's mail.
    @Test func mergesWhenMicrosoftRewritesTheUID() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Date().addingTimeInterval(3600)
        let marker = Array("vCal-Uid".utf8) + [1, 0, 0, 0] + Array("abc-123@example.com".utf8) + [0]
        var bytes: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0x82, 0x00, 0xE0, 0x00, 0x74, 0xC5, 0xB7, 0x10, 0x1A, 0x82, 0xE0, 0x08,
                              0x07, 0xEA, 0x0B, 0x13] + Array(repeating: 0, count: 20)
        bytes += [UInt8(marker.count), 0, 0, 0] + marker
        let exchangeID = bytes.map { String(format: "%02X", $0) }.joined()
        model.calendarEvents[account.id] = [
            CalendarEvent(id: "e1", uid: exchangeID, title: "Kickoff", start: start, end: start.addingTimeInterval(1800)),
        ]
        var invite = CalendarEntry(id: "ABC-123@example.com", title: "Kickoff", start: start, end: start.addingTimeInterval(1800),
                                   isAllDay: false, threadID: "t1", cancelled: false)
        invite.accountID = account.id
        model.saveCalendar([invite])
        let items = model.agenda(from: Date(), to: Date().addingTimeInterval(86_400))
        #expect(items.count == 1)
        #expect(items.first?.source == .account(account.id, eventID: "e1"))
        #expect(items.first?.invitationThreadID == "t1")
    }

    /// No UID in common, but the same title at the same time: still one item.
    @Test func mergesSameTitleAndTime() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Date().addingTimeInterval(7200)
        model.calendarEvents[account.id] = [
            CalendarEvent(id: "e1", uid: "calendar-own-id", title: "Weekly sync", start: start, end: start.addingTimeInterval(1800)),
        ]
        var invite = CalendarEntry(id: "mail-uid", title: "Weekly sync ", start: start, end: start.addingTimeInterval(1800),
                                   isAllDay: false, threadID: "t9", cancelled: false)
        invite.accountID = account.id
        model.saveCalendar([invite])
        let items = model.agenda(from: Date(), to: Date().addingTimeInterval(86_400))
        #expect(items.count == 1)
        #expect(items.first?.invitationThreadID == "t9")
    }

    /// Occurrences of a repeating Microsoft meeting differ only in the day bytes.
    @Test func occurrenceIDsShareTheSeriesUID() {
        let series = "040000008200E00074C5B7101A82E00800000000A0B1C2D3E4F5A6B7C8D9E0F1"
        let occurrence = "040000008200E00074C5B7101A82E00807EA0B13A0B1C2D3E4F5A6B7C8D9E0F1"
        #expect(MailModel.meetingUID(series) == MailModel.meetingUID(occurrence))
        #expect(MailModel.meetingUID("Plain-UID@Example.com") == "plain-uid@example.com")
    }

    /// Meetings from the calendar reach Ask's facts.
    @Test func askKnowsTheCalendar() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Date().addingTimeInterval(86_400)
        model.calendarEvents[account.id] = [CalendarEvent(id: "e1", title: "Board meeting", start: start, end: start.addingTimeInterval(3600))]
        #expect(model.askFacts().contains("Board meeting"))
    }
}

@MainActor @Suite struct InvitationsInSavedMailTests {
    /// Outlook moves an answered invitation to Deleted Items and your answer sits in Sent:
    /// the meeting still shows, with your answer.
    @Test func findsAnsweredInvitationsInOtherFolders() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let me = account.address
        let sam = EmailAddress(name: "Sam", address: "sam@example.com")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let start = Date().addingTimeInterval(7 * 86_400)
        let ics = """
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r
        BEGIN:VEVENT\r
        UID:second-round@example.com\r
        SUMMARY:Second round\r
        DTSTART:\(formatter.string(from: start))\r
        DTEND:\(formatter.string(from: start.addingTimeInterval(5400)))\r
        ORGANIZER;CN=Sam:mailto:sam@example.com\r
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:\(me.address)\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let invite = try #require(CalendarInvite.parse(ics))
        let invitation = MailMessage(id: "inv", mailboxID: "Deleted Items", messageID: "inv@example.com", from: sam, to: [me],
                                     subject: "Invitation: Second round", date: Date().addingTimeInterval(-2 * 86_400),
                                     calendarMethod: "REQUEST")
        let answer = try #require(CalendarInvite.parse(invite.reply(from: me, status: .accepted)))
        let reply = MailMessage(id: "ans", mailboxID: "Sent", messageID: "ans@example.com", from: me, to: [sam],
                                subject: "Accepted: Second round", date: Date().addingTimeInterval(-86_400), calendarMethod: "REPLY")
        let cache = model.environment.cache
        await cache.saveThreads([MailThread(id: "inv", messages: [invitation])], account: account.id, mailbox: "Deleted Items")
        await cache.saveThreads([MailThread(id: "ans", messages: [reply])], account: account.id, mailbox: "Sent")
        await cache.saveBody(MessageBody(text: "", invite: invite), of: invitation, account: account.id)
        await cache.saveBody(MessageBody(text: "", invite: answer), of: reply, account: account.id)

        await model.findInvitesInSavedMail()

        let item = try #require(model.agenda(from: Date(), to: Date().addingTimeInterval(14 * 86_400)).first { $0.title == "Second round" })
        #expect(item.response == .accepted)
        #expect(item.organizer == "Sam")
    }
}

@MainActor @Suite struct AnswerDataTests {
    /// Your answer in Sent marks the meeting as Going from its calendar data; its subject isn't read.
    @Test func answerFromYourReplyCounts() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Date().addingTimeInterval(86_400)
        var entry = CalendarEntry(id: "uid-1", title: "Uitnodiging eerste gesprek", start: start, end: nil, isAllDay: false,
                                  threadID: "t", cancelled: false)
        entry.accountID = account.id
        entry.attendees = [MeetingAttendee(address: account.address, kind: .required, response: nil)]
        model.saveCalendar([entry])
        let ics = """
        BEGIN:VCALENDAR\r
        METHOD:REPLY\r
        BEGIN:VEVENT\r
        UID:uid-1\r
        SUMMARY:Uitnodiging eerste gesprek\r
        DTSTART:20991201T150000Z\r
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:\(account.address.address)\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let reply = MailMessage(id: "r", mailboxID: "Sent", messageID: "r@x", from: account.address, to: [],
                                subject: "Re", date: Date(), calendarMethod: "REPLY",
                                body: MessageBody(text: "", invite: CalendarInvite.parse(ics)))
        model.bodies[MailModel.bodyKey(account.id, reply.id)] = reply.body
        model.noteInvites(in: MailModel.tag(MailThread(id: "r", messages: [reply]), account: account.id))
        #expect(model.agenda(from: Date(), to: Date().addingTimeInterval(2 * 86_400)).first { $0.title == "Uitnodiging eerste gesprek" }?.response == .accepted)
    }
}

@MainActor @Suite struct InviteClashTests {
    /// An invitation says what else is on then: not itself (by UID or title and time), not
    /// all-day events, not meetings you declined.
    @Test func findsWhatElseIsOn() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3 * 86_400 + 10 * 3600)
        var declined = CalendarEvent(id: "e3", title: "Skipped", start: start, end: start.addingTimeInterval(3600))
        declined.response = .declined
        model.calendarEvents[account.id] = [
            CalendarEvent(id: "e1", uid: "invite-uid", title: "Kickoff", start: start, end: start.addingTimeInterval(1800)),
            CalendarEvent(id: "e2", title: "Dentist", start: start.addingTimeInterval(900), end: start.addingTimeInterval(2700)),
            CalendarEvent(id: "e4", title: "Offsite", start: Calendar.current.startOfDay(for: start), end: Calendar.current.startOfDay(for: start).addingTimeInterval(86_400), isAllDay: true),
            declined,
        ]
        let clashes = model.clashes(start: start, end: start.addingTimeInterval(1800), uid: "INVITE-UID", title: "Kickoff")
        #expect(clashes.map(\.title) == ["Dentist"])
    }
}

@MainActor @Suite struct AnswerElsewhereTests {
    static func reply(_ response: String, from address: String) -> CalendarInvite {
        CalendarInvite.parse("""
        BEGIN:VCALENDAR
        METHOD:REPLY
        BEGIN:VEVENT
        UID:meeting-uid
        SEQUENCE:0
        DTSTART:20301107T090000Z
        SUMMARY:Vendor call
        ATTENDEE;PARTSTAT=\(response):mailto:\(address)
        END:VEVENT
        END:VCALENDAR
        """)!
    }

    /// Accepted in Margin, declined later in another app (its reply is in Sent): declined wins.
    /// The older acceptance read again afterwards doesn't bring it back.
    @Test func aNewerAnswerFromAnotherAppWins() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let me = try #require(model.accounts.first).address.address
        let accepted = Date().addingTimeInterval(-3600)
        model.sentAnswers["meeting-uid"] = SentAnswer(response: .accepted, sequence: 0, at: accepted)
        model.rsvps["meeting-uid"] = .accepted
        model.noteOwnReply(Self.reply("DECLINED", from: me), sentAt: Date())
        #expect(model.rsvps["meeting-uid"] == .declined)
        model.noteOwnReply(Self.reply("ACCEPTED", from: me), sentAt: accepted.addingTimeInterval(-60))
        #expect(model.rsvps["meeting-uid"] == .declined)
        // Someone else's answer isn't yours.
        model.noteOwnReply(Self.reply("ACCEPTED", from: "someone@example.com"), sentAt: Date().addingTimeInterval(60))
        #expect(model.rsvps["meeting-uid"] == .declined)
    }

    /// Someone else's meeting can be deleted (which declines it); a device event you only read can't.
    @Test func othersMeetingsCanBeDeletedByDeclining() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        var invite = CalendarEntry(id: "x-uid", title: "Vendor call", start: Date().addingTimeInterval(86_400), end: nil,
                                   isAllDay: false, organizer: "Sam", threadID: "t1", cancelled: false)
        invite.accountID = account.id
        model.saveCalendar([invite])
        let item = try #require(model.agenda(from: Date(), to: Date().addingTimeInterval(2 * 86_400)).first { $0.title == "Vendor call" })
        #expect(!model.canChange(item) && model.canDelete(item))
    }
}
