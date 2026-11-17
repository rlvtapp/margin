import Foundation
import Testing
@testable import MailCore

/// How long "Check for New Mail" takes against a server that answers each command after
/// `latency`, the way a real one does. Prints its timings (`swift test --filter CheckSpeed`)
/// and holds the number of commands a check sends, which is what decides its time.
@Suite(.serialized) struct CheckSpeedTests {
    let inbox = Mailbox(id: "INBOX", name: "Inbox", role: .inbox)
    /// A round trip plus the server's own work: iCloud answered a bare command in 138 ms from
    /// the Netherlands, Gmail and Outlook in 10 to 20 ms before any real work.
    let latency = Duration.milliseconds(100)

    func provider(_ server: FakeServer) throws -> IMAPProvider {
        let account = MailAccount(
            label: "Speed", address: EmailAddress(address: "me@example.com"),
            connection: .imap(
                incoming: ServerEndpoint(host: "127.0.0.1", port: server.port, security: .plain),
                outgoing: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain)
            ),
            auth: .password(username: "me@example.com")
        )
        return try IMAPProvider(account: account, credentials: LiveProtocolTests.Password())
    }

    /// What the app does for one mailbox on every check (`MailModel.load`).
    func check(_ provider: IMAPProvider) async throws -> [MailThread] {
        let boxes = try await provider.mailboxes()
        let inbox = try #require(boxes.first { $0.role == .inbox })
        return try await provider.threads(in: inbox, limit: 200)
    }

    func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    @Test func aCheckWithNothingNewIsOneCommand() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 CONDSTORE IDLE", subjects: (1...200).map { "Mail \($0)" })
        let server = try await FakeServer(greeting: "* OK Fake ready", delay: latency, respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)

        let clock = ContinuousClock()
        var mark = mailbox.commands.count
        let first = try await clock.measure { _ = try await check(provider) }
        let launch = Array(mailbox.commands.dropFirst(mark))
        mark = mailbox.commands.count
        let again = try await clock.measure { _ = try await check(provider) }
        let quiet = Array(mailbox.commands.dropFirst(mark))
        mailbox.add("New one")
        mark = mailbox.commands.count
        let arrived = try await clock.measure { _ = try await check(provider) }
        let fresh = Array(mailbox.commands.dropFirst(mark))
        print("check-speed first check: \(milliseconds(first)) ms, \(launch.count) commands: \(launch.map { $0.prefix(24) })")
        print("check-speed nothing new: \(milliseconds(again)) ms, \(quiet.count) commands: \(quiet.map { $0.prefix(24) })")
        print("check-speed one new mail: \(milliseconds(arrived)) ms, \(fresh.count) commands: \(fresh.map { $0.prefix(24) })")
        // The folder list is kept between checks: only the inbox is asked.
        #expect(quiet == ["SELECT \"INBOX\" (CONDSTORE)"])
        await provider.disconnect()
    }

    /// Reading ahead, scanning for invitations and the assistant download whole messages on
    /// the same connection a check uses. A check waits for the one that's under way, not for
    /// every one that's queued.
    @Test func aCheckGoesAheadOfQueuedDownloads() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 CONDSTORE IDLE", subjects: (1...60).map { "Mail \($0)" })
        mailbox.bodySize = 60_000
        let server = try await FakeServer(greeting: "* OK Fake ready", delay: latency, respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)
        let messages = try await check(provider).flatMap(\.messages)

        // Twelve downloads at once (the assistant asks for up to 24 together), as the check starts.
        let mark = mailbox.commands.count
        let downloads = Task {
            await withTaskGroup(of: Void.self) { group in
                for message in messages.prefix(12) {
                    group.addTask { _ = try? await provider.body(of: message) }
                }
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        let clock = ContinuousClock()
        let waited = try await clock.measure { _ = try await check(provider) }
        let all = await clock.measure { await downloads.value }
        print("check-speed check during 12 downloads: \(milliseconds(waited)) ms (downloads finished \(milliseconds(all)) ms later)")
        // The check went ahead of the queue: at most the download under way came before it.
        let round = Array(mailbox.commands.dropFirst(mark))
        let select = try #require(round.firstIndex { $0.hasPrefix("SELECT") })
        #expect(round[..<select].filter { $0.contains("BODY.PEEK[]") }.count <= 1)
        await provider.disconnect()
    }

    /// Previews come in one request per part, whatever each message's character set and
    /// encoding: asking per combination took a round trip each, one after the other.
    @Test func previewsAreOneRequestPerPart() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 CONDSTORE", subjects: (1...24).map { "Mail \($0)" })
        mailbox.structured = true
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)
        let threads = try await check(provider)
        let previews = mailbox.commands.filter { $0.contains("BODY.PEEK[1]<0.") }
        #expect(previews.count == 1)
        #expect(threads.flatMap(\.messages).allSatisfy { $0.snippet == "Hello from \($0.subject)" })
        await provider.disconnect()
    }

    /// Outlook and Microsoft 365 have no CONDSTORE: a check still sends only what it must.
    @Test func plainIMAPChecks() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 IDLE", subjects: (1...200).map { "Mail \($0)" })
        let server = try await FakeServer(greeting: "* OK Fake ready", delay: latency, respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)
        _ = try await check(provider)
        let clock = ContinuousClock()
        var mark = mailbox.commands.count
        let quiet = try await clock.measure { _ = try await check(provider) }
        let quietCommands = Array(mailbox.commands.dropFirst(mark))
        mailbox.add("New one")
        mark = mailbox.commands.count
        let arrived = try await clock.measure { _ = try await check(provider) }
        let freshCommands = Array(mailbox.commands.dropFirst(mark))
        print("check-speed plain nothing new: \(milliseconds(quiet)) ms, \(quietCommands.count) commands: \(quietCommands.map { $0.prefix(24) })")
        print("check-speed plain one new mail: \(milliseconds(arrived)) ms, \(freshCommands.count) commands: \(freshCommands.map { $0.prefix(24) })")
        #expect(quietCommands.count == 2)
        #expect(freshCommands.count == 3)
        await provider.disconnect()
    }
}
