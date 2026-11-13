import Foundation
import Testing
@testable import MailCore

/// Refreshes fetch only what changed: IMAP CONDSTORE/QRESYNC, plain UIDs, and JMAP `/changes`.
@Suite(.serialized) struct IMAPSyncTests {
    let inbox = Mailbox(id: "INBOX", name: "Inbox", role: .inbox)

    func provider(_ server: FakeServer) throws -> IMAPProvider {
        let account = MailAccount(
            label: "Test", address: EmailAddress(address: "me@example.com"),
            connection: .imap(
                incoming: ServerEndpoint(host: "127.0.0.1", port: server.port, security: .plain),
                outgoing: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plain)
            ),
            auth: .password(username: "me@example.com")
        )
        return try IMAPProvider(account: account, credentials: LiveProtocolTests.Password())
    }

    @Test func qresyncFetchesOnlyNewMessages() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 ENABLE CONDSTORE QRESYNC", subjects: ["One", "Two", "Three"])
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)

        let first = try await provider.threads(in: inbox, limit: 50)
        #expect(first.map(\.subject) == ["Three", "Two", "One"])
        #expect(mailbox.commands.contains("ENABLE QRESYNC"))
        let modSeq = mailbox.modSeq

        mailbox.add("Four")
        mailbox.markSeen(1)
        mailbox.expunge(2)
        var mark = mailbox.commands.count
        let second = try await provider.threads(in: inbox, limit: 50)
        #expect(second.map(\.subject) == ["Four", "Three", "One"])
        #expect(second.first { $0.subject == "One" }?.isUnread == false)
        var round = Array(mailbox.commands.dropFirst(mark))
        #expect(round.first == "SELECT \"INBOX\" (QRESYNC (7 \(modSeq) 1:3))")
        #expect(round.contains("UID SEARCH UID 4:*"))
        #expect(round.contains { $0.hasPrefix("UID FETCH 4 (UID FLAGS ENVELOPE") })
        #expect(!round.contains { $0.hasPrefix("FETCH ") })

        // Nothing changed: the SELECT alone answers.
        mark = mailbox.commands.count
        let third = try await provider.threads(in: inbox, limit: 50)
        #expect(third.map(\.subject) == ["Four", "Three", "One"])
        round = Array(mailbox.commands.dropFirst(mark))
        #expect(round.count == 1)
        await provider.disconnect()
    }

    @Test func condstoreAsksForChangedFlagsOnly() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 CONDSTORE", subjects: ["One", "Two", "Three"])
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)

        _ = try await provider.threads(in: inbox, limit: 50)
        #expect(!mailbox.commands.contains("ENABLE QRESYNC"))
        let modSeq = mailbox.modSeq
        mailbox.markSeen(3)
        mailbox.add("Four")
        mailbox.expunge(1)
        var mark = mailbox.commands.count
        let second = try await provider.threads(in: inbox, limit: 50)
        #expect(second.map(\.subject) == ["Four", "Three", "Two"])
        #expect(second.first { $0.subject == "Three" }?.isUnread == false)
        var round = Array(mailbox.commands.dropFirst(mark))
        #expect(round.first == "SELECT \"INBOX\" (CONDSTORE)")
        #expect(round.contains("UID SEARCH UID 1:*"))
        #expect(round.contains("UID FETCH 1:3 (UID FLAGS) (CHANGEDSINCE \(modSeq))"))
        #expect(round.contains { $0.hasPrefix("UID FETCH 4 (UID FLAGS ENVELOPE") })
        #expect(!round.contains { $0.hasPrefix("FETCH ") })

        // Same HIGHESTMODSEQ and count: nothing to ask.
        mark = mailbox.commands.count
        _ = try await provider.threads(in: inbox, limit: 50)
        round = Array(mailbox.commands.dropFirst(mark))
        #expect(round == ["SELECT \"INBOX\" (CONDSTORE)"])
        await provider.disconnect()
    }

    @Test func newUIDValidityFetchesEverythingAgain() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1 ENABLE CONDSTORE QRESYNC", subjects: ["One", "Two", "Three"])
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)

        _ = try await provider.threads(in: inbox, limit: 50)
        mailbox.renumber()
        let mark = mailbox.commands.count
        let second = try await provider.threads(in: inbox, limit: 50)
        #expect(second.map(\.subject) == ["Three", "Two", "One"])
        #expect(second.flatMap(\.messages).map(\.id).sorted() == ["INBOX/101", "INBOX/102", "INBOX/103"])
        let round = Array(mailbox.commands.dropFirst(mark))
        #expect(round.contains { $0.hasPrefix("FETCH 1:3 (UID FLAGS ENVELOPE") })
        await provider.disconnect()
    }

    @Test func withoutCondstoreFetchesNewUIDsAndFlags() async throws {
        let mailbox = FakeIMAPMailbox(capabilities: "IMAP4rev1", subjects: ["One", "Two", "Three", "Four"])
        let server = try await FakeServer(greeting: "* OK Fake ready", respond: { mailbox.respond($0) })
        defer { server.stop() }
        let provider = try provider(server)

        let first = try await provider.threads(in: inbox, limit: 2)
        #expect(first.map(\.subject) == ["Four", "Three"])

        // One left: the window is filled from just below it.
        mailbox.expunge(4)
        mailbox.markSeen(3)
        var mark = mailbox.commands.count
        let second = try await provider.threads(in: inbox, limit: 2)
        #expect(second.map(\.subject) == ["Three", "Two"])
        #expect(second.first?.isUnread == false)
        var round = Array(mailbox.commands.dropFirst(mark))
        #expect(round.contains("UID SEARCH UID 3:*"))
        #expect(round.contains("UID FETCH 3:4 (UID FLAGS)"))
        #expect(round.contains { $0.hasPrefix("FETCH 2:2 (UID FLAGS ENVELOPE") })

        mailbox.add("Five")
        mark = mailbox.commands.count
        let third = try await provider.threads(in: inbox, limit: 2)
        #expect(third.map(\.subject) == ["Five", "Three"])
        round = Array(mailbox.commands.dropFirst(mark))
        #expect(round.contains { $0.hasPrefix("UID FETCH 5 (UID FLAGS ENVELOPE") })
        #expect(!round.contains { $0.hasPrefix("FETCH ") })

        // Same count and UIDNEXT: only the cheap flags fetch.
        mark = mailbox.commands.count
        _ = try await provider.threads(in: inbox, limit: 2)
        round = Array(mailbox.commands.dropFirst(mark))
        #expect(round == ["SELECT \"INBOX\"", "UID FETCH 3:5 (UID FLAGS)"])
        await provider.disconnect()
    }

    @Test func parsesSelectResponseCodesAndVanished() {
        #expect(IMAPParser.responseCode("[UIDVALIDITY 42] ok")! == ("UIDVALIDITY", "42"))
        #expect(IMAPParser.responseCode("[NOMODSEQ] none")! == ("NOMODSEQ", ""))
        #expect(IMAPParser.responseCode("no code") == nil)
        #expect(IMAPParser.ranges("41,43:45") == [41...41, 43...45])
    }
}

