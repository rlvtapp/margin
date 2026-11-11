import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct PersonCardTests {
    /// The card counts mail with the person from this device and lists their newest messages.
    @Test func summarizesMailWithAPerson() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let sender = try #require(model.inboxThreads(nil).first?.latest.from)
        let summary = await model.personSummary(sender)
        #expect(summary.messageCount > 0)
        #expect(summary.fromThem > 0)
        #expect(summary.recent.count <= 5)
        #expect(summary.latest != nil)
    }

    /// Show Source returns the message as headers and MIME.
    @Test func showsAMessagesSource() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = try #require(model.inboxThreads(nil).first)
        let source = try await model.rawSource(of: thread.latest, in: thread)
        #expect(source.contains("Subject:"))
        #expect(source.contains("From:"))
    }
}

@Suite struct MailHistoryTests {
    /// Every saved message with an address on it, from any folder and account, once each.
    @Test func findsAllMailWithAnAddress() async {
        let cache = MailCache(url: nil)
        let gillian = EmailAddress(name: "Gillian", address: "gillian@relevate.app")
        let me = EmailAddress(name: "Me", address: "me@example.com")
        let received = MailMessage(id: "1", mailboxID: "INBOX", messageID: "a@x", from: gillian, to: [me], subject: "Hi", date: Date(timeIntervalSince1970: 100))
        let sent = MailMessage(id: "2", mailboxID: "Sent", messageID: "b@x", from: me, to: [gillian], subject: "Re: Hi", date: Date(timeIntervalSince1970: 200))
        let other = MailMessage(id: "3", mailboxID: "INBOX", messageID: "c@x", from: EmailAddress(address: "gill@else.example"), to: [me], subject: "No", date: Date(timeIntervalSince1970: 300))
        await cache.saveThreads([MailThread(id: "1", messages: [received]), MailThread(id: "3", messages: [other])], account: UUID(), mailbox: "INBOX")
        await cache.saveThreads([MailThread(id: "2", messages: [sent])], account: UUID(), mailbox: "Sent")
        let history = await cache.history(with: "Gillian@relevate.app")
        #expect(history.map(\.subject) == ["Re: Hi", "Hi"])
    }
}
