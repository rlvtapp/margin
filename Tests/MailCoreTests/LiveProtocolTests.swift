import Foundation
import Network
import Testing
@testable import MailCore

/// Runs the real IMAP and SMTP clients against scripted servers on localhost.
@Suite(.serialized) struct LiveProtocolTests {
    struct Password: CredentialSource {
        func secret(for account: MailAccount) async throws -> String { "s3cret pass" }
    }

    @Test func readsAndChangesMailOverIMAP() async throws {
        let log = Log()
        let header = "List-Id: <weekly.example>\r\n\r\n"
        let body = "From: Maya <maya@studio.example>\r\nSubject: Hi\r\nContent-Type: text/plain\r\n\r\nSee you at ten.\r\n"
        let imap = try await FakeServer(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Fake ready") { line in
            log.append(line)
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return "" }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "CAPABILITY":
                return "* CAPABILITY IMAP4rev1 MOVE UIDPLUS\r\n\(tag) OK done\r\n"
            case "LOGIN":
                return line.contains("\"s3cret pass\"") ? "\(tag) OK logged in\r\n" : "\(tag) NO wrong\r\n"
            case "LIST":
                return """
                * LIST (\\HasNoChildren) "/" INBOX\r
                * LIST (\\HasNoChildren \\Archive) "/" Archive\r
                * LIST (\\HasNoChildren \\Sent) "/" Sent\r
                \(tag) OK listed\r

                """
            case "SELECT":
                return "* 2 EXISTS\r\n* OK [UIDVALIDITY 1] ok\r\n\(tag) OK [READ-WRITE] selected\r\n"
            case "FETCH":
                return "* 1 FETCH (UID 11 FLAGS () ENVELOPE (\"Tue, 3 Nov 2026 10:00:00 +0100\" \"Hi\" ((\"Maya\" NIL \"maya\" \"studio.example\")) NIL NIL ((NIL NIL \"me\" \"example.com\")) NIL NIL NIL \"<m1@studio.example>\"))\r\n"
                    + "* 2 FETCH (UID 12 FLAGS (\\Seen) ENVELOPE (\"Tue, 3 Nov 2026 11:00:00 +0100\" \"Issue 4\" ((\"Weekly\" NIL \"editor\" \"weekly.example\")) NIL NIL NIL NIL NIL NIL \"<w4@weekly.example>\") "
                    + "BODY[HEADER.FIELDS (LIST-ID LIST-UNSUBSCRIBE PRECEDENCE REFERENCES AUTO-SUBMITTED)] {\(header.utf8.count)}\r\n\(header))\r\n"
                    + "\(tag) OK fetched\r\n"
            case "UID":
                if line.contains("BODY.PEEK[]") {
                    return "* 1 FETCH (UID 11 BODY[]<0> {\(body.utf8.count)}\r\n\(body))\r\n\(tag) OK fetched\r\n"
                }
                return "\(tag) OK done\r\n"
            case "LOGOUT":
                return "* BYE bye\r\n\(tag) OK bye\r\n"
            default:
                return "\(tag) BAD unknown\r\n"
            }
        }
        defer { imap.stop() }

        let account = MailAccount(
            label: "Test", address: EmailAddress(address: "me@example.com"),
            connection: .imap(
                incoming: ServerEndpoint(host: "127.0.0.1", port: imap.port, security: .plain),
                outgoing: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain)
            ),
            auth: .password(username: "me@example.com")
        )
        let provider = try IMAPProvider(account: account, credentials: Password())
        let folders = try await provider.mailboxes()
        #expect(folders.map(\.role) == [.inbox, .archive, .sent])

        let threads = try await provider.threads(in: folders[0], limit: 50)
        #expect(threads.map(\.subject) == ["Issue 4", "Hi"])
        #expect(threads[0].split == .newsletters)
        #expect(threads[1].isUnread)

        let text = try await provider.body(of: threads[1].latest)
        #expect(text.text.trimmingCharacters(in: .whitespacesAndNewlines) == "See you at ten.")

        try await provider.perform(.markRead, on: [threads[1]])
        try await provider.perform(.done, on: [threads[1]])
        await provider.disconnect()

        let commands = log.lines.map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        #expect(commands.contains("UID STORE 11 +FLAGS.SILENT (\\Seen)"))
        #expect(commands.contains("UID MOVE 11 \"Archive\""))
    }

    @Test func sendsOverSMTP() async throws {
        let log = Log()
        let state = Log()
        let smtp = try await FakeServer(greeting: "220 fake.example ESMTP") { line in
            if state.lines.last == "DATA" {
                log.append(line)
                if line == "." { state.append("DONE"); return "250 2.0.0 queued\r\n" }
                return ""
            }
            state.append(line.uppercased().hasPrefix("DATA") ? "DATA" : "CMD")
            log.append(line)
            switch line.prefix(4).uppercased() {
            case "EHLO": return "250-fake.example\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n"
            case "AUTH": return line == "AUTH PLAIN \(SASL.plain(username: "me@example.com", password: "s3cret pass"))" ? "235 ok\r\n" : "535 no\r\n"
            case "MAIL", "RCPT": return "250 ok\r\n"
            case "DATA": return "354 go\r\n"
            case "QUIT": return "221 bye\r\n"
            default: return "500 what\r\n"
            }
        }
        defer { smtp.stop() }

        let client = try SMTPClient(endpoint: ServerEndpoint(host: "127.0.0.1", port: smtp.port, security: .plain))
        try await client.open(security: .plain)
        try await client.authenticate(username: "me@example.com", password: "s3cret pass")
        let draft = Draft(from: EmailAddress(address: "me@example.com"), to: [EmailAddress(address: "maya@studio.example")],
                          subject: "Hello", text: "First\n.second")
        try await client.send(from: "me@example.com", to: ["maya@studio.example"], message: MessageBuilder.build(draft))
        await client.quit()

        #expect(log.lines.contains("MAIL FROM:<me@example.com>"))
        #expect(log.lines.contains("RCPT TO:<maya@studio.example>"))
        #expect(log.lines.contains("..second"))
        #expect(log.lines.contains("Subject: Hello"))
    }

    @Test func refusesPlainTextToRemoteHosts() {
        #expect(throws: MailError.insecureConnection) {
            try LineConnection(endpoint: ServerEndpoint(host: "mail.example.com", port: 143, security: .plain))
        }
    }
}

