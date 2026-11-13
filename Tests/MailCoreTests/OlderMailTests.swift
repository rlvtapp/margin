import Foundation
import Testing
@testable import MailCore

/// Paging through a folder's older mail without growing what a refresh keeps, and comparing
/// saved mail with the server: IMAP (with and without CONDSTORE) and JMAP.
@Suite(.serialized) struct OlderMailTests {
    let inbox = Mailbox(id: "INBOX", name: "Inbox", role: .inbox)

    func provider(_ server: FakeServer) throws -> IMAPProvider {
        try IMAPSyncTests().provider(server)
    }

    @Test func imapPagesGoDownBySequenceAndSurviveDeletedPositions() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1", subjects: (1...7).map { "S\($0)" })
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)

        let first = try await provider.olderMessages(in: inbox, after: nil, limit: 3)
        #expect(first.messages.map(\.subject) == ["S7", "S6", "S5"])
        #expect(first.next == "5")
        #expect(first.validity == "7")

        // The message the next page starts below was deleted meanwhile.
        mailbox.expunge(5)
        let second = try await provider.olderMessages(in: inbox, after: first.next, limit: 3)
        #expect(second.messages.map(\.subject) == ["S4", "S3", "S2"])
        let third = try await provider.olderMessages(in: inbox, after: second.next, limit: 3)
        #expect(third.messages.map(\.subject) == ["S1"])
        #expect(third.next == nil)

        // Paging kept nothing: a refresh still fetches only its own window.
        let threads = try await provider.threads(in: inbox, limit: 2)
        #expect(threads.map(\.subject) == ["S7", "S6"])
        await provider.disconnect()
    }

    @Test func imapCheckWithoutCondstoreLooksAtEveryFlag() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1", subjects: (1...5).map { "S\($0)" })
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)
        mailbox.expunge(3)
        mailbox.markSeen(2)
        let check = try await provider.checkSaved((1...5).map { "INBOX/\($0)" }, in: inbox, since: nil)
        #expect(check.gone == ["INBOX/3"])
        #expect(check.flags["INBOX/2"] == [.seen])
        #expect(check.flags["INBOX/1"] == [])
        #expect(check.token == nil)
        await provider.disconnect()
    }

    @Test func imapCheckWithCondstoreAsksOnlyForChanges() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 CONDSTORE", subjects: (1...5).map { "S\($0)" })
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)
        let ids = (1...5).map { "INBOX/\($0)" }
        let first = try await provider.checkSaved(ids, in: inbox, since: nil)
        #expect(first.token == "7:\(mailbox.modSeq)")
        let modSeq = mailbox.modSeq

        // Nothing changed: the SELECT answers it.
        var mark = mailbox.commands.count
        let same = try await provider.checkSaved(ids, in: inbox, since: first.token)
        #expect(same.flags.isEmpty && same.gone.isEmpty)
        #expect(!mailbox.commands.dropFirst(mark).contains { $0.contains("FLAGS") })

        mailbox.markSeen(4)
        mark = mailbox.commands.count
        let second = try await provider.checkSaved(ids, in: inbox, since: first.token)
        #expect(second.flags == ["INBOX/4": [.seen]])
        #expect(mailbox.commands.dropFirst(mark).contains { $0.hasSuffix("(UID FLAGS) (CHANGEDSINCE \(modSeq))") })

        // Renumbered: every saved id names another message now.
        mailbox.renumber()
        let renumbered = try await provider.checkSaved(ids, in: inbox, since: second.token)
        #expect(Set(renumbered.gone) == Set(ids))
        await provider.disconnect()
    }

    @Test func jmapPagesByPositionAndChecksWithChanges() async throws {
        let server = FakeJMAPServer(host: "older.jmap.test")
        defer { server.stop() }
        for index in 1...5 { server.addEmail("e\(index)", subject: "S\(index)") }
        let provider = try JMAPSyncTests().provider(server)
        let inbox = try await provider.mailboxes().first { $0.role == .inbox }!

        let first = try await provider.olderMessages(in: inbox, after: nil, limit: 2)
        #expect(first.messages.map(\.subject) == ["S5", "S4"])
        let second = try await provider.olderMessages(in: inbox, after: first.next, limit: 2)
        #expect(second.messages.map(\.subject) == ["S3", "S2"])
        let third = try await provider.olderMessages(in: inbox, after: second.next, limit: 2)
        #expect(third.messages.map(\.subject) == ["S1"])
        #expect(third.next == nil)

        let ids = (1...5).map { "e\($0)" }
        server.remove("e2")
        let whole = try await provider.checkSaved(ids, in: inbox, since: nil)
        #expect(whole.gone == ["e2"])
        #expect(whole.token != nil)

        server.markSeen("e1")
        server.remove("e3")
        let mark = server.requests.count
        let changes = try await provider.checkSaved(ids, in: inbox, since: whole.token)
        #expect(changes.gone == ["e3"])
        #expect(changes.flags == ["e1": [.seen]])
        #expect(server.requests.dropFirst(mark).first == ["Email/changes"])
    }

    @Test func savedMailTakesInChecksAndClears() async throws {
        let cache = MailCache(url: nil)
        let account = UUID()
        let messages = (0..<800).map { index in
            MailMessage(id: "INBOX/\(index)", mailboxID: "INBOX", from: EmailAddress(address: "a@example.com"),
                        subject: "Note \(index)", date: Date(timeIntervalSince1970: Double(1_000_000 + index)))
        }
        await cache.addThreads(messages.map { MailThread(id: $0.id, messages: [$0]) }, account: account, mailbox: "INBOX")
        await cache.saveDownloadProgress(.init(position: "12", done: nil), account: account, mailbox: "INBOX")
        #expect(await cache.downloadProgress(account: account, mailbox: "INBOX")?.position == "12")

        await cache.apply(SavedMailCheck(flags: ["INBOX/5": [.seen]], gone: ["INBOX/6"]), account: account, mailbox: "INBOX")
        #expect(await cache.message(id: "INBOX/5", account: account)?.flags == [.seen])
        #expect(await cache.message(id: "INBOX/6", account: account) == nil)
        #expect(await cache.search("Note 6").allSatisfy { $0.message.id != "INBOX/6" })

        await cache.clearDownloaded(keepNewest: 500)
        #expect(await cache.messageCount() == 500)
        #expect(await cache.downloadProgress(account: account, mailbox: "INBOX") == nil)
        #expect(await cache.usage().bytes > 0)
    }
}
