import Foundation
import Testing
@testable import MailCore

@Suite struct MailCacheTests {
    let account = UUID()

    func message(_ id: String, _ subject: String, from: String, minutes: Double, body: String? = nil) -> MailMessage {
        MailMessage(id: id, mailboxID: "INBOX", messageID: "\(id)@example.com", from: EmailAddress(name: from, address: "\(from.lowercased())@example.com"),
                    subject: subject, date: Date(timeIntervalSince1970: minutes * 60), snippet: body ?? "",
                    body: body.map { MessageBody(text: $0) })
    }

    @Test func keepsFoldersThreadsAndBodies() async {
        let cache = MailCache(url: nil)
        await cache.saveMailboxes([Mailbox(id: "INBOX", name: "Inbox", role: .inbox)], account: account)
        #expect(await cache.mailboxes(account: account)?.first?.role == .inbox)

        let lisbon = message("1", "Lisbon in May?", from: "Noor", minutes: 10)
        let invoice = message("2", "Invoice question", from: "Sam", minutes: 20)
        await cache.saveThreads([MailThread(id: "1", messages: [lisbon]), MailThread(id: "2", messages: [invoice])], account: account, mailbox: "INBOX")
        #expect(await cache.threads(account: account, mailbox: "INBOX").map(\.subject) == ["Invoice question", "Lisbon in May?"])

        await cache.saveBody(MessageBody(text: "We found a flat by the river."), of: lisbon, account: account)
        #expect(await cache.body(of: "1", account: account)?.text == "We found a flat by the river.")

        // A newer snapshot without the invoice: it leaves the folder but stays searchable.
        await cache.saveThreads([MailThread(id: "1", messages: [lisbon])], account: account, mailbox: "INBOX")
        #expect(await cache.threads(account: account, mailbox: "INBOX").map(\.subject) == ["Lisbon in May?"])
        #expect(await cache.search("invoice").map(\.message.subject) == ["Invoice question"])
    }

    @Test func findsPeopleInEveryFolderForAddressFields() async {
        let cache = MailCache(url: nil)
        // Someone you wrote to (in Sent, as a recipient) and someone in another mailbox.
        var sent = message("s1", "Roadmap", from: "Me", minutes: 5)
        sent.to = [EmailAddress(name: "Gillian Park", address: "gillian@relevate.app")]
        await cache.saveThreads([MailThread(id: "s1", messages: [sent])], account: account, mailbox: "Sent")
        await cache.saveThreads([MailThread(id: "a1", messages: [message("a1", "Hi", from: "Gilbert", minutes: 6)])],
                                account: UUID(), mailbox: "Archive")
        let found = await cache.people(matching: "gil").map(\.address)
        #expect(found.contains("gillian@relevate.app"))
        #expect(found.contains("gilbert@example.com"))
        #expect(await cache.people(matching: "park").map(\.address) == ["gillian@relevate.app"])   // a last name
        #expect(await cache.people(matching: "zz").isEmpty)
    }

    @Test func searchesSubjectsPeopleAndBodies() async {
        let cache = MailCache(url: nil)
        let lisbon = message("1", "Trip plans", from: "Noor", minutes: 10)
        await cache.saveThreads([MailThread(id: "1", messages: [lisbon])], account: account, mailbox: "INBOX")
        await cache.saveBody(MessageBody(text: "The flat is near the river in Lisbon."), of: lisbon, account: account)
        #expect(await cache.search("lisb").count == 1)          // prefix of the last word
        #expect(await cache.search("noor river").count == 1)    // person and body together
        #expect(await cache.search("noor paris").isEmpty)       // every word must match
        #expect(await cache.search("Trip").first?.account == account)
        #expect(await cache.search("\"").isEmpty)
        await cache.removeAccount(account)
        #expect(await cache.search("lisbon").isEmpty)
    }

    @Test func survivesReopening() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "margin-cache-\(UUID()).sqlite")
        do {
            let cache = MailCache(url: url)
            await cache.saveThreads([MailThread(id: "1", messages: [message("1", "Kept", from: "Sam", minutes: 1)])], account: account, mailbox: "INBOX")
        }
        let reopened = MailCache(url: url)
        #expect(await reopened.threads(account: account, mailbox: "INBOX").first?.subject == "Kept")
    }
}
