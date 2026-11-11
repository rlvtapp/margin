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
                                     subject: "Invitation: Second round", date: Date().addingTimeInterval(-2 * 86_400))
        let answer = try #require(CalendarInvite.parse(invite.reply(from: me, status: .accepted)))
        let reply = MailMessage(id: "ans", mailboxID: "Sent", messageID: "ans@example.com", from: me, to: [sam],
                                subject: "Accepted: Second round", date: Date().addingTimeInterval(-86_400))
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

@MainActor @Suite struct AnswerSubjectTests {
    /// Calendars name your answer at the front of the reply's subject, in your language.
    @Test func readsAnswersFromSubjects() {
        #expect(MailModel.answer(inSubject: "Accepted: Kaan x Engaige (second round)")! == (.accepted, "Kaan x Engaige (second round)"))
        #expect(MailModel.answer(inSubject: "Geaccepteerd: Team meeting")! == (.accepted, "Team meeting"))
        #expect(MailModel.answer(inSubject: "Tentatively accepted: Standup")! == (.tentative, "Standup"))
        #expect(MailModel.answer(inSubject: "Refusé : Revue")! == (.declined, "Revue"))
        #expect(MailModel.answer(inSubject: "Re: Accepted: no") == nil)
        #expect(MailModel.answer(inSubject: "Accepted:") == nil)
    }

    /// Your "Accepted:" reply in Sent marks the meeting as Going, even without its calendar part.
    @Test func answerFromYourReplyCounts() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let start = Date().addingTimeInterval(86_400)
        var entry = CalendarEntry(id: "uid-1", title: "Uitnodiging eerste gesprek", start: start, end: nil, isAllDay: false,
                                  threadID: "t", cancelled: false)
        entry.accountID = account.id
        model.saveCalendar([entry])
        let reply = MailMessage(id: "r", mailboxID: "Sent", messageID: "r@x", from: account.address, to: [],
                                subject: "Accepted: Uitnodiging eerste gesprek", date: Date())
        model.noteAnswers(in: [reply])
        #expect(model.agenda(from: Date(), to: Date().addingTimeInterval(2 * 86_400)).first?.response == .accepted)
    }
}
