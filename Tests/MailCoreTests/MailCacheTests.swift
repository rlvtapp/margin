import Foundation
import SQLite3
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

    @Test func peopleCanBeLimitedToSomeAccounts() async {
        let cache = MailCache(url: nil)
        let other = UUID()
        await cache.saveThreads([MailThread(id: "a1", messages: [message("a1", "Hi", from: "Gilbert", minutes: 6)])], account: account, mailbox: "INBOX")
        await cache.saveThreads([MailThread(id: "b1", messages: [message("b1", "Hey", from: "Gilda", minutes: 7)])], account: other, mailbox: "INBOX")
        #expect(Set(await cache.people(matching: "gil").map(\.address)) == ["gilbert@example.com", "gilda@example.com"])
        #expect(await cache.people(matching: "gil", accounts: [account]).map(\.address) == ["gilbert@example.com"])
        #expect(await cache.people(matching: "gil", accounts: [other, account]).count == 2)
        #expect(await cache.people(matching: "gil", accounts: []).isEmpty)
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

/// Saved mail at size: a refresh writes only what changed, older pages stay, and a file from
/// before row numbers is brought up to date with nothing lost.
@Suite struct MailCacheScaleTests {
    let account = UUID()

    func thread(_ index: Int, flags: MessageFlags = []) -> MailThread {
        let message = MailMessage(id: "INBOX/\(index)", mailboxID: "INBOX", messageID: "<\(index)@example.com>",
                                  from: EmailAddress(name: "Sender \(index % 7)", address: "sender\(index % 7)@example.com"),
                                  to: [EmailAddress(address: "me@example.com")], subject: "Subject \(index)",
                                  date: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 60), snippet: "Preview \(index)", flags: flags)
        return MailThread(id: "t\(index)", messages: [message])
    }

    @Test func aRefreshWithNothingNewWritesNothing() async {
        let cache = MailCache(url: nil)
        let page = (0..<200).map { thread($0) }
        await cache.saveThreads(page, account: account, mailbox: "INBOX", limit: 200)
        #expect(await cache.rowsWritten == 200)
        await cache.saveThreads(page, account: account, mailbox: "INBOX", limit: 200)
        #expect(await cache.rowsWritten == 200)
        // One read mark: one row.
        var changed = page
        changed[3] = thread(3, flags: [.seen])
        await cache.saveThreads(changed, account: account, mailbox: "INBOX", limit: 200)
        #expect(await cache.rowsWritten == 201)
        #expect(await cache.threads(account: account, mailbox: "INBOX").first { $0.id.hasSuffix("/3") || $0.messages[0].id == "INBOX/3" }?.isUnread == false)
        // Still found by its words after the flag changed.
        #expect(await cache.search("Subject 3").contains { $0.message.id == "INBOX/3" })
    }

    @Test func olderPagesStayWhenTheNewestPageIsSavedAgain() async {
        let cache = MailCache(url: nil)
        // The list was scrolled: 600 conversations were saved, in three pages.
        await cache.saveThreads((0..<600).map { thread($0) }, account: account, mailbox: "INBOX", limit: 600)
        #expect(await cache.messageCount(account: account, mailbox: "INBOX") == 600)
        // Next launch the newest 200 come back, one of them gone and one new.
        let newest = [thread(-1)] + (0..<200).filter { $0 != 5 }.map { thread($0) }
        await cache.saveThreads(Array(newest.prefix(200)), account: account, mailbox: "INBOX", limit: 200)
        // The one that left is out of the folder; the pages below the snapshot are untouched.
        #expect(await cache.messageCount(account: account, mailbox: "INBOX") == 600)
        let ids = Set(await cache.threads(account: account, mailbox: "INBOX", limit: 700).flatMap { $0.messages.map(\.id) })
        #expect(!ids.contains("INBOX/5"))
        #expect(ids.contains("INBOX/-1"))
        #expect(ids.contains("INBOX/599"))
        // The next page down, as the list asks for it.
        let oldestShown = thread(198).date
        let older = await cache.threads(account: account, mailbox: "INBOX", limit: 200, before: oldestShown)
        #expect(older.count == 200)
        #expect(older.first?.messages[0].id == "INBOX/199")
        #expect(older.last?.messages[0].id == "INBOX/398")
    }

    @Test func aWholeSnapshotStillEmptiesWhatLeft() async {
        let cache = MailCache(url: nil)
        await cache.saveThreads((0..<50).map { thread($0) }, account: account, mailbox: "INBOX", limit: 200)
        // Fewer than asked for: this is the whole folder, so anything else has left it.
        await cache.saveThreads((0..<10).map { thread($0) }, account: account, mailbox: "INBOX", limit: 200)
        #expect(await cache.messageCount(account: account, mailbox: "INBOX") == 10)
        #expect(await cache.search("Subject 40").count == 1)   // still searchable
    }

    @Test func removingAnAccountTakesItsSearchRowsToo() async {
        let cache = MailCache(url: nil)
        let other = UUID()
        await cache.saveThreads((0..<20).map { thread($0) }, account: account, mailbox: "INBOX")
        await cache.saveThreads((100..<110).map { thread($0) }, account: other, mailbox: "INBOX")
        #expect(await cache.savedAccounts() == [account, other])
        await cache.removeAccount(account)
        #expect(await cache.savedAccounts() == [other])
        #expect(await cache.search("Subject 13").isEmpty)
        #expect(await cache.search("Subject 103").count == 1)
        #expect(await cache.messageCount() == 10)
    }

    @Test func correspondentsComeFromWhatYouSent() async {
        let cache = MailCache(url: nil)
        var sent = MailMessage(id: "Sent/1", mailboxID: "Sent", from: EmailAddress(address: "Me@Example.com"), to: [EmailAddress(address: "Noor@Example.com")],
                               cc: [EmailAddress(address: "sam@example.com")], subject: "Hi", date: Date())
        sent.messageID = "<s1@example.com>"
        await cache.saveThreads([MailThread(id: "s", messages: [sent]), thread(1)], account: account, mailbox: "Sent")
        #expect(await cache.correspondents(of: ["me@example.com"]) == ["noor@example.com", "sam@example.com"])
    }

    /// A database written by a build from before row numbers opens with everything in place:
    /// folders, messages, opened text, and search.
    @Test func aFileFromBeforeIsBroughtUpToDate() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "margin-cache-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let message = thread(7).messages[0]
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        let body = String(decoding: try JSONEncoder().encode(MessageBody(text: "The quarterly figures are attached.")), as: UTF8.self)
        let setUp = """
        CREATE TABLE messages (account TEXT NOT NULL, id TEXT NOT NULL, mailbox TEXT, date REAL, json BLOB NOT NULL, body BLOB, PRIMARY KEY (account, id));
        CREATE INDEX messages_by_mailbox ON messages (account, mailbox, date DESC);
        CREATE TABLE mailboxes (account TEXT PRIMARY KEY, json BLOB NOT NULL);
        CREATE VIRTUAL TABLE search USING fts5(account UNINDEXED, id UNINDEXED, subject, people, body, tokenize = 'unicode61 remove_diacritics 2');
        INSERT INTO messages VALUES ('\(account.uuidString)', 'INBOX/7', 'INBOX', \(message.date.timeIntervalSince1970), CAST('\(json)' AS BLOB), CAST('\(body)' AS BLOB));
        INSERT INTO search (account, id, subject, people, body) VALUES ('\(account.uuidString)', 'INBOX/7', 'Subject 7', 'Sender 0 sender0@example.com', 'The quarterly figures are attached.');
        INSERT INTO search (account, id, subject, people, body) VALUES ('\(account.uuidString)', 'gone', 'Left behind', '', 'no message for this row');
        """
        #expect(sqlite3_exec(db, setUp, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let cache = MailCache(url: url)
        #expect(await cache.messageCount() == 1)
        #expect(await cache.threads(account: account, mailbox: "INBOX").first?.subject == "Subject 7")
        #expect(await cache.body(of: "INBOX/7", account: account)?.text == "The quarterly figures are attached.")
        #expect(await cache.search("quarterly").map(\.message.id) == ["INBOX/7"])
        #expect(await cache.search("behind").isEmpty)
        #expect(await cache.people(matching: "sender").map(\.address) == ["sender0@example.com"])
        // Saving the same message again finds its row instead of adding another.
        await cache.saveThreads([thread(7)], account: account, mailbox: "INBOX")
        #expect(await cache.messageCount() == 1)
        #expect(await cache.search("quarterly").count == 1)
    }
}