/// One scripted IMAP mailbox that answers SELECT (with CONDSTORE and QRESYNC), UID SEARCH
/// and FETCH from its own state, so tests can change mail between refreshes.
final class FakeIMAPMailbox: @unchecked Sendable {
    struct Message {
        var uid: Int
        var subject: String
        var seen = false
        var modSeq: Int
    }

    private let lock = NSLock()
    private let capabilities: String
    private var uidValidity = 7
    private var messages: [Message] = []
    private var expunged: [(uid: Int, modSeq: Int)] = []
    private var nextUID = 1
    private var highest = 100
    private var log: [String] = []

    init(capabilities: String, subjects: [String]) {
        self.capabilities = capabilities
        for subject in subjects { add(subject) }
    }

    var commands: [String] { lock.withLock { log } }
    var modSeq: Int { lock.withLock { highest } }

    func add(_ subject: String) {
        lock.withLock {
            highest += 1
            messages.append(Message(uid: nextUID, subject: subject, modSeq: highest))
            nextUID += 1
        }
    }

    func markSeen(_ uid: Int) {
        lock.withLock {
            guard let index = messages.firstIndex(where: { $0.uid == uid }) else { return }
            highest += 1
            messages[index].seen = true
            messages[index].modSeq = highest
        }
    }

    func expunge(_ uid: Int) {
        lock.withLock {
            highest += 1
            messages.removeAll { $0.uid == uid }
            expunged.append((uid, highest))
        }
    }

