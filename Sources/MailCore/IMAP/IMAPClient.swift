import Foundation

/// The result of one tagged command: everything the server said before the tag.
struct IMAPReply: Sendable {
    var untagged: [IMAPResponse]
    var text: String

    var values: [[IMAPValue]] {
        untagged.compactMap { if case .untagged(let values) = $0 { values } else { nil } }
    }
}

/// What SELECT reports about a mailbox (RFC 9051 §6.3.2, RFC 7162).
struct IMAPSelection: Sendable {
    var exists = 0
    var uidValidity: Int?
    var uidNext: Int?
    /// HIGHESTMODSEQ; nil when CONDSTORE is off or the mailbox keeps none (NOMODSEQ).
    var highestModSeq: Int?
    /// QRESYNC: UIDs expunged since the mod-sequence the client gave.
    var vanished: [ClosedRange<Int>] = []
    /// QRESYNC: messages changed since that mod-sequence, with UID and FLAGS.
    var changed: [IMAPFetchItem] = []
}

/// An IMAP4rev1 / IMAP4rev2 session over one connection. Commands run one at a time.
actor IMAPClient {
    private let connection: LineConnection
    private var nextTag = 1
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var capabilities: Set<String> = []
    private(set) var selected: String?

    /// `readTimeout` is how long a read may wait: long for a connection that sits in IDLE.
    init(endpoint: ServerEndpoint, readTimeout: TimeInterval = 30) throws {
        connection = try LineConnection(endpoint: endpoint, timeout: readTimeout)
    }

    var supportsIdle: Bool { capabilities.contains("IDLE") }
    /// CONDSTORE (RFC 7162): mod-sequences, so changed flags can be asked for alone.
    var supportsCondStore: Bool { capabilities.contains("CONDSTORE") || capabilities.contains("QRESYNC") }
    /// Whether `ENABLE QRESYNC` succeeded on this connection.
    private(set) var qresyncEnabled = false

    /// Turns on QRESYNC (RFC 7162 §3.2.3) when offered. ENABLE is only allowed before the
    /// first SELECT, so this runs right after signing in. Returns whether it's on.
    @discardableResult
    func enableQResync() async -> Bool {
        if qresyncEnabled { return true }
        guard capabilities.contains("QRESYNC"), selected == nil,
              let reply = try? await command("ENABLE QRESYNC") else { return false }
        qresyncEnabled = reply.values.contains { values in
            values.first?.string?.uppercased() == "ENABLED" && values.dropFirst().contains { $0.string?.uppercased() == "QRESYNC" }
        }
        return qresyncEnabled
    }

    /// Waits on the selected mailbox (RFC 2177) until the server reports a change or `timeout`
    /// passes, and returns whether something changed. The server tells us the moment mail
    /// arrives, so there's nothing to poll. Servers drop an IDLE after 30 minutes, so callers
    /// pass less and start again.
    func idle(timeout: Duration) async throws -> Bool {
        guard supportsIdle else { throw MailError.notSupported(String(localized: "This server can't push new mail.")) }
        return try await exclusive {
            let tag = self.takeTag()
            try await self.connection.write("\(tag) IDLE\r\n")
            switch try IMAPParser.parse(try await self.readResponse()) {
            case .continuation: break
            case .tagged(_, _, let text): throw MailError.serverRejected(text)
            default: break
            }
            let connection = self.connection
            let stopper = DoneSender()
            // When nothing happens for `timeout`, end the IDLE ourselves.
            let timer = Task {
                try? await Task.sleep(for: timeout)
                if await stopper.claim() { try? await connection.write("DONE\r\n") }
            }
            defer { timer.cancel() }
            var changed = false
            while true {
                let response = try IMAPParser.parse(try await self.readResponse())
                switch response {
                case .tagged(let got, let status, let text) where got == tag:
                    guard status == .ok else { throw MailError.serverRejected(text) }
                    return changed
                case .untaggedStatus(.bye, let text):
                    throw MailError.connectionFailed(text)
                default:
                    if Self.isMailboxChange(response) {
                        changed = true
                        if await stopper.claim() { try await connection.write("DONE\r\n") }
                    }
                }
            }
        }
    }

    /// `* 4 EXISTS`, `* 2 EXPUNGE`, `* 3 FETCH (FLAGS …)`: the mailbox changed.
    static func isMailboxChange(_ response: IMAPResponse) -> Bool {
        guard case .untagged(let values) = response, values.count >= 2 else { return false }
        let word = values[1].string?.uppercased()
        if values[0].string?.uppercased() == "VANISHED" { return true }
        return word == "EXISTS" || word == "EXPUNGE" || word == "FETCH" || word == "RECENT"
    }

    /// Reads the greeting, upgrades with STARTTLS when asked, and learns capabilities.
    func open(security: ConnectionSecurity) async throws {
        let greeting = try IMAPParser.parse(try await readResponse())
        switch greeting {
        case .untaggedStatus(.ok, let text), .untaggedStatus(.preauth, let text):
            learnCapabilities(fromStatusText: text)
        case .untaggedStatus(.bye, let text):
            throw MailError.connectionFailed(text)
        default:
            throw MailError.protocolViolation("Unexpected greeting.")
        }
        if security == .startTLS {
            if capabilities.isEmpty { try await refreshCapabilities() }
            guard capabilities.contains("STARTTLS") else {
                throw MailError.connectionFailed(String(localized: "The server doesn't offer STARTTLS."))
            }
            _ = try await command("STARTTLS")
            await connection.startTLS()
            capabilities = [] // must be asked again over TLS (RFC 9051 §6.2.1)
        }
        if capabilities.isEmpty { try await refreshCapabilities() }
    }

    func login(username: String, password: String) async throws {
        guard !capabilities.contains("LOGINDISABLED") else {
            throw MailError.authenticationFailed(String(localized: "The server doesn't accept passwords on this connection."))
        }
        guard let user = IMAPParser.quoted(username), let pass = IMAPParser.quoted(password) else {
            throw MailError.authenticationFailed(String(localized: "The username or password has a line break in it."))
        }
        do {
            let reply = try await command("LOGIN \(user) \(pass)", redacted: "LOGIN ***")
            learnCapabilities(fromStatusText: reply.text)
        } catch MailError.serverRejected(let text) {
            throw MailError.authenticationFailed(text)
        }
        try await refreshCapabilities()
    }

    /// SASL XOAUTH2 (Google, Microsoft) with an access token.
    func authenticate(username: String, accessToken: String) async throws {
        let payload = SASL.xoauth2(username: username, accessToken: accessToken)
        let mechanism = capabilities.contains("AUTH=OAUTHBEARER") && !capabilities.contains("AUTH=XOAUTH2")
            ? "OAUTHBEARER \(SASL.oauthBearer(username: username, accessToken: accessToken))"
            : "XOAUTH2 \(payload)"
        do {
            _ = try await command("AUTHENTICATE \(mechanism)", redacted: "AUTHENTICATE ***")
        } catch MailError.serverRejected(let text) {
            throw MailError.authenticationFailed(text)
        }
        try await refreshCapabilities()
    }

    func list() async throws -> [IMAPListItem] {
        let reply = try await command("LIST \"\" \"*\"")
        return reply.values.compactMap(IMAPListItem.init)
    }

    /// Selects a mailbox and returns how many messages it holds.
    @discardableResult
    func select(_ mailbox: String) async throws -> Int {
        try await selectMailbox(mailbox).exists
    }

    /// SELECT with optional parameters: `(CONDSTORE)`, or
    /// `(QRESYNC (uidvalidity modseq known-uids))` to hear what changed since the last visit.
    func selectMailbox(_ mailbox: String, parameters: String? = nil) async throws -> IMAPSelection {
        guard let name = IMAPParser.quoted(mailbox) else { throw MailError.protocolViolation(String(localized: "Bad mailbox name.")) }
        selected = nil
        let reply = try await command("SELECT \(name)" + (parameters.map { " " + $0 } ?? ""))
        selected = mailbox
        var selection = IMAPSelection()
        for response in reply.untagged {
            switch response {
            case .untaggedStatus(.ok, let text):
                guard let code = IMAPParser.responseCode(text) else { continue }
                switch code.name {
                case "UIDVALIDITY": selection.uidValidity = Int(code.value)
                case "UIDNEXT": selection.uidNext = Int(code.value)
                case "HIGHESTMODSEQ": selection.highestModSeq = Int(code.value)
                case "NOMODSEQ": selection.highestModSeq = nil
                default: break
                }
            case .untagged(let values):
                if values.first?.string?.uppercased() == "VANISHED", let set = values.last?.string {
                    selection.vanished += IMAPParser.ranges(set)
                } else if values.count >= 2, values[1].string?.uppercased() == "EXISTS", let count = values[0].int {
                    selection.exists = count
                } else if let item = IMAPFetchItem(values) {
                    selection.changed.append(item)
                }
            default: break
            }
        }
        return selection
    }

    func fetch(_ set: String, _ items: String, byUID: Bool = false) async throws -> [IMAPFetchItem] {
        let reply = try await command("\(byUID ? "UID " : "")FETCH \(set) \(items)")
        return reply.values.compactMap(IMAPFetchItem.init)
    }

    /// `UID SEARCH`; returns matching UIDs, oldest first.
    func uidSearch(_ criteria: String) async throws -> [Int] {
        let reply = try await command("UID SEARCH \(criteria)")
        return reply.values.filter { $0.first?.string?.uppercased() == "SEARCH" }.flatMap { $0.dropFirst().compactMap(\.int) }
    }

    func create(_ mailbox: String) async throws {
        guard let name = IMAPParser.quoted(mailbox) else { throw MailError.protocolViolation(String(localized: "Bad folder name.")) }
        _ = try await command("CREATE \(name)")
    }

    func rename(_ mailbox: String, to newName: String) async throws {
        guard let old = IMAPParser.quoted(mailbox), let new = IMAPParser.quoted(newName) else { throw MailError.protocolViolation(String(localized: "Bad folder name.")) }
        _ = try await command("RENAME \(old) \(new)")
        if selected == mailbox { selected = nil }
    }

    func delete(_ mailbox: String) async throws {
        guard let name = IMAPParser.quoted(mailbox) else { throw MailError.protocolViolation(String(localized: "Bad folder name.")) }
        // A selected folder can't be deleted. UNSELECT leaves it without expunging anything.
        if selected == mailbox {
            if capabilities.contains("UNSELECT") { _ = try await command("UNSELECT") } else { try await select("INBOX") }
            selected = nil
        }
        _ = try await command("DELETE \(name)")
    }

    func store(uids: [Int], _ change: String) async throws {
        guard !uids.isEmpty else { return }
        _ = try await command("UID STORE \(Self.set(uids)) \(change)")
    }

    /// Moves messages, with RFC 6851 MOVE when offered and copy + delete otherwise.
    func move(uids: [Int], to mailbox: String) async throws {
        guard !uids.isEmpty, let target = IMAPParser.quoted(mailbox) else { return }
        let set = Self.set(uids)
        if capabilities.contains("MOVE") {
            _ = try await command("UID MOVE \(set) \(target)")
            return
        }
        _ = try await command("UID COPY \(set) \(target)")
        _ = try await command("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        // Plain EXPUNGE would also remove other messages someone marked deleted.
        if capabilities.contains("UIDPLUS") { _ = try await command("UID EXPUNGE \(set)") }
    }

    func append(to mailbox: String, message: [UInt8], flags: String = "(\\Seen)") async throws {
        guard let target = IMAPParser.quoted(mailbox) else { return }
        try await exclusive {
            let tag = self.takeTag()
            let literalPlus = self.capabilities.contains("LITERAL+") || self.capabilities.contains("LITERAL-")
            try await self.connection.write("\(tag) APPEND \(target) \(flags) {\(message.count)\(literalPlus ? "+" : "")}\r\n")
            if !literalPlus {
                guard case .continuation = try IMAPParser.parse(try await self.readResponse()) else {
                    throw MailError.serverRejected(String(localized: "The server refused to store the message."))
                }
            }
            try await self.connection.write(message + Array("\r\n".utf8))
            _ = try await self.collect(until: tag)
        }
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        await connection.close()
    }

    // MARK: Commands

    func command(_ text: String, redacted: String? = nil) async throws -> IMAPReply {
        try await exclusive {
            let tag = self.takeTag()
            try await self.connection.write("\(tag) \(text)\r\n")
            return try await self.collect(until: tag)
        }
    }

    private func collect(until tag: String) async throws -> IMAPReply {
        var untagged: [IMAPResponse] = []
        while true {
            let response = try IMAPParser.parse(try await readResponse())
            switch response {
            case .tagged(let got, let status, let text) where got == tag:
                guard status == .ok else { throw MailError.serverRejected(text) }
                return IMAPReply(untagged: untagged, text: text)
            case .untaggedStatus(.bye, let text):
                throw MailError.connectionFailed(text)
            case .continuation:
                throw MailError.protocolViolation(String(localized: "The server asked for more input."))
            default:
                untagged.append(response)
            }
        }
    }

    /// One response, including any literals it carries.
    private func readResponse() async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while true {
            let line = try await connection.readLine()
            bytes += line
            guard let count = IMAPParser.literalLength(endingLine: line) else { return bytes }
            bytes += try await connection.readExactly(count)
        }
    }

    private func refreshCapabilities() async throws {
        let reply = try await command("CAPABILITY")
        for values in reply.values where values.first?.string?.uppercased() == "CAPABILITY" {
            capabilities = Set(values.dropFirst().compactMap { $0.string?.uppercased() })
        }
    }

    private func learnCapabilities(fromStatusText text: String) {
        guard text.uppercased().hasPrefix("[CAPABILITY "), let close = text.firstIndex(of: "]") else { return }
        let list = text[text.index(text.startIndex, offsetBy: 12)..<close]
        capabilities = Set(list.split(separator: " ").map { $0.uppercased() })
    }

    private func takeTag() -> String {
        defer { nextTag += 1 }
        return "M\(nextTag)"
    }

    /// Runs one exchange at a time; the actor alone would interleave them at awaits.
    private func exclusive<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if isBusy { await withCheckedContinuation { waiting.append($0) } }
        isBusy = true
        defer {
            if waiting.isEmpty { isBusy = false } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    /// `1,2,3,7` → `1:3,7`.
    static func set(_ numbers: [Int]) -> String {
        let sorted = Array(Set(numbers)).sorted()
        var ranges: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            ranges.append(end > index ? "\(sorted[index]):\(sorted[end])" : "\(sorted[index])")
            index = end + 1
        }
        return ranges.joined(separator: ",")
    }
}

enum SASL {
    static func xoauth2(username: String, accessToken: String) -> String {
        Data("user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8).base64EncodedString()
    }

    /// RFC 7628.
    static func oauthBearer(username: String, accessToken: String) -> String {
        Data("n,a=\(username),\u{01}auth=Bearer \(accessToken)\u{01}\u{01}".utf8).base64EncodedString()
    }

    static func plain(username: String, password: String) -> String {
        Data("\u{00}\(username)\u{00}\(password)".utf8).base64EncodedString()
    }
}

/// Makes sure DONE is sent once, whether the timer or a change ends the IDLE.
private actor DoneSender {
    private var sent = false
    func claim() -> Bool {
        defer { sent = true }
        return !sent
    }
}
