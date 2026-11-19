import Foundation
import MailCore
import Testing
@testable import MailUI

/// Counts the replies sent; each send waits until the test lets it through, like a slow server.
private actor SlowSendProvider: MailProvider {
    var sent: [Draft] = []
    var failNext = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func failOnce() { failNext = true }

    func send(_ draft: Draft) async throws {
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        if failNext {
            failNext = false
            throw MailError.serverRejected("Try again")
        }
        sent.append(draft)
    }

    func mailboxes() async throws -> [Mailbox] { [] }
    func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] { [] }
    func body(of message: MailMessage) async throws -> MessageBody { MessageBody(text: "") }
    func perform(_ action: MailAction, on threads: [MailThread]) async throws {}
    func saveDraft(_ draft: Draft) async throws {}
    func attachmentData(_ attachment: AttachmentInfo, of message: MailMessage) async throws -> Data { Data() }
    func disconnect() async {}
}

@MainActor @Suite struct InviteAnswerTests {
    private struct Setup {
        let model: MailModel
        let provider: SlowSendProvider
        let invite: CalendarInvite
        let thread: MailThread
    }

    private func setup(sequence: Int = 0, aliases: [EmailAddress]? = nil) async throws -> Setup {
        let environment = MailEnvironment.preview()
        let me = EmailAddress(name: "Kaan", address: "me@example.com")
        var account = MailAccount(label: "Work", address: me, connection: .sample, auth: .password(username: "me"))
        account.aliases = aliases
        try environment.accounts.save([account])
        let model = MailModel(environment: environment)
        let provider = SlowSendProvider()
        model.providers[account.id] = provider
        let start = Date().addingTimeInterval(86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let ics = """
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r
        BEGIN:VEVENT\r
        UID:weekly-sync@example.com\r
        SEQUENCE:\(sequence)\r
        SUMMARY:Weekly sync\r
        DTSTART:\(formatter.string(from: start))\r
        DTEND:\(formatter.string(from: start.addingTimeInterval(1800)))\r
        ORGANIZER;CN=Sam:mailto:sam@example.com\r
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:\(me.address)\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let invite = try #require(CalendarInvite.parse(ics))
        var message = MailMessage(id: "INBOX/1", mailboxID: "INBOX", messageID: "invite@example.com",
                                  from: EmailAddress(name: "Sam", address: "sam@example.com"), to: [me],
                                  subject: "Weekly sync", date: Date())
        message.body = MessageBody(text: "", invite: invite)
        let thread = MailModel.tag(MailThread(id: "invite-thread", messages: [message]), account: account.id)
        model.shelves[account.id] = InboxShelf([thread])
        var entry = CalendarEntry(id: invite.uid, title: invite.summary, start: start, end: start.addingTimeInterval(1800),
                                  isAllDay: false, threadID: thread.id, cancelled: false)
        entry.accountID = account.id
        model.saveCalendar([entry])
        return Setup(model: model, provider: provider, invite: invite, thread: thread)
    }

    /// Tapping Accept twice while the first reply is still sending sends one reply.
    @Test func fastDoubleTapSendsOnce() async throws {
        let s = try await setup()
        let first = s.model.respond(to: s.invite, in: s.thread, with: .accepted)
        let second = s.model.respond(to: s.invite, in: s.thread, with: .accepted)
        // A different answer while the first is on its way waits its turn too.
        let third = s.model.respond(to: s.invite, in: s.thread, with: .declined)
        #expect(first != nil)
        #expect(second == nil)
        #expect(third == nil)
        // The buttons show the answer straight away, before the server has it.
        #expect(s.model.answer(to: s.invite) == .accepted)
        #expect(s.model.answering[s.invite.uid] == .accepted)
        await s.provider.open()
        await first?.value
        #expect(await s.provider.sent.count == 1)
        #expect(await s.provider.sent.first?.calendar?.contains("PARTSTAT=ACCEPTED") == true)
    }

    /// After the reply has gone: the answer is kept, nothing is in flight, the notice says so,
    /// and the same answer again isn't sent a second time, even after a restart.
    @Test func stateAfterAnswering() async throws {
        let s = try await setup()
        await s.provider.open()
        await s.model.respond(to: s.invite, in: s.thread, with: .accepted)?.value
        #expect(s.model.rsvps[s.invite.uid] == .accepted)
        #expect(s.model.answer(to: s.invite) == .accepted)
        #expect(s.model.answering.isEmpty)
        #expect(s.model.answerState(of: s.invite) == .sent(.accepted))
        let notice = try #require(s.model.notice)
        #expect(notice.isSent)
        #expect(!notice.isError)
        // The meeting's guest list has you as going, once.
        let me = try #require(s.model.calendarEntries.first { $0.id == s.invite.uid }?.attendees.filter { $0.id == "me@example.com" })
        #expect(me.map(\.response) == [.accepted])
        // The reply is a proper iTIP REPLY to the organizer.
        let draft = try #require(await s.provider.sent.first)
        #expect(draft.to.map(\.address) == ["sam@example.com"])
        let reply = try #require(draft.calendar.flatMap(CalendarInvite.parse))
        #expect(reply.method == "REPLY")
        #expect(reply.uid == s.invite.uid)
        #expect(reply.sequence == s.invite.sequence)
        #expect(reply.attendees.map(\.id) == ["me@example.com"])
        #expect(reply.attendees.first?.response == .accepted)

        #expect(s.model.respond(to: s.invite, in: s.thread, with: .accepted) == nil)
        #expect(await s.provider.sent.count == 1)

        // A fresh launch remembers the answer, so it shows and isn't sent again.
        let relaunched = MailModel(environment: s.model.environment)
        #expect(relaunched.rsvps[s.invite.uid] == .accepted)
        relaunched.providers = s.model.providers
        #expect(relaunched.respond(to: s.invite, in: s.thread, with: .accepted) == nil)
        #expect(await s.provider.sent.count == 1)
    }

    /// Changing your mind sends the new answer; an updated invitation can be answered again.
    @Test func changedAnswerAndNewVersionSend() async throws {
        let s = try await setup()
        await s.provider.open()
        await s.model.respond(to: s.invite, in: s.thread, with: .accepted)?.value
        await s.model.respond(to: s.invite, in: s.thread, with: .declined)?.value
        #expect(await s.provider.sent.count == 2)
        #expect(s.model.rsvps[s.invite.uid] == .declined)

        // The organizer moves the meeting: the old answer no longer counts and the card says so.
        var moved = s.invite
        moved.sequence += 1
        #expect(s.model.answerState(of: moved) == .changed(.declined))
        #expect(s.model.answer(to: moved) == nil)
        await s.model.respond(to: moved, in: s.thread, with: .declined)?.value
        #expect(await s.provider.sent.count == 3)
        #expect(s.model.answerState(of: moved) == .sent(.declined))
        #expect(await s.provider.sent.last?.calendar?.contains("SEQUENCE:1") == true)
    }

    /// A failed send shows the error, leaves no answer behind, and can be tried again.
    @Test func failureRollsBackAndRetrySends() async throws {
        let s = try await setup()
        await s.provider.failOnce()
        await s.provider.open()
        await s.model.respond(to: s.invite, in: s.thread, with: .accepted)?.value
        #expect(s.model.answer(to: s.invite) == nil)
        #expect(s.model.answering.isEmpty)
        #expect(s.model.notice?.isError == true)
        #expect(await s.provider.sent.isEmpty)

        await s.model.respond(to: s.invite, in: s.thread, with: .accepted)?.value
        #expect(await s.provider.sent.count == 1)
        #expect(s.model.rsvps[s.invite.uid] == .accepted)
    }

    /// The calendar page and the reader card answering the same invitation send one reply,
    /// and so does a double tap on the calendar page while the invitation is looked up.
    @Test func calendarPageAndReaderCardSendOnce() async throws {
        let s = try await setup()
        let item = try #require(s.model.agenda(from: Date(), to: Date().addingTimeInterval(2 * 86_400))
            .first { $0.id == s.invite.uid })
        let fromPage = s.model.respond(to: item, with: .accepted)
        #expect(s.model.respond(to: item, with: .accepted) == nil)
        #expect(s.model.isAnswering(item))
        #expect(s.model.respond(to: s.invite, in: s.thread, with: .accepted) == nil)
        #expect(s.model.agenda(from: Date(), to: Date().addingTimeInterval(2 * 86_400))
            .first { $0.id == s.invite.uid }?.response == .accepted)
        await s.provider.open()
        await fromPage?.value
        #expect(await s.provider.sent.count == 1)
        #expect(!s.model.isAnswering(item))
        #expect(s.model.rsvps[s.invite.uid] == .accepted)
    }

    /// Invited at an alias: the reply comes from, and names, that address.
    @Test func answersAsTheInvitedAlias() async throws {
        let s = try await setup(aliases: [EmailAddress(address: "kaan@alias.example")])
        var invite = s.invite
        invite.attendees = [MeetingAttendee(address: EmailAddress(address: "Kaan@Alias.example"))]
        await s.provider.open()
        await s.model.respond(to: invite, in: s.thread, with: .accepted)?.value
        let draft = try #require(await s.provider.sent.first)
        #expect(draft.from.address == "kaan@alias.example")
        #expect(draft.calendar?.contains("mailto:kaan@alias.example") == true)
    }

    /// On the Calendar page, tapping your answer again after the organizer updated the
    /// invitation sends it for the new version; for the same version it sends nothing.
    @Test func calendarPageAnswersAnUpdatedInvitationAgain() async throws {
        let s = try await setup()
        await s.provider.open()
        let item = try #require(s.model.agenda(from: Date(), to: Date().addingTimeInterval(2 * 86_400))
            .first { $0.id == s.invite.uid })
        await s.model.respond(to: item, with: .accepted)?.value
        await s.model.respond(to: item, with: .accepted)?.value
        #expect(await s.provider.sent.count == 1)

        var updated = s.invite
        updated.sequence = 1
        var message = s.thread.messages[0]
        message.body = MessageBody(text: "", invite: updated)
        let thread = MailThread(id: s.thread.id, messages: [message])
        let accountID = try #require(s.thread.accountID)
        s.model.shelves[accountID] = InboxShelf([thread])
        s.model.bodies[MailModel.bodyKey(accountID, message.id)] = message.body
        await s.model.respond(to: item, with: .accepted)?.value
        #expect(await s.provider.sent.count == 2)
        #expect(await s.provider.sent.last?.calendar?.contains("SEQUENCE:1") == true)
    }
}