    /// New UIDVALIDITY; the same messages come back as 101, 102, …
    func renumber() {
        lock.withLock {
            uidValidity += 1
            for index in messages.indices { messages[index].uid = 101 + index }
            nextUID = 101 + messages.count
            expunged = []
        }
    }

    func respond(_ line: String) -> String {
        lock.withLock {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "" }
            let tag = parts[0], command = parts[1]
            log.append(command)
            let word = command.split(separator: " ").first.map { $0.uppercased() } ?? ""
            switch word {
            case "CAPABILITY": return "* CAPABILITY \(capabilities)\r\n\(tag) OK done\r\n"
            case "LOGIN": return "\(tag) OK logged in\r\n"
            case "ENABLE": return "* ENABLED QRESYNC\r\n\(tag) OK enabled\r\n"
            case "LIST": return "* LIST (\\HasNoChildren) \"/\" INBOX\r\n\(tag) OK listed\r\n"
            case "SELECT": return select(command) + "\(tag) OK [READ-WRITE] selected\r\n"
            case "FETCH":
                let words = command.split(separator: " ", maxSplits: 2).map(String.init)
                let numbers = Self.numbers(words[1], max: messages.count)
                return messages.enumerated().filter { numbers.contains($0.offset + 1) }
                    .map { full($0.element, sequence: $0.offset + 1) }.joined() + "\(tag) OK fetched\r\n"
            case "UID":
                let words = command.split(separator: " ", maxSplits: 3).map(String.init)
                if words[1].uppercased() == "SEARCH" {
                    let set = words[3]
                    let low = Int(set.split(separator: ":")[0])!
                    var found = messages.map(\.uid).filter { $0 >= low }
                    // `n:*` always takes in the highest UID, even below n.
                    if found.isEmpty, let last = messages.last { found = [last.uid] }
                    return "* SEARCH \(found.map(String.init).joined(separator: " "))\r\n\(tag) OK searched\r\n"
                }
                let set = words[2], items = words[3]
                let uids = Self.numbers(set, max: Int.max)
                var since: Int?
                if let range = items.range(of: "CHANGEDSINCE ") { since = Int(items[range.upperBound...].dropLast()) }
                var out = ""
                for (offset, message) in messages.enumerated() where uids.contains(message.uid) {
                    if let since, message.modSeq <= since { continue }
                    out += items.contains("ENVELOPE") ? full(message, sequence: offset + 1) : short(message, sequence: offset + 1)
                }
                return out + "\(tag) OK fetched\r\n"
            case "LOGOUT": return "* BYE bye\r\n\(tag) OK bye\r\n"
            default: return "\(tag) BAD unknown\r\n"
            }
        }
    }

    private func select(_ command: String) -> String {
        var out = "* \(messages.count) EXISTS\r\n* OK [UIDVALIDITY \(uidValidity)] ok\r\n* OK [UIDNEXT \(nextUID)] ok\r\n"
        if capabilities.contains("CONDSTORE") { out += "* OK [HIGHESTMODSEQ \(highest)] ok\r\n" }
        guard let range = command.range(of: "(QRESYNC (") else { return out }
        let values = command[range.upperBound...].split(separator: " ").map { Int($0.filter(\.isNumber)) ?? 0 }
        guard values[0] == uidValidity else { return out }
        let since = values[1]
        let gone = expunged.filter { $0.modSeq > since }.map(\.uid)
        if !gone.isEmpty { out += "* VANISHED (EARLIER) \(IMAPClient.set(gone))\r\n" }
        for (offset, message) in messages.enumerated() where message.modSeq > since {
            out += short(message, sequence: offset + 1)
        }
        return out
    }

    private func full(_ message: Message, sequence: Int) -> String {
        "* \(sequence) FETCH (UID \(message.uid) FLAGS (\(message.seen ? "\\Seen" : "")) ENVELOPE (\"Tue, 3 Nov 2026 \(String(format: "%02d", message.uid % 24)):00:00 +0100\" \"\(message.subject)\" ((\"Sender\" NIL \"sender\" \"example.com\")) NIL NIL ((NIL NIL \"me\" \"example.com\")) NIL NIL NIL \"<\(message.subject)@example.com>\"))\r\n"
    }

    private func short(_ message: Message, sequence: Int) -> String {
        "* \(sequence) FETCH (UID \(message.uid) FLAGS (\(message.seen ? "\\Seen" : "")) MODSEQ (\(message.modSeq)))\r\n"
    }

    /// `1:3,7` → {1, 2, 3, 7}; `*` stands for `max`.
    static func numbers(_ set: String, max: Int) -> Set<Int> {
        var result = Set<Int>()
        for part in set.split(separator: ",") {
            let ends = part.split(separator: ":").map { $0 == "*" ? max : Int($0) ?? 0 }
            let low = Swift.min(ends[0], ends.last!), high = Swift.max(ends[0], ends.last!)
            guard high - low < 10_000 else { continue }
            for number in low...high { result.insert(number) }
        }
        return result
    }
}

