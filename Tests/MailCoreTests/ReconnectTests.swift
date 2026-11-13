import Foundation
import Network
import Testing
@testable import MailCore

/// A connection that died while nobody was looking is replaced, and the request that found
/// out is done again, instead of every request failing with "Socket is not connected".
@Suite(.serialized) struct ReconnectTests {
    private func server(_ log: Log) async throws -> FakeServer {
        try await FakeServer(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Fake ready") { line in
            log.append(line)
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return "" }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "CAPABILITY": return "* CAPABILITY IMAP4rev1 MOVE UIDPLUS\r\n\(tag) OK done\r\n"
            case "LOGIN": return "\(tag) OK logged in\r\n"
            case "LIST": return "* LIST (\\HasNoChildren) \"/\" INBOX\r\n* LIST (\\HasNoChildren \\Drafts) \"/\" Drafts\r\n\(tag) OK listed\r\n"
            case "SELECT": return "* 1 EXISTS\r\n* OK [UIDVALIDITY 1] ok\r\n\(tag) OK [READ-WRITE] selected\r\n"
            case "FETCH":
                return "* 1 FETCH (UID 11 FLAGS () ENVELOPE (\"Tue, 3 Nov 2026 10:00:00 +0100\" \"Hi\" ((\"Maya\" NIL \"maya\" \"studio.example\")) NIL NIL ((NIL NIL \"me\" \"example.com\")) NIL NIL NIL \"<m1@studio.example>\"))\r\n\(tag) OK fetched\r\n"
            case "LOGOUT": return "* BYE bye\r\n\(tag) OK bye\r\n"
            default: return "\(tag) OK done\r\n"
            }
        }
    }

    private func provider(port: Int) throws -> IMAPProvider {
        let account = MailAccount(
            label: "Test", address: EmailAddress(address: "me@example.com"),
            connection: .imap(incoming: ServerEndpoint(host: "127.0.0.1", port: port, security: .plain),
                              outgoing: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain)),
            auth: .password(username: "me@example.com")
        )
        return try IMAPProvider(account: account, credentials: LiveProtocolTests.Password())
    }

    private func signIns(_ log: Log) -> Int { log.lines.filter { $0.contains(" LOGIN ") }.count }

    @Test func aTemporaryOutlookRefusalDoesNotAskForANewSignIn() async throws {
        let log = Log()
        let imap = try await FakeServer(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Fake ready") { line in
            log.append(line)
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return "" }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "LOGIN": return "\(tag) NO User is authenticated but not connected.\r\n"
            case "LOGOUT": return "* BYE bye\r\n\(tag) OK bye\r\n"
            default: return "\(tag) OK done\r\n"
            }
        }
        defer { imap.stop() }
        let provider = try provider(port: imap.port)
        do {
            _ = try await provider.mailboxes()
            Issue.record("The temporary refusal should be reported after bounded retries.")
        } catch {
            #expect(MailError.isConnectionProblem(error))
            #expect(signIns(log) == 4)
        }
        await provider.disconnect()
    }

    @Test func aDeadConnectionIsReplacedAndTheRequestDoneAgain() async throws {
        let log = Log()
        let imap = try await server(log)
        defer { imap.stop() }
        let provider = try provider(port: imap.port)

        #expect(try await provider.mailboxes().map(\.id) == ["INBOX", "Drafts"])
        #expect(signIns(log) == 1)

        // The line goes dead behind the app's back.
        imap.hangUp()
        try await Task.sleep(for: .milliseconds(150))

        // The next request doesn't fail: it signs in again and gets its answer.
        #expect(try await provider.mailboxes().map(\.id) == ["INBOX", "Drafts"])
        #expect(signIns(log) == 2)

        // And reading mail after another drop works the same way.
        imap.hangUp()
        try await Task.sleep(for: .milliseconds(150))
        let inbox = Mailbox(id: "INBOX", name: "Inbox", role: .inbox)
        #expect(try await provider.threads(in: inbox, limit: 50).count == 1)
        #expect(signIns(log) == 3)
        await provider.disconnect()
    }

    @Test func aServerThatIsReallyGoneIsReportedAndRecoversLater() async throws {
        let log = Log()
        let imap = try await server(log)
        let provider = try provider(port: imap.port)
        _ = try await provider.mailboxes()

        // The server goes away altogether: that's a real failure, said as one.
        imap.stop()
        imap.hangUp()
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: MailError.self) { _ = try await provider.mailboxes() }

        // A later try isn't stuck on the dead connection: it fails by trying to connect anew.
        do {
            _ = try await provider.mailboxes()
            Issue.record("The server is gone; this should have failed.")
        } catch {
            #expect(MailError.isConnectionProblem(error))
        }
        await provider.disconnect()
    }

    /// Adding a message can't be repeated blindly (it would be added twice), so the connection
    /// is checked first and replaced if it's dead: the draft is saved once.
    @Test func savingADraftChecksTheConnectionFirst() async throws {
        let log = Log()
        let imap = try await server(log)
        defer { imap.stop() }
        let provider = try provider(port: imap.port)
        _ = try await provider.mailboxes()
        imap.hangUp()
        try await Task.sleep(for: .milliseconds(150))
        // The fake server answers APPEND's literal request with OK straight away, which the
        // client reads as a refusal to take the literal; what matters is that it signed in again
        // to try, and tried once.
        _ = try? await provider.saveDraft(Draft(from: EmailAddress(address: "me@example.com"), to: [], subject: "Hi", text: "Later"))
        #expect(signIns(log) == 2)
        #expect(log.lines.filter { $0.contains(" APPEND ") }.count == 1)
        await provider.disconnect()
    }
}
