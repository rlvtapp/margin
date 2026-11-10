import Foundation
import Testing
@testable import MailCore

@Suite struct MailHelperTests {
    @Test func findsUnsubscribeMethods() {
        let oneClick = Unsubscribe.method(from: [
            "list-unsubscribe": "<mailto:leave@list.example?subject=bye>, <https://list.example/u/123>",
            "list-unsubscribe-post": "List-Unsubscribe=One-Click",
        ])
        #expect(oneClick == .oneClick(URL(string: "https://list.example/u/123")!))
        #expect(Unsubscribe.method(from: ["list-unsubscribe": "<mailto:leave@list.example?subject=bye>, <https://list.example/u>"])
            == .mail(EmailAddress(address: "leave@list.example"), subject: "bye"))
        #expect(Unsubscribe.method(from: ["list-unsubscribe": "<https://list.example/u>"]) == .web(URL(string: "https://list.example/u")!))
        #expect(Unsubscribe.method(from: ["list-id": "<x>"]) == nil)

        let request = Unsubscribe.oneClickRequest(URL(string: "https://list.example/u/123")!)
        #expect(request.httpMethod == "POST")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "List-Unsubscribe=One-Click")
        #expect(!request.httpShouldHandleCookies)
    }

    @Test func spotsSignInCodes() {
        #expect(SignInCode.detect(subject: "Your sign-in code", text: "Use 482 913 to sign in. It expires in 10 minutes.") == "482913")
        #expect(SignInCode.detect(subject: "Verify your email", text: "Your verification code is: 735102") == "735102")
        #expect(SignInCode.detect(subject: "Security alert", text: "Code 4410-2201 was requested") == "44102201")
        #expect(SignInCode.detect(subject: "Card payment of €42.10", text: "Card ending 4410 on 8 Nov 2026") == nil)
        #expect(SignInCode.detect(subject: "Lunch on Tuesday?", text: "Table for 4 at 1230") == nil)
        #expect(SignInCode.detect(subject: "Your code", text: "Valid since 2026.") == nil)
    }

    @Test func snoozeTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        // Sunday 8 November 2026, 14:20.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 14, minute: 20)))
        func parts(_ date: Date) -> [Int] {
            let c = calendar.dateComponents([.month, .day, .hour], from: date)
            return [c.month!, c.day!, c.hour!]
        }
        #expect(parts(SnoozePreset.laterToday.date(from: now, calendar: calendar)) == [11, 8, 17])
        #expect(parts(SnoozePreset.tomorrow.date(from: now, calendar: calendar)) == [11, 9, 8])
        #expect(parts(SnoozePreset.weekend.date(from: now, calendar: calendar)) == [11, 14, 9])
        #expect(parts(SnoozePreset.nextWeek.date(from: now, calendar: calendar)) == [11, 9, 8])
    }

    @Test func findsConversationsWaitingForReply() {
        let me = EmailAddress(address: "me@example.com")
        let sam = EmailAddress(address: "sam@kettle.example")
        let lena = EmailAddress(address: "lena@harbor.example")
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 100 * day)
        func message(_ id: String, from: EmailAddress, to: EmailAddress, subject: String, daysAgo: Double, inReplyTo: String? = nil) -> MailMessage {
            MailMessage(id: id, mailboxID: "x", messageID: id, inReplyTo: inReplyTo, from: from, to: [to], subject: subject,
                        date: now.addingTimeInterval(-daysAgo * day))
        }
        let unanswered = MailThread(id: "a", messages: [message("a", from: me, to: sam, subject: "Contract", daysAgo: 5)])
        let answered = MailThread(id: "b", messages: [message("b", from: me, to: lena, subject: "Offsite", daysAgo: 6)])
        let recent = MailThread(id: "c", messages: [message("c", from: me, to: sam, subject: "Lunch", daysAgo: 1)])
        let reply = MailThread(id: "r", messages: [message("r", from: lena, to: me, subject: "Re: Offsite", daysAgo: 4, inReplyTo: "b")])
        let waiting = FollowUp.waiting(sent: [unanswered, answered, recent], inbox: [reply], me: [me.address], olderThan: 3 * day, now: now)
        #expect(waiting.map(\.id) == ["a"])
    }

    @Test func buildsAndReadsAttachments() {
        let pdf = Data((0..<3000).map { UInt8($0 % 251) })
        let draft = Draft(from: EmailAddress(address: "me@example.com"), to: [EmailAddress(address: "sam@kettle.example")],
                          subject: "Plan", text: "Attached.", attachments: [OutgoingAttachment(filename: "plän v3.pdf", mimeType: "application/pdf", data: pdf)])
        let raw = MessageBuilder.build(draft, messageID: "x@example.com", boundary: "b1")
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.contains("Content-Type: multipart/mixed; boundary=\"b1\""))
        #expect(text.contains("filename*=utf-8''pl%C3%A4n%20v3.pdf"))
        #expect(text.split(separator: "\r\n").allSatisfy { $0.count <= 998 })

        let parsed = MIMEMessage.parse(raw)
        #expect(parsed.body.text == "Attached.")
        #expect(parsed.attachments.first?.filename == "plän v3.pdf")
        #expect(parsed.attachments.first?.data == pdf)
        #expect(parsed.attachments.first?.size == 3000)
    }

    @Test func storesRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "margin-test-\(UUID()).json")
        let file = JSONFile<[ScheduledMessage]>(url: url)
        let message = ScheduledMessage(accountID: UUID(), draft: Draft(from: EmailAddress(address: "me@example.com"), text: "Hi"),
                                       sendAt: Date(timeIntervalSince1970: 1_800_000_000))
        file.save([message])
        #expect(file.load() == [message])
    }
}