final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}

/// A line-based TCP server on localhost that answers each line with a script.
final class FakeServer: @unchecked Sendable {
    let port: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-server")

    init(greeting: String, respond: @escaping @Sendable (String) -> String) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: Data((greeting + "\r\n").utf8), completion: .contentProcessed { _ in })
            FakeServer.receive(on: connection, buffer: Data(), respond: respond)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume(returning: Int(listener.port!.rawValue)) }
                case .failed(let error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private static func receive(on connection: NWConnection, buffer: Data, respond: @escaping @Sendable (String) -> String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer + (data ?? Data())
            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                buffer = Data(buffer[(newline + 1)...])
                let reply = respond(line)
                if !reply.isEmpty { connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in }) }
            }
            if complete || error != nil { connection.cancel(); return }
            receive(on: connection, buffer: buffer, respond: respond)
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

@Suite struct IdleTests {
    /// The server pushes "* 3 EXISTS" during IDLE; the provider reports a change and ends the IDLE.
    @Test func reportsNewMailFromIdle() async throws {
        let log = Log()
        let idleTag = Box()
        let imap = try await FakeServer(greeting: "* OK [CAPABILITY IMAP4rev1 IDLE AUTH=PLAIN] Fake ready") { line in
            log.append(line)
            if line == "DONE" { return "\(idleTag.value) OK IDLE done\r\n" }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return "" }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "LOGIN": return "\(tag) OK logged in\r\n"
            case "SELECT": return "* 2 EXISTS\r\n\(tag) OK [READ-WRITE] selected\r\n"
            case "IDLE":
                idleTag.value = tag
                return "+ idling\r\n* 3 EXISTS\r\n"
            default: return "\(tag) OK\r\n"
            }
        }
        defer { imap.stop() }
        let account = MailAccount(
            label: "Test", address: EmailAddress(address: "me@example.com"),
            connection: .imap(
                incoming: ServerEndpoint(host: "127.0.0.1", port: imap.port, security: .plain),
                outgoing: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain)
            ),
            auth: .password(username: "me@example.com")
        )
        let provider = try IMAPProvider(account: account, credentials: LiveProtocolTests.Password())
        let changed = try await provider.waitForInboxChange(timeout: .seconds(5))
        #expect(changed)
        #expect(log.lines.contains("DONE"))
        await provider.disconnect()
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
