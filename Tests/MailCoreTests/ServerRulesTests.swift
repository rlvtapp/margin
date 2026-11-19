import Foundation
import Testing
@testable import MailCore

@Suite struct ServerRulesTests {
    let invoices = ServerRule(name: "Invoices", from: "billing@", subject: "Invoice", hasAttachment: true, moveTo: "Finance", markRead: true)

    // MARK: Sieve

    @Test func sieveScriptForARule() {
        let script = SieveScript(parts: [.rule(invoices)])
        let text = script.text(options: .init(extensions: ["fileinto", "imap4flags", "mime", "copy"]))
        #expect(text == """
        require ["fileinto", "imap4flags", "mime"];
        # rule:[Invoices]
        if allof (address :contains "from" "billing@", header :contains "subject" "Invoice", header :mime :anychild :contains "Content-Disposition" "attachment")
        {
        \taddflag "\\\\Seen";
        \tfileinto "Finance";
        }

        """)
    }

    @Test func sieveWithoutExtensionsStaysPortable() {
        var rule = ServerRule(to: "team@", hasAttachment: true, flag: true, forwardTo: "me@example.com")
        rule.name = "Team"
        let text = SieveScript(parts: [.rule(rule)]).text(options: .init(extensions: ["fileinto", "imap4flags"]))
        #expect(text.contains(#"address :contains ["to", "cc"] "team@""#))
        #expect(text.contains(#"header :contains "Content-Type" "multipart/mixed""#))
        // Without :copy, redirecting needs an explicit keep so the email still arrives.
        #expect(text.contains("redirect \"me@example.com\";\n\tkeep;"))
        #expect(text.contains(#"addflag "\\Flagged";"#))
    }

    @Test func sieveDeleteFilesIntoTrashAndEscapes() {
        let rule = ServerRule(name: "Odd", subject: #"say "hi" \ now"#, delete: true)
        let text = SieveScript(parts: [.rule(rule)]).text(options: .init(extensions: ["fileinto"], trashFolder: "INBOX.Trash"))
        #expect(text.contains(#"header :contains "subject" "say \"hi\" \\ now""#))
        #expect(text.contains(#"fileinto "INBOX.Trash";"#))
        #expect(!text.contains("discard"))
        // And it reads back the same.
        let back = SieveScript(parsing: text, trashFolder: "INBOX.Trash").rules
        #expect(back.count == 1)
        #expect(back.first?.subject == #"say "hi" \ now"#)
        #expect(back.first?.delete == true)
    }

    @Test func sieveRoundTrip() {
        var off = ServerRule(name: "Paused", from: "x@y.z", forwardTo: "a@b.c")
        off.isEnabled = false
        let options = SieveScript.Options(extensions: ["fileinto", "imap4flags", "copy", "mime"])
        let text = SieveScript(parts: [.rule(invoices), .rule(off)]).text(options: options)
        let parsed = SieveScript(parsing: text)
        #expect(parsed.parts.count == 2)
        var expected = invoices
        expected.id = "sieve-0"
        #expect(parsed.rules.first == expected)
        #expect(parsed.rules.last?.isEnabled == false)
        #expect(parsed.rules.last?.forwardTo == "a@b.c")
        #expect(parsed.text(options: options) == text)
    }

    @Test func sieveKeepsWhatItDoesntKnow() {
        let source = """
        require ["fileinto", "vacation", "imap4flags"];
        # rule:[Spam]
        if header :contains "X-Spam-Flag" "YES"
        {
        \tfileinto "Junk";
        \tstop;
        }
        # rule:[Boss]
        if address :is "from" "boss@example.com" { addflag "\\\\Flagged"; }
        # rule:[News]
        if header :contains "subject" "Weekly"
        {
        \taddflag "\\\\Seen";
        }
        vacation :days 7 "Away";
        """
        var script = SieveScript(parsing: source)
        #expect(script.rules.map(\.name) == ["News"])
        #expect(script.requires == ["fileinto", "vacation", "imap4flags"])
        script.put(ServerRule(name: "New", from: "a@", flag: true))
        let text = script.text(options: .init(extensions: ["fileinto", "imap4flags"]))
        #expect(text.hasPrefix(#"require ["fileinto", "imap4flags", "vacation"];"#))
        #expect(text.contains(#"if header :contains "X-Spam-Flag" "YES""#))
        #expect(text.contains(#"if address :is "from" "boss@example.com""#))
        #expect(text.contains(#"vacation :days 7 "Away";"#))
        #expect(text.contains("# rule:[New]"))
        script.remove(id: script.rules.first { $0.name == "News" }!.id)
        #expect(!script.text(options: .init(extensions: [])).contains("Weekly"))
    }

    @Test func sieveLeavesOtherRulesWordForWord() {
        let foreign = """
        # rule:[Lists]
        if header :contains "from" "list@"
        {
        \tredirect "me@example.com";
        \tstop;
        }
        """
        var script = SieveScript(parsing: "require [\"fileinto\"];\n" + foreign + "\n")
        let lists = script.rules[0]
        #expect(lists.forwardTo == "me@example.com")
        // It stops later rules and forwards without a copy: Margin would write it differently.
        #expect(!lists.isEditable)
        script.put(ServerRule(name: "New", subject: "x", moveTo: "Done"))
        let text = script.text(options: .init(extensions: ["fileinto", "copy"]))
        #expect(text.contains("\n" + foreign + "\n"))
        #expect(text.hasPrefix(#"require ["fileinto"];"#))
    }

    @Test func sieveIfWithElseStaysWhole() {
        let source = """
        if header :contains "subject" "a" { fileinto "A"; }
        else { fileinto "B"; }
        if header :contains "subject" "c" { fileinto "C"; }
        """
        let script = SieveScript(parsing: source)
        #expect(script.parts.count == 2)
        #expect(script.rules.map(\.moveTo) == ["C"])
    }

    @Test func manageSieveSavesIntoTheRunningScript() async throws {
        let server = FakeSieveServer(script: """
        require ["fileinto"];
        # rule:[Old]
        if header :contains "subject" "old" { fileinto "Archive"; }
        """)
        let rules = ManageSieveRules(mailboxes: [], trashFolder: "Trash") {
            await server.reconnect()
            let client = ManageSieveClient(transport: server)
            try await client.open(alreadySecure: false, username: "alex", password: "pw")
            return client
        }
        let listed = try await rules.rules()
        #expect(listed.map(\.moveTo) == ["Archive"])
        try await rules.save(ServerRule(name: "Receipts", subject: "receipt", markRead: true))
        let sent = await server.sent
        #expect(sent.contains("STARTTLS\r\n"))
        #expect(sent.contains("AUTHENTICATE \"PLAIN\" \"\(Data("\u{0}alex\u{0}pw".utf8).base64EncodedString())\"\r\n"))
        let put = try #require(sent.first { $0.hasPrefix("PUTSCRIPT \"webmail\"") })
        #expect(put.contains("# rule:[Old]"))
        #expect(put.contains("# rule:[Receipts]"))
        #expect(put.contains(#"require ["fileinto", "imap4flags"];"#))
        // Already running: no SETACTIVE needed.
        #expect(!sent.contains { $0.hasPrefix("SETACTIVE") })
        #expect(await server.tlsStarted)
    }

    @Test func manageSieveStartsItsOwnScriptWhenNoneRuns() async throws {
        let server = FakeSieveServer(script: nil)
        let rules = ManageSieveRules(mailboxes: [], trashFolder: "Trash") {
            let client = ManageSieveClient(transport: server)
            try await client.open(alreadySecure: true, username: "alex", password: "pw")
            return client
        }
        try await rules.save(ServerRule(from: "a@", flag: true))
        let sent = await server.sent
        #expect(sent.contains { $0.hasPrefix("PUTSCRIPT \"margin\"") })
        #expect(sent.contains("SETACTIVE \"margin\"\r\n"))
        #expect(!sent.contains("STARTTLS\r\n"))
    }

    @Test func sieveNamesFoldersInUTF8() async throws {
        let rules = ManageSieveRules(endpoint: ServerEndpoint(host: "mail.example.com", port: 4190, security: .startTLS),
                                     username: "a", password: "b",
                                     mailboxes: [ServerFolder(id: "INBOX.&AOk-t&AOk-", name: "été")], trashFolder: "Corbeille")
        #expect(try await rules.folders() == [ServerFolder(id: "INBOX.été", name: "été")])
    }

    @Test func archivingOnEachServer() async throws {
        let rule = ServerRule(from: "news@", archive: true)
        // Sieve: into the archive folder, and read back as archiving.
        let options = SieveScript.Options(extensions: ["fileinto"], archiveFolder: "Archive")
        let text = SieveScript(parts: [.rule(rule)]).text(options: options)
        #expect(text.contains(#"fileinto "Archive";"#))
        #expect(SieveScript(parsing: text, archiveFolder: "Archive").rules.first?.archive == true)
        // Gmail: out of the inbox, no label.
        let action = GmailServerRules.body(for: rule)["action"] as? [String: Any]
        #expect(action?["removeLabelIds"] as? [String] == ["INBOX"] && action?["addLabelIds"] == nil)
        #expect(GmailServerRules.rule(from: ["id": "1", "criteria": ["from": "news@"], "action": ["removeLabelIds": ["INBOX"]]]).archive)
        // Microsoft: the Archive folder, found by its well-known name.
        let api = GraphFakeAPI()
        api.on("mailFolders/archive", #"{"id": "AAMkArchive"}"#)
        api.on("messageRules", #"{"value": [], "id": "r1"}"#)
        try await MicrosoftServerRules(accessToken: "t", send: api.send).save(rule)
        let body = try #require(api.requests.last?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["actions"] as? [String: Any])?["moveToFolder"] as? String == "AAMkArchive")
    }

    // MARK: Microsoft

    @Test func graphRuleBody() async throws {
        let api = GraphFakeAPI()
        api.on("messageRules", #"{"value": [], "id": "r1", "displayName": "Invoices"}"#)
        var rule = invoices
        rule.flag = true
        rule.forwardTo = "me@example.com"
        try await MicrosoftServerRules(accessToken: "t", send: api.send).save(rule)
        let post = try #require(api.requests.last)
        #expect(post.httpMethod == "POST")
        let body = try #require(post.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let conditions = try #require(body["conditions"] as? [String: Any])
        let actions = try #require(body["actions"] as? [String: Any])
        #expect(body["displayName"] as? String == "Invoices")
        #expect(body["sequence"] as? Int == 1)
        #expect(conditions["senderContains"] as? [String] == ["billing@"])
        #expect(conditions["subjectContains"] as? [String] == ["Invoice"])
        #expect(conditions["hasAttachments"] as? Bool == true)
        #expect(actions["moveToFolder"] as? String == "Finance")
        #expect(actions["markAsRead"] as? Bool == true)
        #expect(actions["markImportance"] as? String == "high")
        #expect((actions["forwardTo"] as? [[String: Any]])?.first?["emailAddress"] as? [String: String] == ["address": "me@example.com"])
        #expect(actions["permanentDelete"] == nil)
    }

    @Test func graphChangeTakesTheOldPlaceAndDeleteGoesToDeletedItems() async throws {
        let api = GraphFakeAPI()
        api.on("messageRules/r1", #"{}"#)
        api.on("messageRules", #"{"value": [{"id": "r0", "sequence": 1}, {"id": "r1", "sequence": 4}], "id": "r2"}"#)
        let adapter = MicrosoftServerRules(accessToken: "t", send: api.send)
        let saved = try await adapter.save(ServerRule(id: "r1", subject: "x", delete: true))
        // A new rule in its place, then the old one removed, so nothing cleared lingers.
        #expect(api.requests.map(\.httpMethod) == ["GET", "POST", "DELETE"])
        let body = try #require(api.requests[1].httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["sequence"] as? Int == 4)
        #expect((body["actions"] as? [String: Any])?["delete"] as? Bool == true)
        #expect((body["actions"] as? [String: Any])?["permanentDelete"] == nil)
        #expect(api.requests[2].url?.absoluteString.hasSuffix("messageRules/r1") == true)
        #expect(saved.id == "r2")
    }

    @Test func graphReadsRulesAndMarksForeignOnesReadOnly() async throws {
        let api = GraphFakeAPI()
        api.on("messageRules", #"""
        {"value": [
          {"id": "b", "displayName": "Big", "sequence": 2, "isEnabled": true,
           "conditions": {"bodyContains": ["x"]}, "actions": {"delete": true}},
          {"id": "a", "displayName": "News", "sequence": 1, "isEnabled": false,
           "conditions": {"senderContains": ["news@"]}, "actions": {"markAsRead": true, "moveToFolder": "f1"}}
        ]}
        """#)
        let rules = try await MicrosoftServerRules(accessToken: "t", send: api.send).rules()
        #expect(rules.map(\.id) == ["a", "b"])
        #expect(rules[0].isEditable && !rules[0].isEnabled && rules[0].moveTo == "f1" && rules[0].markRead)
        #expect(!rules[1].isEditable)
    }

    // MARK: Gmail

    @Test func gmailFilterBody() {
        var rule = invoices
        rule.moveTo = "Label_7"
        rule.flag = true
        rule.forwardTo = "me@example.com"
        let body = GmailServerRules.body(for: rule)
        let criteria = body["criteria"] as? [String: Any]
        let action = body["action"] as? [String: Any]
        #expect(criteria?["from"] as? String == "billing@")
        #expect(criteria?["subject"] as? String == "Invoice")
        #expect(criteria?["hasAttachment"] as? Bool == true)
        #expect(action?["addLabelIds"] as? [String] == ["Label_7", "STARRED"])
        #expect(action?["removeLabelIds"] as? [String] == ["INBOX", "UNREAD"])
        #expect(action?["forward"] as? String == "me@example.com")
        let trash = GmailServerRules.body(for: ServerRule(to: "x", delete: true))["action"] as? [String: Any]
        #expect(trash?["addLabelIds"] as? [String] == ["TRASH"])
    }

    @Test func gmailChangeIsNewThenDelete() async throws {
        let api = GraphFakeAPI()
        api.on("settings/filters/old", #"{}"#)
        api.on("settings/filters", #"{"id": "new", "criteria": {"from": "a@"}, "action": {"addLabelIds": ["STARRED"]}}"#)
        let saved = try await GmailServerRules(accessToken: "t", labelsToken: "m", send: api.send)
            .save(ServerRule(id: "old", from: "a@", flag: true))
        #expect(api.requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(saved.id == "new" && saved.flag && saved.isEditable)
    }

    @Test func gmailReadsFiltersAndLabels() async throws {
        let api = GraphFakeAPI()
        api.on("settings/filters", #"""
        {"filter": [
          {"id": "1", "criteria": {"from": "news@"}, "action": {"addLabelIds": ["Label_1"], "removeLabelIds": ["INBOX", "UNREAD"]}},
          {"id": "2", "criteria": {"query": "larger:10M"}, "action": {"addLabelIds": ["TRASH"]}},
          {"id": "3", "criteria": {"from": "x@"}, "action": {"addLabelIds": ["Label_1"]}}
        ]}
        """#)
        api.on("users/me/labels", #"{"labels": [{"id": "INBOX", "name": "INBOX", "type": "system"}, {"id": "Label_1", "name": "Work/News", "type": "user"}]}"#)
        let adapter = GmailServerRules(accessToken: "t", labelsToken: "m", send: api.send)
        let rules = try await adapter.rules()
        #expect(rules[0].moveTo == "Label_1" && rules[0].markRead && rules[0].isEditable)
        #expect(!rules[1].isEditable)
        #expect(!rules[2].isEditable)
        #expect(try await adapter.folders() == [ServerFolder(id: "Label_1", name: "Work / News")])
        #expect(api.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer m")
    }

    @Test func rulesAccessScopes() {
        #expect(APIAccess.rules.scopes(for: .microsoft) == ["https://graph.microsoft.com/MailboxSettings.ReadWrite", "https://graph.microsoft.com/Mail.ReadBasic"])
        #expect(APIAccess.rules.scopes(for: .google) == ["https://www.googleapis.com/auth/gmail.settings.basic"])
    }
}

/// A ManageSieve server that answers each command from what it keeps.
actor FakeSieveServer: SieveTransport {
    private var output: [UInt8] = []
    private(set) var sent: [String] = []
    private(set) var tlsStarted = false
    private var active: String?
    private var scripts: [String: String] = [:]

    init(script: String?) {
        if let script {
            scripts["webmail"] = script
            active = "webmail"
        }
        output = Array(Self.capabilities(tls: false).utf8)
    }

    static func capabilities(tls: Bool) -> String {
        "\"IMPLEMENTATION\" \"Fake\"\r\n\"SASL\" \"PLAIN\"\r\n\"SIEVE\" \"fileinto imap4flags\"\r\n"
            + (tls ? "" : "\"STARTTLS\"\r\n") + "OK \"ready\"\r\n"
    }

    func write(_ text: String) async throws {
        sent.append(text)
        let line = text.components(separatedBy: "\r\n")[0]
        let words = ManageSieveClient.strings(in: line)
        var reply = "OK\r\n"
        if line == "STARTTLS" {
            reply = "OK \"go\"\r\n"
        } else if line.hasPrefix("LISTSCRIPTS") {
            reply = scripts.keys.sorted().map { "\"\($0)\"" + ($0 == active ? " ACTIVE" : "") + "\r\n" }.joined() + "OK\r\n"
        } else if line.hasPrefix("GETSCRIPT"), let script = scripts[words[0]] {
            reply = "{\(script.utf8.count)}\r\n\(script)\r\nOK\r\n"
        } else if line.hasPrefix("PUTSCRIPT") {
            let body = text.components(separatedBy: "+}\r\n").dropFirst().joined(separator: "+}\r\n")
            scripts[words[0]] = String(body.dropLast(2))
        } else if line.hasPrefix("SETACTIVE") {
            active = words[0]
        }
        output += Array(reply.utf8)
    }

    /// A new connection: the greeting again.
    func reconnect() {
        output = Array(Self.capabilities(tls: false).utf8)
    }

    func startTLS() async {
        tlsStarted = true
        output = Array(Self.capabilities(tls: true).utf8)
    }

    func readLine(limit: Int) async throws -> [UInt8] {
        guard let newline = output.firstIndex(of: 0x0A) else { throw MailError.connectionClosed }
        let line = Array(output[...newline])
        output.removeFirst(newline + 1)
        return line
    }

    func readExactly(_ count: Int) async throws -> [UInt8] {
        let bytes = Array(output.prefix(count))
        output.removeFirst(min(count, output.count))
        return bytes
    }

    func close() async {}
}
