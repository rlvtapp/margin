import Foundation
import Testing
@testable import MailCore

/// Labels over IMAP: reading `X-GM-LABELS`, building `STORE` and `SEARCH` commands, and what
/// archiving, moving and labelling send to a server that keeps labels.
@Suite struct IMAPLabelsTests {
    // MARK: Reading

    func fetchItem(_ line: String) throws -> IMAPFetchItem? {
        guard case .untagged(let values) = try IMAPParser.parse(Array(line.utf8)) else { return nil }
        return IMAPFetchItem(values)
    }

    @Test func readsLabelsAndIDsFromAFetch() throws {
        let item = try #require(try fetchItem(
            #"* 3 FETCH (UID 7 X-GM-THRID 17000000000000000001 X-GM-MSGID 1278455344230334866 X-GM-LABELS (\Inbox "\\Important" "Projects/2026" "&AOk-t&AOk-") FLAGS (\Seen))"#
        ))
        #expect(item.uid == 7)
        // Bigger than Int: kept as text.
        #expect(item.threadID == "17000000000000000001")
        #expect(item.serverID == "1278455344230334866")
        #expect(item.labels == ["\\Inbox", "\\Important", "Projects/2026", "été"])
        #expect(item.flags == [.seen])
    }

    @Test func noLabelsInTheResponseIsNilNotEmpty() throws {
        let plain = try #require(try fetchItem("* 1 FETCH (UID 2 FLAGS ())"))
        #expect(plain.labels == nil)
        let empty = try #require(try fetchItem("* 1 FETCH (UID 2 X-GM-LABELS ())"))
        #expect(empty.labels == [])
    }

    @Test func systemLabelsKeepOneSpelling() {
        #expect(IMAPLabels.parse(.list([.atom("\\INBOX"), .quoted("\\important"), .atom("Work")])) == ["\\Inbox", "\\Important", "Work"])
    }

    @Test func theFolderOnScreenAddsItsOwnLabel() {
        #expect(IMAPLabels.adding("\\Inbox", to: ["Projects"]) == ["\\Inbox", "Projects"])
        #expect(IMAPLabels.adding("projects", to: ["Projects"]) == ["Projects"])
        #expect(IMAPLabels.adding(nil, to: ["Projects"]) == ["Projects"])
        #expect(IMAPLabels.adding("\\Inbox", to: nil) == nil)
    }

    @Test func userLabelsLeaveOutSystemOnesAndRepeats() {
        #expect(IMAPLabels.userLabels(["\\Inbox", "Work", "\\Important", "work", "Travel"]) == ["Work", "Travel"])
    }

    @Test func eachListedFolderStandsForALabel() {
        func item(_ attributes: [String], _ name: String) -> IMAPListItem {
            IMAPListItem([.atom("LIST"), .list(attributes.map { .atom($0) }), .quoted("/"), .quoted(name)])!
        }
        #expect(IMAPLabels.label(for: item([], "INBOX")) == "\\Inbox")
        #expect(IMAPLabels.label(for: item(["\\Sent"], "[Gmail]/Sent Mail")) == "\\Sent")
        #expect(IMAPLabels.label(for: item(["\\Drafts"], "[Gmail]/Drafts")) == "\\Draft")
        #expect(IMAPLabels.label(for: item(["\\Flagged"], "[Gmail]/Starred")) == "\\Starred")
        #expect(IMAPLabels.label(for: item(["\\Important"], "[Gmail]/Important")) == "\\Important")
        #expect(IMAPLabels.label(for: item(["\\All"], "[Gmail]/All Mail")) == nil)
        #expect(IMAPLabels.label(for: item(["\\Trash"], "[Gmail]/Trash")) == nil)
        #expect(IMAPLabels.label(for: item(["\\Junk"], "[Gmail]/Spam")) == nil)
        #expect(IMAPLabels.label(for: item(["\\HasNoChildren"], "Projects/2026")) == "Projects/2026")
        #expect(IMAPLabels.label(for: item([], "R&AOk-sum&AOk-")) == "Résumé")
        // Names never make a system label: these are the person's own.
        #expect(IMAPLabels.label(for: item([], "Work/Sent")) == "Work/Sent")
        #expect(IMAPLabels.label(for: item([], "Archive")) == "Archive")
        #expect(IMAPLabels.label(for: item([], "Trash")) == "Trash")
    }

    @Test func readsLabelColoursFromTheLabelList() {
        let json = #"""
        {"labels": [
          {"id": "INBOX", "name": "INBOX", "type": "system"},
          {"id": "Label_1", "name": "Projects", "type": "user", "color": {"backgroundColor": "#4A86E8", "textColor": "#ffffff"}},
          {"id": "Label_2", "name": "Plain", "type": "user"},
          {"id": "Label_3", "name": "Odd", "type": "user", "color": {"backgroundColor": "blue"}}
        ]}
        """#
        #expect(IMAPLabels.colors(fromLabelList: Data(json.utf8)) == ["Projects": "#4a86e8"])
        #expect(IMAPLabels.colors(fromLabelList: Data("nope".utf8)) == [:])
    }

    // MARK: Commands

    @Test func storeNamesSystemLabelsBareAndOwnLabelsQuoted() {
        #expect(IMAPLabels.store(["\\Inbox"], adding: false) == #"-X-GM-LABELS.SILENT (\Inbox)"#)
        #expect(IMAPLabels.store(["Projects/2026", "\\Important"], adding: true) == #"+X-GM-LABELS.SILENT ("Projects/2026" \Important)"#)
        #expect(IMAPLabels.store(["Say \"hi\""], adding: true) == #"+X-GM-LABELS.SILENT ("Say \"hi\"")"#)
        #expect(IMAPLabels.store(["Résumé"], adding: true) == #"+X-GM-LABELS.SILENT ("R&AOk-sum&AOk-")"#)
        #expect(IMAPLabels.store([], adding: true) == nil)
        // A line break is encoded like any other character outside printable ASCII: one line.
        #expect(IMAPLabels.store(["Two\nlines"], adding: true)?.contains("\n") == false)
        // A system label a command can't carry spoils the whole change rather than half of it.
        #expect(IMAPLabels.store(["Fine", "\\In box"], adding: true) == nil)
    }

    @Test func searchFindsMessagesByServerID() {
        #expect(IMAPLabels.search(serverIDs: ["5"]) == "X-GM-MSGID 5")
        #expect(IMAPLabels.search(serverIDs: ["3", "1", "2", "1"]) == "OR X-GM-MSGID 1 OR X-GM-MSGID 2 X-GM-MSGID 3")
        #expect(IMAPLabels.search(serverIDs: []) == nil)
        #expect(IMAPLabels.search(serverIDs: ["12 OR ALL"]) == nil)
    }

    @Test func modifiedUTF7GoesBothWays() {
        for name in ["Inbox", "R&D", "Résumé", "日本語/メモ", "Mixed & 🎉 done", "~a-b_c"] {
            #expect(ModifiedUTF7.decode(ModifiedUTF7.encode(name)) == name)
        }
        #expect(ModifiedUTF7.encode("R&D") == "R&-D")
        #expect(ModifiedUTF7.encode("été") == "&AOk-t&AOk-")
    }

    // MARK: Conversations

    @Test func serverConversationIDsJoinAndRepeatsAreDropped() {
        func message(_ id: String, subject: String, thread: String?, server: String?, minutes: Double) -> MailMessage {
            var message = MailMessage(id: id, mailboxID: id.components(separatedBy: "/")[0], messageID: "<\(id)@example.com>",
                                      from: EmailAddress(address: "a@example.com"), subject: subject,
                                      date: Date(timeIntervalSince1970: minutes * 60))
            message.threadID = thread
            message.serverID = server
            return message
        }
        let threads = Threader.threads(from: [
            message("INBOX/1", subject: "Plans", thread: "t1", server: "m1", minutes: 1),
            // No reply headers, another subject: only the server's id joins it.
            message("INBOX/2", subject: "Something else", thread: "t1", server: "m2", minutes: 2),
            // The same message again, from All Mail.
            message("All/9", subject: "Plans", thread: "t1", server: "m1", minutes: 1),
            message("INBOX/3", subject: "Unrelated", thread: "t2", server: "m3", minutes: 3),
        ])
        #expect(threads.count == 2)
        let joined = threads.first { $0.messages.count > 1 }
        #expect(joined?.messages.map(\.id) == ["INBOX/1", "INBOX/2"])
    }
}

/// What a server that keeps labels is sent for archiving, moving and labelling.
@Suite(.serialized) struct IMAPLabelActionTests {
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

    func inboxThread() -> MailThread {
        var message = MailMessage(id: "INBOX/7", mailboxID: "INBOX", from: EmailAddress(address: "sender@example.com"),
                                  subject: "Plans", date: Date())
        message.serverID = "900"
        message.labels = ["\\Inbox", "Projects"]
        return MailThread(id: message.id, messages: [message])
    }

    @Test func listsFoldersAsLabelsAndReadsLabelsWithMessages() async throws {
        let server = LabelServer()
        let fake = try await FakeServer(greeting: "* OK ready", respond: { server.respond($0) })
        defer { fake.stop() }
        let provider = try provider(fake)
        let folders = try await provider.mailboxes()
        #expect(folders.first { $0.id == "INBOX" }?.label == "\\Inbox")
        #expect(folders.first { $0.id == "Projects/2026" }?.label == "Projects/2026")
        #expect(folders.first { $0.id == "Projects/2026" }?.parentID == "Projects")
        #expect(folders.first { $0.role == .all }?.label == nil)

        let threads = try await provider.threads(in: folders.first { $0.role == .inbox }!, limit: 10)
        let message = try #require(threads.first?.messages.first)
        // The inbox's own label isn't in the response; it's put back.
        #expect(message.labels == ["\\Inbox", "\\Important", "Projects"])
        #expect(message.serverID == "900")
        #expect(message.threadID == "17000000000000000001")
        #expect(server.commands.contains { $0.contains("FETCH") && $0.contains("X-GM-LABELS X-GM-THRID X-GM-MSGID") })
        await provider.disconnect()
    }

    @Test func archivingTakesTheInboxLabelOffInAllMail() async throws {
        let server = LabelServer()
        let fake = try await FakeServer(greeting: "* OK ready", respond: { server.respond($0) })
        defer { fake.stop() }
        let provider = try provider(fake)
        try await provider.perform(.done, on: [inboxThread()])
        let commands = server.commands
        #expect(commands.contains(#"SELECT "[Gmail]/All Mail""#))
        #expect(commands.contains("UID SEARCH X-GM-MSGID 900"))
        #expect(commands.contains(#"UID STORE 42 -X-GM-LABELS.SILENT (\Inbox)"#))
        #expect(!commands.contains { $0.hasPrefix("UID MOVE") })
        await provider.disconnect()
    }

    @Test func movingSwapsLabels() async throws {
        let server = LabelServer()
        let fake = try await FakeServer(greeting: "* OK ready", respond: { server.respond($0) })
        defer { fake.stop() }
        let provider = try provider(fake)
        try await provider.perform(.move(toMailboxID: "Projects/2026"), on: [inboxThread()])
        let stores = server.commands.filter { $0.hasPrefix("UID STORE") }
        #expect(stores == [#"UID STORE 42 +X-GM-LABELS.SILENT ("Projects/2026")"#, #"UID STORE 42 -X-GM-LABELS.SILENT (\Inbox)"#])
        await provider.disconnect()
    }

    @Test func addingAndRemovingALabel() async throws {
        let server = LabelServer()
        let fake = try await FakeServer(greeting: "* OK ready", respond: { server.respond($0) })
        defer { fake.stop() }
        let provider = try provider(fake)
        try await provider.changeLabel("Travel", adding: true, on: [inboxThread()])
        try await provider.changeLabel("Projects", adding: false, on: [inboxThread()])
        let stores = server.commands.filter { $0.hasPrefix("UID STORE") }
        #expect(stores == [#"UID STORE 42 +X-GM-LABELS.SILENT ("Travel")"#, #"UID STORE 42 -X-GM-LABELS.SILENT ("Projects")"#])
        await provider.disconnect()
    }

    @Test func movingOutOfSentKeepsTheSentLabel() async throws {
        let server = LabelServer()
        let fake = try await FakeServer(greeting: "* OK ready", respond: { server.respond($0) })
        defer { fake.stop() }
        let provider = try provider(fake)
        var thread = inboxThread()
        thread.messages[0].id = "[Gmail]/Sent Mail/7"
        thread.messages[0].mailboxID = "[Gmail]/Sent Mail"
        try await provider.perform(.move(toMailboxID: "Projects/2026"), on: [thread])
        let stores = server.commands.filter { $0.hasPrefix("UID STORE") }
        #expect(stores == [#"UID STORE 42 +X-GM-LABELS.SILENT ("Projects/2026")"#])
        await provider.disconnect()
    }

    @Test func withoutAServerIDDoneIsTheUsualMove() async throws {
        let server = LabelServer()
        let fake = try await FakeServer(greeting: "* OK ready", respond: { server.respond($0) })
        defer { fake.stop() }
        let provider = try provider(fake)
        var thread = inboxThread()
        thread.messages[0].serverID = nil
        try await provider.perform(.done, on: [thread])
        #expect(server.commands.contains(#"UID MOVE 7 "[Gmail]/All Mail""#))
        #expect(!server.commands.contains { $0.contains("X-GM-LABELS") })
        await provider.disconnect()
    }

    @Test func trashIsStillAMove() async throws {
        let server = LabelServer()
        let fake = try await FakeServer(greeting: "* OK ready", respond: { server.respond($0) })
        defer { fake.stop() }
        let provider = try provider(fake)
        try await provider.perform(.trash, on: [inboxThread()])
        #expect(server.commands.contains(#"UID MOVE 7 "[Gmail]/Trash""#))
        #expect(!server.commands.contains { $0.contains("X-GM-LABELS") })
        await provider.disconnect()
    }

    @Test func aServerWithoutLabelsSaysSo() async throws {
        let server = LabelServer(capabilities: "IMAP4rev1 MOVE")
        let fake = try await FakeServer(greeting: "* OK ready", respond: { server.respond($0) })
        defer { fake.stop() }
        let provider = try provider(fake)
        await #expect(throws: MailError.self) { try await provider.changeLabel("Travel", adding: true, on: [inboxThread()]) }
        let folders = try await provider.mailboxes()
        #expect(folders.allSatisfy { $0.label == nil })
        await provider.disconnect()
    }
}

/// A scripted server that keeps labels: one message in the inbox, UID 7 there and 42 in All Mail.
final class LabelServer: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let capabilities: String

    init(capabilities: String = "IMAP4rev1 MOVE X-GM-EXT-1") { self.capabilities = capabilities }

    var commands: [String] { lock.withLock { log } }

    func respond(_ line: String) -> String {
        lock.withLock {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "" }
            let tag = parts[0], command = parts[1]
            log.append(command)
            let words = command.split(separator: " ").map { $0.uppercased() }
            switch words.first ?? "" {
            case "CAPABILITY": return "* CAPABILITY \(capabilities)\r\n\(tag) OK done\r\n"
            case "LOGIN": return "\(tag) OK logged in\r\n"
            case "LIST":
                return [
                    #"* LIST (\HasNoChildren) "/" "INBOX""#,
                    #"* LIST (\HasChildren \Noselect) "/" "[Gmail]""#,
                    #"* LIST (\All \HasNoChildren) "/" "[Gmail]/All Mail""#,
                    #"* LIST (\HasNoChildren \Trash) "/" "[Gmail]/Trash""#,
                    #"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#,
                    #"* LIST (\HasNoChildren \Important) "/" "[Gmail]/Important""#,
                    #"* LIST (\HasChildren) "/" "Projects""#,
                    #"* LIST (\HasNoChildren) "/" "Projects/2026""#,
                ].map { $0 + "\r\n" }.joined() + "\(tag) OK listed\r\n"
            case "SELECT": return "* 1 EXISTS\r\n* OK [UIDVALIDITY 3] ok\r\n* OK [UIDNEXT 8] ok\r\n\(tag) OK [READ-WRITE] selected\r\n"
            case "FETCH":
                return "* 1 FETCH (UID 7 X-GM-THRID 17000000000000000001 X-GM-MSGID 900 X-GM-LABELS (\\Important \"Projects\") FLAGS (\\Seen) ENVELOPE (\"Tue, 3 Nov 2026 10:00:00 +0100\" \"Plans\" ((\"Sender\" NIL \"sender\" \"example.com\")) NIL NIL ((NIL NIL \"me\" \"example.com\")) NIL NIL NIL \"<plans@example.com>\"))\r\n\(tag) OK fetched\r\n"
            case "UID":
                if words.count > 1, words[1] == "SEARCH" { return "* SEARCH 42\r\n\(tag) OK searched\r\n" }
                return "\(tag) OK done\r\n"
            case "LOGOUT": return "* BYE bye\r\n\(tag) OK bye\r\n"
            default: return "\(tag) OK fine\r\n"
            }
        }
    }
}
