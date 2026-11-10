import Foundation
import Testing
@testable import MailCore

@Suite struct Batch2EngineTests {
    let ics = """
    BEGIN:VCALENDAR\r
    METHOD:REQUEST\r
    BEGIN:VEVENT\r
    UID:abc-123@harbor.example\r
    SEQUENCE:2\r
    SUMMARY:Quarterly planning\\, Q1\r
    DTSTART:20261112T090000Z\r
    DTEND:20261112T100000Z\r
    LOCATION:Room 3\r
    ORGANIZER;CN="Fischer, Lena":mailto:lena@harbor.example\r
    DESCRIPTION:Agenda attached.\\nJoin: https://meet.google.com/abc-defg\r
     -hij\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    @Test func parsesInvitations() throws {
        let invite = try #require(CalendarInvite.parse(ics))
        #expect(invite.summary == "Quarterly planning, Q1")
        #expect(invite.method == "REQUEST")
        #expect(invite.sequence == 2)
        #expect(invite.organizer == EmailAddress(name: "Fischer, Lena", address: "lena@harbor.example"))
        #expect(invite.joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(invite.start == Date(timeIntervalSince1970: 1_794_474_000))
        #expect(!invite.isAllDay)
        let allDay = try #require(CalendarInvite.parse("BEGIN:VEVENT\nUID:x\nDTSTART;VALUE=DATE:20261224\nEND:VEVENT"))
        #expect(allDay.isAllDay)
    }

    @Test func repliesToInvitations() throws {
        let invite = try #require(CalendarInvite.parse(ics))
        let reply = invite.reply(from: EmailAddress(name: "Alex Rivera", address: "alex@example.com"), status: .accepted, now: Date(timeIntervalSince1970: 0))
        #expect(reply.contains("METHOD:REPLY"))
        #expect(reply.contains("UID:abc-123@harbor.example"))
        #expect(reply.contains("SEQUENCE:2"))
        #expect(reply.contains("ATTENDEE;PARTSTAT=ACCEPTED;CN=\"Alex Rivera\":mailto:alex@example.com"))
        #expect(reply.contains("DTSTART:20261112T090000Z"))

        var draft = Draft(from: EmailAddress(address: "alex@example.com"), to: [EmailAddress(address: "lena@harbor.example")],
                          subject: "Accepted: Quarterly planning", text: "Alex accepted.")
        draft.calendar = reply
        let parsed = MIMEMessage.parse(MessageBuilder.build(draft, boundary: "b2"))
        #expect(parsed.body.text == "Alex accepted.")
        #expect(parsed.invite?.method == "REPLY")
    }

    @Test func sendsFormattedMailWithAPlainPart() {
        var draft = Draft(from: EmailAddress(address: "me@example.com"), to: [EmailAddress(address: "sam@kettle.example")],
                          subject: "Plan", text: "The plan is bold.")
        draft.html = "<p>The plan is <b>bold</b>.</p>"
        draft.attachments = [OutgoingAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("hi".utf8))]
        let raw = MessageBuilder.build(draft, boundary: "outer1")
        let parsed = MIMEMessage.parse(raw)
        #expect(parsed.body.text == "The plan is bold.")
        #expect(parsed.html == "<p>The plan is <b>bold</b>.</p>")
        #expect(parsed.attachments.map(\.filename) == ["a.txt"])
        // Inner boundaries never start with the outer one.
        let text = String(decoding: raw, as: UTF8.self)
        let outerLines = text.components(separatedBy: "\r\n").filter { $0.hasPrefix("--outer1") }
        #expect(Set(outerLines) == ["--outer1", "--outer1--"])
    }

    @Test func backupsOpenOnlyWithTheirPassword() throws {
        let contents = Data("{\"hello\":\"world\"}".utf8)
        let sealed = try BackupBox.seal(contents, password: "correct horse")
        #expect(BackupBox.isEncrypted(sealed))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("world"))
        #expect(try BackupBox.open(sealed, password: "correct horse") == contents)
        #expect(throws: BackupBox.Failure.wrongPassword) { try BackupBox.open(sealed, password: "wrong") }
        #expect(throws: BackupBox.Failure.needsPassword) { try BackupBox.open(sealed, password: nil) }

        let plain = try BackupBox.seal(contents, password: nil)
        #expect(!BackupBox.isEncrypted(plain))
        #expect(try BackupBox.open(plain, password: nil) == contents)
        #expect(throws: BackupBox.Failure.notABackup) { try BackupBox.open(Data("nope".utf8), password: nil) }
    }

    @Test func questionsMatchAnyWord() async {
        let cache = MailCache(url: nil)
        let account = UUID()
        let message = MailMessage(id: "1", mailboxID: "INBOX", from: EmailAddress(name: "Noor", address: "noor@post.example"),
                                  subject: "Flat in Lisbon", date: Date())
        await cache.saveThreads([MailThread(id: "1", messages: [message])], account: account, mailbox: "INBOX")
        #expect(await cache.search("When does the Lisbon deposit need paying?", anyWord: true).count == 1)
        #expect(await cache.search("When does the Lisbon deposit need paying?").isEmpty)
        #expect(MailCache.ftsAnyQuery("what is the") == nil)
    }

    @Test func templatesFillIn() {
        let template = MailTemplate(name: "Thanks", subject: "Thanks, {first_name}", body: "Hi {first_name},\n\n— {my_first_name}, {date}")
        let filled = template.filled(to: EmailAddress(name: "Lena Fischer", address: "lena@harbor.example"),
                                     from: EmailAddress(name: "Alex Rivera", address: "alex@example.com"),
                                     date: Date(timeIntervalSince1970: 0))
        #expect(filled.subject == "Thanks, Lena")
        #expect(filled.body.hasPrefix("Hi Lena,\n\n— Alex, "))
    }
}