// MARK: - JMAP

@Suite(.serialized) struct JMAPSyncTests {
    func provider(_ server: FakeJMAPServer) throws -> JMAPProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JMAPStub.self]
        let account = MailAccount(
            label: "Test", address: EmailAddress(address: "me@example.com"),
            connection: .jmap(sessionURL: URL(string: "https://\(server.host)/session")!),
            auth: .password(username: "me@example.com")
        )
        return try JMAPProvider(account: account, credentials: LiveProtocolTests.Password(), http: URLSession(configuration: configuration))
    }

    @Test func emailChangesFetchOnlyWhatChanged() async throws {
        let server = FakeJMAPServer(host: "changes.jmap.test")
        defer { server.stop() }
        for (index, subject) in ["One", "Two", "Three"].enumerated() { server.addEmail("e\(index + 1)", subject: subject) }
        let provider = try provider(server)
        let inbox = try await provider.mailboxes().first { $0.role == .inbox }!

        let first = try await provider.threads(in: inbox, limit: 50)
        #expect(first.map(\.subject) == ["Three", "Two", "One"])
        #expect(server.requests.last == ["Email/query", "Email/get", "Thread/get", "Email/get"])

        // A new email and a flag change: only those two are fetched.
        server.addEmail("e4", subject: "Four")
        server.markSeen("e1")
        var mark = server.requests.count
        let second = try await provider.threads(in: inbox, limit: 50)
        #expect(second.map(\.subject) == ["Four", "Three", "Two", "One"])
        #expect(second.last?.isUnread == false)
        #expect(Array(server.requests.dropFirst(mark)) == [
            ["Email/changes", "Email/get", "Email/get"],
            ["Email/query", "Email/get", "Thread/get"],
        ])
        #expect(server.fetchedEmails.suffix(2) == [["e4"], ["e1"]])

        // Only a flag changed: the list holds and nothing else is asked.
        server.markSeen("e2")
        mark = server.requests.count
        let third = try await provider.threads(in: inbox, limit: 50)
        #expect(third.first { $0.subject == "Two" }?.isUnread == false)
        #expect(Array(server.requests.dropFirst(mark)) == [["Email/changes", "Email/get", "Email/get"]])

        // Nothing changed.
        mark = server.requests.count
        _ = try await provider.threads(in: inbox, limit: 50)
        #expect(server.requests.count == mark + 1)
    }

    @Test func cannotCalculateChangesStartsOver() async throws {
        let server = FakeJMAPServer(host: "reset.jmap.test")
        defer { server.stop() }
        server.addEmail("e1", subject: "One")
        let provider = try provider(server)
        let inbox = try await provider.mailboxes().first { $0.role == .inbox }!
        _ = try await provider.threads(in: inbox, limit: 50)

        server.cannotCalculateChanges = true
        server.addEmail("e2", subject: "Two")
        let mark = server.requests.count
        let threads = try await provider.threads(in: inbox, limit: 50)
        #expect(threads.map(\.subject) == ["Two", "One"])
        #expect(Array(server.requests.dropFirst(mark)) == [
            ["Email/changes", "Email/get", "Email/get"],
            ["Email/query", "Email/get", "Thread/get", "Email/get"],
        ])
    }

    @Test func mailboxChangesFetchOnlyChangedFolders() async throws {
        let server = FakeJMAPServer(host: "folders.jmap.test")
        defer { server.stop() }
        let provider = try provider(server)
        _ = try await provider.mailboxes()

        server.setUnread("inbox", 3)
        var mark = server.requests.count
        let folders = try await provider.mailboxes()
        #expect(folders.first { $0.id == "inbox" }?.unreadCount == 3)
        #expect(folders.count == 2)
        #expect(Array(server.requests.dropFirst(mark)) == [["Mailbox/changes", "Mailbox/get", "Mailbox/get"]])
        #expect(server.fetchedMailboxes.suffix(2) == [[], ["inbox"]])

        server.cannotCalculateChanges = true
        mark = server.requests.count
        let again = try await provider.mailboxes()
        #expect(again.count == 2)
        #expect(Array(server.requests.dropFirst(mark)) == [["Mailbox/changes", "Mailbox/get", "Mailbox/get"], ["Mailbox/get"]])
    }
}

