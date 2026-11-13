import Foundation
import Network
import Testing
@testable import MailCore

/// Opening a mail: on its own connection, text before attachments, a conversation in one request.
@Suite(.serialized) struct OpenedMailTests {
    static let small = "From: Maya <maya@studio.example>\r\nSubject: Hi\r\nContent-Type: text/plain\r\n\r\nSee you at ten.\r\n"

    /// A message with a short text and a file far bigger than what's fetched first.
    static let large: String = {
        let file = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldY\r\n", count: 9000)
        return "From: Sam <sam@example.com>\r\nSubject: Report\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: multipart/mixed; boundary=\"edge\"\r\n\r\n"
            + "--edge\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nThe report is attached.\r\n"
            + "--edge\r\nContent-Type: application/pdf; name=\"report.pdf\"\r\nContent-Disposition: attachment; filename=\"report.pdf\"\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\n" + file + "--edge--\r\n"
    }()

    private func server(_ log: Log) async throws -> FakeServer {
        try await FakeServer(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Fake ready") { line in
            log.append(line)
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return "" }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "CAPABILITY": return "* CAPABILITY IMAP4rev1 MOVE UIDPLUS\r\n\(tag) OK done\r\n"
            case "LOGIN": return "\(tag) OK logged in\r\n"
            case "LIST": return "* LIST (\\HasNoChildren) \"/\" INBOX\r\n\(tag) OK listed\r\n"
            case "SELECT": return "* 3 EXISTS\r\n* OK [UIDVALIDITY 1] ok\r\n\(tag) OK [READ-WRITE] selected\r\n"
            case "UID":
                let small = OpenedMailTests.small, large = OpenedMailTests.large
                if line.contains("FETCH 11 ") && line.contains("<0.") {
                    return "* 1 FETCH (UID 11 RFC822.SIZE \(small.utf8.count) BODY[]<0> {\(small.utf8.count)}\r\n\(small))\r\n\(tag) OK fetched\r\n"
                }
                if line.contains("FETCH 13 ") && line.contains("<0.") {
                    let start = String(large.prefix(IMAPProvider.openingBytes))
                    return "* 3 FETCH (UID 13 RFC822.SIZE \(large.utf8.count) BODY[]<0> {\(start.utf8.count)}\r\n\(start))\r\n\(tag) OK fetched\r\n"
                }
                if line.contains("BODY.PEEK[])") {
                    var reply = ""
                    if line.contains("11") { reply += "* 1 FETCH (UID 11 BODY[] {\(small.utf8.count)}\r\n\(small))\r\n" }
                    if line.contains("12") { reply += "* 2 FETCH (UID 12 BODY[] {\(small.utf8.count)}\r\n\(small))\r\n" }
                    if line.contains("13") { reply += "* 3 FETCH (UID 13 BODY[] {\(large.utf8.count)}\r\n\(large))\r\n" }
                    return reply + "\(tag) OK fetched\r\n"
                }
                return "\(tag) OK done\r\n"
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

    private func message(_ uid: Int) -> MailMessage {
        MailMessage(id: "INBOX/\(uid)", mailboxID: "INBOX", from: EmailAddress(address: "sam@example.com"), subject: "Hi", date: Date())
    }

    @Test func aSmallMailIsWholeInOneRequestOnItsOwnConnection() async throws {
        let log = Log()
        let imap = try await server(log)
        defer { imap.stop() }
        let provider = try provider(port: imap.port)
        _ = try await provider.mailboxes()

        let opened = try await provider.openedBody(of: message(11))
        #expect(opened.isComplete)
        #expect(opened.body.text == "See you at ten.")
        // The first connection does the background work; the mail on screen has another.
        #expect(log.lines.filter { $0.contains(" LOGIN ") }.count == 2)
        #expect(log.lines.filter { $0.contains(" UID FETCH ") }.count == 1)
        await provider.disconnect()
    }

    @Test func conversationHistoryLeavesTheOpeningConnectionFree() async throws {
        let log = Log()
        let imap = try await server(log)
        defer { imap.stop() }
        let provider = try provider(port: imap.port)
        // History uses the ordinary connection. Opening another message gets a separate one.
        _ = try await provider.bodies(of: [message(11), message(12)])
        #expect(log.lines.filter { $0.contains(" LOGIN ") }.count == 1)
        let opened = try await provider.openedBody(of: message(11))
        #expect(opened.body.text == "See you at ten.")
        #expect(log.lines.filter { $0.contains(" LOGIN ") }.count == 2)
        await provider.disconnect()
    }

    @Test func aMailWithALargeFileShowsItsTextFirst() async throws {
        let log = Log()
        let imap = try await server(log)
        defer { imap.stop() }
        let provider = try provider(port: imap.port)

        let opened = try await provider.openedBody(of: message(13))
        #expect(!opened.isComplete)
        #expect(opened.body.isPartial == true)
        #expect(opened.body.text == "The report is attached.")
        #expect(opened.body.attachments.isEmpty)
        // Only the start was asked for.
        #expect(log.lines.filter { $0.contains(" UID FETCH ") }.allSatisfy { $0.contains("<0.\(IMAPProvider.openingBytes)>") })

        // The whole message follows, file and all.
        let whole = try #require(try await provider.bodies(of: [message(13)])["INBOX/13"])
        #expect(whole.isPartial != true)
        #expect(whole.attachments.map(\.filename) == ["report.pdf"])
        #expect((whole.attachments.first?.data?.count ?? 0) > 200_000)
        await provider.disconnect()
    }

    @Test func aConversationComesInOneRequest() async throws {
        let log = Log()
        let imap = try await server(log)
        defer { imap.stop() }
        let provider = try provider(port: imap.port)

        let bodies = try await provider.bodies(of: [message(11), message(12)])
        #expect(Set(bodies.keys) == ["INBOX/11", "INBOX/12"])
        #expect(log.lines.filter { $0.contains(" UID FETCH ") }.count == 1)
        await provider.disconnect()
    }

    @Test func theStartIsOnlyShownWhenItHoldsAllTheText() {
        // Cut inside the file: the text is whole, so it can be shown.
        let start = Array(Self.large.utf8.prefix(IMAPProvider.openingBytes))
        let body = IMAPProvider.readableStart(of: start)
        #expect(body?.text == "The report is attached.")
        #expect(body?.isPartial == true)

        // Cut inside the text itself (a very long newsletter, no file reached yet): not shown
        // half-finished; the whole message is fetched instead.
        let long = "From: News <news@example.com>\r\nSubject: Issue\r\nContent-Type: text/html\r\n\r\n<p>" + String(repeating: "word ", count: 60_000)
        #expect(IMAPProvider.readableStart(of: Array(long.utf8.prefix(IMAPProvider.openingBytes))) == nil)
    }
}
