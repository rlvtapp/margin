import Foundation
import Testing
@testable import MailCore

/// What IMAP folders held is kept between launches: the first check after starting asks only
/// for what changed while the app was closed, and gets the same answer a full download would.
@Suite(.serialized) struct SyncStoreTests {
    let inbox = Mailbox(id: "INBOX", name: "Inbox", role: .inbox)

    func provider(_ server: FakeServer, store: IMAPSyncStore, host: String = "127.0.0.1", user: String = "me@example.com",
                  id: UUID) throws -> IMAPProvider {
        var account = MailAccount(
            label: "Saved", address: EmailAddress(address: "me@example.com"),
            connection: .imap(
                incoming: ServerEndpoint(host: host, port: server.port, security: .plain),
                outgoing: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain)
            ),
            auth: .password(username: user)
        )
        account.id = id
        return try IMAPProvider(account: account, credentials: LiveProtocolTests.Password(), syncStore: store)
    }

    func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "imap-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// The save happens on the side; this waits until it's on disk.
    func saved(in folder: URL, _ id: UUID) async {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: folder.appending(path: "\(id.uuidString).json").path) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    func summary(_ threads: [MailThread]) -> [String] {
        threads.flatMap(\.messages).sorted { $0.id < $1.id }.map { "\($0.id) \($0.subject) \($0.isUnread ? "unread" : "read")" }
    }

    @Test(arguments: ["IMAP4rev1 CONDSTORE", "IMAP4rev1 ENABLE CONDSTORE QRESYNC", "IMAP4rev1"])
    func aRelaunchAsksOnlyForWhatChanged(capabilities: String) async throws {
        let mailbox = FakeIMAPMailbox(capabilities: capabilities, subjects: ["One", "Two", "Three", "Four"])
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let folder = folder(), id = UUID()
        let first = try provider(server, store: IMAPSyncStore(folder: folder), id: id)
        _ = try await first.threads(in: inbox, limit: 50)
        await saved(in: folder, id)
        await first.disconnect()

        // While the app is closed: new mail, a read mark from another device, one deleted.
        mailbox.add("Five")
        mailbox.markSeen(1)
        mailbox.expunge(2)

        let mark = mailbox.commands.count
        let again = try provider(server, store: IMAPSyncStore(folder: folder), id: id)
        let threads = try await again.threads(in: inbox, limit: 50)
        let round = Array(mailbox.commands.dropFirst(mark))
        #expect(summary(threads) == ["INBOX/1 One read", "INBOX/3 Three unread", "INBOX/4 Four unread", "INBOX/5 Five unread"])
        // No full download: only the new message is fetched whole.
        #expect(!round.contains { $0.hasPrefix("FETCH ") })
        #expect(round.filter { $0.contains("ENVELOPE") } == ["UID FETCH 5 \(IMAPProvider.listItems)"])
        await again.disconnect()
    }

    @Test func aRenumberedFolderOrAnotherServerStartsAfresh() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 CONDSTORE", subjects: ["One", "Two"])
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let folder = folder(), id = UUID()
        let first = try provider(server, store: IMAPSyncStore(folder: folder), id: id)
        _ = try await first.threads(in: inbox, limit: 50)
        await saved(in: folder, id)
        await first.disconnect()

        // The mailbox now signs in as someone else: what was saved isn't theirs.
        var mark = mailbox.commands.count
        let other = try provider(server, store: IMAPSyncStore(folder: folder), user: "someone@example.com", id: id)
        _ = try await other.threads(in: inbox, limit: 50)
        #expect(mailbox.commands.dropFirst(mark).contains { $0.hasPrefix("FETCH 1:2") })
        await other.disconnect()

        // The folder was renumbered while closed: every saved UID names another message now.
        mailbox.renumber()
        mark = mailbox.commands.count
        let again = try provider(server, store: IMAPSyncStore(folder: folder), id: id)
        let threads = try await again.threads(in: inbox, limit: 50)
        #expect(mailbox.commands.dropFirst(mark).contains { $0.hasPrefix("FETCH 1:2") })
        #expect(threads.flatMap(\.messages).map(\.id).sorted() == ["INBOX/101", "INBOX/102"])
        await again.disconnect()
    }

    @Test func removedMailboxesAreForgotten() async throws {
        let folder = folder(), keep = UUID(), gone = UUID()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in [keep, gone] { try Data("{}".utf8).write(to: folder.appending(path: "\(id.uuidString).json")) }
        await IMAPSyncStore(folder: folder).keepOnly([keep])
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(keep.uuidString).json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "\(gone.uuidString).json").path))
    }
}