/// Answers JMAP requests for a `FakeJMAPServer`, found by host.
final class JMAPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: FakeJMAPServer] = [:]

    static func register(_ server: FakeJMAPServer) { lock.withLock { servers[server.host] = server } }
    static func remove(_ host: String) { _ = lock.withLock { servers.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let server = Self.lock.withLock { Self.servers[url.host() ?? ""] }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let data = server?.handle(path: url.path(), body: body) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: server == nil ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A small JMAP mail server in memory: two folders, emails with states and a change log,
/// and back-references between calls.
final class FakeJMAPServer: @unchecked Sendable {
    struct Email {
        var id: String
        var subject: String
        var received: Int
        var seen = false
    }

    let host: String
    private let lock = NSLock()
    private var emails: [Email] = []
    private var emailState = 0
    private var emailLog: [(state: Int, id: String, kind: String)] = []
    private var unread = ["inbox": 0, "archive": 0]
    private var mailboxState = 0
    private var mailboxLog: [(state: Int, id: String)] = []
    private var cannotCalculate = false
    private var methodLog: [[String]] = []
    private var emailGets: [[String]] = []
    private var mailboxGets: [[String]] = []

    init(host: String) {
        self.host = host
        JMAPStub.register(self)
    }

    func stop() { JMAPStub.remove(host) }

    /// Method names of each API request, in order.
    var requests: [[String]] { lock.withLock { methodLog } }
    /// Ids of each Email/get that asked for list properties.
    var fetchedEmails: [[String]] { lock.withLock { emailGets } }
    var fetchedMailboxes: [[String]] { lock.withLock { mailboxGets } }
    var cannotCalculateChanges: Bool {
        get { lock.withLock { cannotCalculate } }
        set { lock.withLock { cannotCalculate = newValue } }
    }

    func addEmail(_ id: String, subject: String) {
        lock.withLock {
            emailState += 1
            emails.append(Email(id: id, subject: subject, received: emails.count + 1))
            emailLog.append((emailState, id, "created"))
        }
    }

    func markSeen(_ id: String) {
        lock.withLock {
            guard let index = emails.firstIndex(where: { $0.id == id }) else { return }
            emailState += 1
            emails[index].seen = true
            emailLog.append((emailState, id, "updated"))
        }
    }

    func remove(_ id: String) {
        lock.withLock {
            emailState += 1
            emails.removeAll { $0.id == id }
            emailLog.append((emailState, id, "destroyed"))
        }
    }

    func setUnread(_ mailbox: String, _ count: Int) {
        lock.withLock {
            mailboxState += 1
            unread[mailbox] = count
            mailboxLog.append((mailboxState, mailbox))
        }
    }

    func handle(path: String, body: Data) -> Data {
        lock.withLock {
            if path.hasSuffix("/session") {
                return json(["apiUrl": "https://\(host)/api", "primaryAccounts": ["urn:ietf:params:jmap:mail": "a1"]])
            }
            let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let calls = request["methodCalls"] as? [[Any]] ?? []
            methodLog.append(calls.compactMap { $0.first as? String })
            var results: [String: [String: Any]] = [:]
            var responses: [[Any]] = []
            var failed = false
            for call in calls {
                let name = call[0] as! String, callID = call[2] as! String
                var arguments = call[1] as? [String: Any] ?? [:]
                if let reference = arguments["#ids"] as? [String: String] {
                    arguments["ids"] = Self.resolve(results[reference["resultOf"]!] as Any, path: reference["path"]!)
                }
                if failed {
                    responses.append(["error", ["type": "invalidResultReference"], callID])
                    continue
                }
                guard let result = answer(name, arguments) else {
                    failed = true
                    responses.append(["error", ["type": "cannotCalculateChanges", "description": "State too old."], callID])
                    continue
                }
                results[callID] = result
                responses.append([name, result, callID])
            }
            return json(["methodResponses": responses, "sessionState": "s"])
        }
    }

    private func answer(_ name: String, _ arguments: [String: Any]) -> [String: Any]? {
        let ids = arguments["ids"] as? [String]
        switch name {
        case "Mailbox/get":
            let all = [("inbox", "Inbox", "inbox"), ("archive", "Archive", "archive")]
            let chosen = all.filter { ids?.contains($0.0) ?? true }
            mailboxGets.append(chosen.map(\.0))
            return ["state": "m\(mailboxState)", "list": chosen.map { ["id": $0.0, "name": $0.1, "role": $0.2, "unreadEmails": unread[$0.0] ?? 0] }]
        case "Mailbox/changes":
            if cannotCalculate { return nil }
            let since = Int((arguments["sinceState"] as? String ?? "m0").dropFirst()) ?? 0
            let updated = Array(Set(mailboxLog.filter { $0.state > since }.map(\.id))).sorted()
            return ["oldState": "m\(since)", "newState": "m\(mailboxState)", "hasMoreChanges": false,
                    "created": [String](), "updated": updated, "destroyed": [String]()]
        case "Email/query":
            let sorted = emails.sorted { $0.received > $1.received }.map(\.id)
            let position = arguments["position"] as? Int ?? 0
            return ["ids": Array(sorted.dropFirst(position).prefix(arguments["limit"] as? Int ?? 50)), "total": sorted.count]
        case "Email/get":
            let chosen = emails.filter { ids?.contains($0.id) ?? true }
            let properties = arguments["properties"] as? [String] ?? []
            if properties.contains("subject") { emailGets.append(chosen.map(\.id)) }
            let missing = (ids ?? []).filter { id in !emails.contains { $0.id == id } }
            return ["state": "e\(emailState)", "notFound": missing, "list": chosen.map { email -> [String: Any] in
                [
                    "id": email.id, "threadId": "t-\(email.id)", "mailboxIds": ["inbox": true],
                    "keywords": email.seen ? ["$seen": true] : [String: Bool](),
                    "from": [["name": "Sender", "email": "sender@example.com"]], "subject": email.subject,
                    "receivedAt": String(format: "2026-11-03T%02d:00:00Z", email.received),
                ]
            }]
        case "Thread/get":
            return ["state": "e\(emailState)", "list": (ids ?? []).map { ["id": $0, "emailIds": [String($0.dropFirst(2))]] }]
        case "Email/changes":
            if cannotCalculate { return nil }
            let since = Int((arguments["sinceState"] as? String ?? "e0").dropFirst()) ?? 0
            let recent = emailLog.filter { $0.state > since }
            let created = recent.filter { $0.kind == "created" }.map(\.id)
            let destroyed = recent.filter { $0.kind == "destroyed" }.map(\.id)
            let updated = Array(Set(recent.filter { $0.kind == "updated" }.map(\.id)).subtracting(created).subtracting(destroyed)).sorted()
            return ["oldState": "e\(since)", "newState": "e\(emailState)", "hasMoreChanges": false,
                    "created": created, "updated": updated, "destroyed": destroyed]
        default:
            return [:]
        }
    }

    /// Evaluates a result reference path such as `/list/*/threadId`.
    static func resolve(_ value: Any, path: String) -> [String] {
        func walk(_ value: Any, _ parts: ArraySlice<Substring>) -> [Any] {
            guard let part = parts.first else { return [value] }
            if part == "*" { return (value as? [Any] ?? []).flatMap { walk($0, parts.dropFirst()) } }
            guard let next = (value as? [String: Any])?[String(part)] else { return [] }
            return walk(next, parts.dropFirst())
        }
        return walk(value, path.split(separator: "/")[...]).flatMap { ($0 as? [String]) ?? [$0 as? String].compactMap { $0 } }
    }

    private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
}
