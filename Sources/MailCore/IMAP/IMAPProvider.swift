import Foundation

/// Reads over IMAP and sends over SMTP, straight from the device to the account's servers.
public actor IMAPProvider: MailProvider {
    private let account: MailAccount
    private let incoming: ServerEndpoint
    private let outgoing: ServerEndpoint
    private let credentials: any CredentialSource
    private var client: IMAPClient?
    /// A second connection that only sits in IDLE on the inbox, so waiting never blocks the
    /// first one's commands.
    private var watcher: IMAPClient?
    private var folders: [Mailbox] = []
    /// When the folder list was last read from the server. Folders rarely change, so a check
    /// doesn't ask for the list again within `folderListAge`.
    private var foldersListed: Date?
    static let folderListAge: TimeInterval = 5 * 60
    /// What each folder held at the last refresh, by mailbox name.
    private var sync: [String: IMAPFolderSync] = [:]
    /// Keeps `sync` between launches; nil in previews and tests that don't ask for it.
    private let syncStore: IMAPSyncStore?
    private var restored = false
    /// A saved folder state is brought back with at most this many messages: the window a list
    /// starts with. Older mail that was scrolled to before isn't refreshed on every check after.
    static let restoredWindow = 200
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Downloads in the background (reading ahead, invitations, the assistant) wait here, behind
    /// checks and anything a person asked for.
    private var waitingLater: [CheckedContinuation<Void, Never>] = []
    /// A third connection, only for the mail someone just opened. The first one does one folder
    /// operation at a time (a refresh, the Sent check, reading ahead), and a click shouldn't
    /// stand in that line.
    private var reader: IMAPClient?
    private var readerIsBusy = false
    private var readerWaiting: [CheckedContinuation<Void, Never>] = []
    /// Set when the server wouldn't give a connection for reading (some allow very few): until
    /// then the first connection is used, as before.
    private var readerRefusedUntil: Date?
    /// How much of a message is fetched first. Text comes before attachments in nearly all
    /// mail, so this is enough to show it; the rest follows.
    static let openingBytes = 200_000

    /// The parts of a message a list needs: no body.
    static let listItems = "(UID FLAGS ENVELOPE RFC822.SIZE INTERNALDATE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (LIST-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST PRECEDENCE REFERENCES AUTO-SUBMITTED FEEDBACK-ID X-CSA-COMPLAINTS X-MAILGUN-SID X-SES-OUTGOING X-SG-EID X-MC-USER X-MS-REACTIONS)])"

    public init(account: MailAccount, credentials: any CredentialSource, syncStore: IMAPSyncStore? = nil) throws {
        guard case .imap(let incoming, let outgoing) = account.connection else {
            throw MailError.notSupported(String(localized: "Not an IMAP account."))
        }
        self.account = account
        self.incoming = incoming
        self.outgoing = outgoing
        self.credentials = credentials
        self.syncStore = syncStore
    }

    /// Which server and sign-in the saved state belongs to.
    private var syncOwner: String {
        let user: String = switch account.auth {
        case .password(let name), .oauth(_, let name): name
        case .token: ""
        }
        return "\(incoming.host.lowercased()):\(incoming.port) \(user.lowercased())"
    }

    /// Brings back what every folder held when the app last ran, once, before the first sync.
    private func restoreSync() async {
        guard !restored else { return }
        restored = true
        guard let syncStore else { return }
        for (name, var state) in await syncStore.load(account: account.id, server: syncOwner) where sync[name] == nil {
            state.window = min(state.window, Self.restoredWindow)
            state.messages = state.messages.mapValues { message in
                var compact = message
                compact.listHeaders = InboxSplit.compact(message.listHeaders)
                compact.snippet = HTMLText.cleanedPreview(message.snippet)
                return compact
            }
            state.trim()
            sync[name] = state
        }
    }

    /// Saves `sync` on the side when a refresh changed it.
    private func saveSync() {
        guard let syncStore else { return }
        let snapshot = sync, taken = ContinuousClock.now, id = account.id, owner = syncOwner
        Task.detached(priority: .utility) { await syncStore.save(snapshot, account: id, server: owner, taken: taken) }
    }

    /// The account's folders. Asked of the server at most every `folderListAge` (and after a
    /// reconnect, or when a folder is made, renamed or deleted here); in between, every check
    /// would otherwise spend a round trip on a list that hasn't changed.
    public func mailboxes() async throws -> [Mailbox] {
        if !folders.isEmpty, let listed = foldersListed, Date().timeIntervalSince(listed) < Self.folderListAge { return folders }
        return try await listedAgain()
    }

    private func listedAgain() async throws -> [Mailbox] {
        try await reliably { try await self.listMailboxes() }
    }

    private func listMailboxes() async throws -> [Mailbox] {
        let before = foldersListed
        let client = try await connected()
        // A new connection reads the list as it signs in: no need to ask twice.
        if foldersListed != before { return folders }
        let items = try await client.list().filter(\.isSelectable)
        let names = Set(items.map(\.name))
        folders = items.map { item in
            // Folders inside others show their own name, nested under the parent.
            let parent = item.parent.flatMap { names.contains($0) ? $0 : nil }
            return Mailbox(id: item.name, name: ModifiedUTF7.decode(parent == nil ? item.name : item.shortName), role: item.role, parentID: parent)
        }
        foldersListed = Date()
        return folders
    }

    /// The newest `limit` messages, threaded. The first visit to a folder fetches them all;
    /// later ones fetch only what changed (see `refresh`).
    public func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] {
        var laps = StepTimes.Laps()
        return try await exclusive {
            laps.lap("waited for the connection")
            defer { StepTimes.send("\(self.tag) \(mailbox.role == .inbox ? "inbox" : "folder"): \(laps.line)") }
            return try await self.reliably {
                let client = try await self.connected()
                laps.lap("connection")
                await self.restoreSync()
                let before = self.sync[mailbox.id]
                let state = try await self.refresh(mailbox.id, limit: limit, client: client)
                laps.lap(before == nil ? "full download" : "sync")
                if self.sync[mailbox.id] != before { self.saveSync() }
                let newest = state.messages.keys.sorted(by: >).prefix(max(0, limit)).compactMap { state.messages[$0] }
                return Threader.threads(from: newest).sorted { $0.date > $1.date }
            }
        }
    }

    /// How this mailbox shows in step times: its server and the start of its id, no address.
    private var tag: String { "IMAP \(incoming.host) \(account.id.uuidString.prefix(8))" }

    public func body(of message: MailMessage) async throws -> MessageBody {
        try await exclusive(.later) { try await self.reliably { try await self.fetchBody(of: message) } }
    }

    private func fetchBody(of message: MailMessage) async throws -> MessageBody {
        let client = try await connected()
        guard let uid = Self.uid(of: message) else { throw MailError.protocolViolation(String(localized: "Unknown message.")) }
        if await client.selected != message.mailboxID { try await client.select(message.mailboxID) }
        // The whole message, attachments included, so files can be opened and saved offline.
        let items = try await client.fetch("\(uid)", "(UID BODY.PEEK[])", byUID: true)
        guard let raw = items.first?.sections[""] else {
            throw MailError.protocolViolation(String(localized: "The message body was missing."))
        }
        return MIMEMessage.parse(raw).body
    }

    // MARK: The mail on screen

    public func openedBody(of message: MailMessage) async throws -> (body: MessageBody, isComplete: Bool) {
        guard let uid = Self.uid(of: message) else { throw MailError.protocolViolation(String(localized: "Unknown message.")) }
        return try await onReader { client in
            if await client.selected != message.mailboxID { try await client.select(message.mailboxID) }
            let items = try await client.fetch("\(uid)", "(UID RFC822.SIZE BODY.PEEK[]<0.\(Self.openingBytes)>)", byUID: true)
            guard let item = items.first, let start = item.sections[""] else {
                throw MailError.protocolViolation(String(localized: "The message body was missing."))
            }
            // All of it came: small mail, which is most mail, is done in one request.
            if start.count < Self.openingBytes || (item.size ?? .max) <= start.count {
                return (MIMEMessage.parse(start).body, true)
            }
            if let opening = Self.readableStart(of: start) { return (opening, false) }
            // The start didn't hold the text (a huge newsletter, or files put first): the whole.
            let whole = try await client.fetch("\(uid)", "(UID BODY.PEEK[])", byUID: true)
            guard let raw = whole.first?.sections[""] else {
                throw MailError.protocolViolation(String(localized: "The message body was missing."))
            }
            return (MIMEMessage.parse(raw).body, true)
        }
    }

    /// The text of a message from its first bytes, when they hold all of it: the text parts
    /// were read and a file after them had begun, so the cut fell in the files, not the text.
    /// The files are left out (they're incomplete) and the body is marked partial.
    static func readableStart(of bytes: [UInt8]) -> MessageBody? {
        let parsed = MIMEMessage.parse(bytes)
        guard !parsed.attachments.isEmpty, !(parsed.text.isEmpty && (parsed.html ?? "").isEmpty) else { return nil }
        let readable = parsed.text.isEmpty ? (parsed.html.map(HTMLText.plain) ?? "") : parsed.text
        var body = MessageBody(text: readable.trimmingCharacters(in: .whitespacesAndNewlines), html: parsed.html, invite: parsed.invite,
                               reaction: parsed.reaction)
        body.isPartial = true
        return body
    }

    public func bodies(of messages: [MailMessage]) async throws -> [String: MessageBody] {
        var found: [String: MessageBody] = [:]
        // One request per folder, however many messages.
        for (mailboxID, group) in Dictionary(grouping: messages, by: \.mailboxID) {
            let uids = group.compactMap(Self.uid(of:))
            guard !uids.isEmpty else { continue }
            // Conversation history and attachments must not occupy the connection used to
            // open the next message. That connection is reserved for `openedBody`.
            let items = try await exclusive(.later) {
                try await self.reliably {
                    let client = try await self.connected()
                    if await client.selected != mailboxID { try await client.select(mailboxID) }
                    return try await client.fetch(IMAPClient.set(uids.sorted()), "(UID BODY.PEEK[])", byUID: true)
                }
            }
            for item in items {
                guard let uid = item.uid, let raw = item.sections[""] else { continue }
                found["\(mailboxID)/\(uid)"] = MIMEMessage.parse(raw).body
            }
        }
        return found
    }

    /// The first `openingBytes` of each message in one request per folder: small mail (most
    /// mail) comes whole, bigger mail as its text without the files, marked partial.
    public func readableBodies(of messages: [MailMessage]) async throws -> [String: MessageBody] {
        var found: [String: MessageBody] = [:]
        for (mailboxID, group) in Dictionary(grouping: messages, by: \.mailboxID) {
            let uids = group.compactMap(Self.uid(of:))
            guard !uids.isEmpty else { continue }
            let items = try await exclusive(.later) {
                try await self.reliably {
                    let client = try await self.connected()
                    if await client.selected != mailboxID { try await client.select(mailboxID) }
                    return try await client.fetch(IMAPClient.set(uids.sorted()), "(UID RFC822.SIZE BODY.PEEK[]<0.\(Self.openingBytes)>)", byUID: true)
                }
            }
            for item in items {
                guard let uid = item.uid, let start = item.sections[""] else { continue }
                if start.count < Self.openingBytes || (item.size ?? .max) <= start.count {
                    found["\(mailboxID)/\(uid)"] = MIMEMessage.parse(start).body
                } else if let opening = Self.readableStart(of: start) {
                    found["\(mailboxID)/\(uid)"] = opening
                }
            }
        }
        return found
    }

    /// Does `work` on the connection kept for the mail on screen, one request at a time, and
    /// gets over that connection having died the same way `reliably` does. A server that won't
    /// give a connection for it is asked on the first one instead.
    private func onReader<T: Sendable>(_ work: (IMAPClient) async throws -> T) async throws -> T {
        if let until = readerRefusedUntil, until > Date() {
            return try await exclusive { try await self.reliably { try await work(try await self.connected()) } }
        }
        if readerIsBusy { await withCheckedContinuation { readerWaiting.append($0) } }
        readerIsBusy = true
        defer {
            if readerWaiting.isEmpty { readerIsBusy = false } else { readerWaiting.removeFirst().resume() }
        }
        let reused = reader != nil
        do {
            return try await work(try await readerConnection())
        } catch where MailError.isConnectionProblem(error) {
            await dropReader()
            guard reused, !Task.isCancelled else { throw error }
        } catch where reader == nil {
            // Couldn't even sign in a third time (too many connections, for one): the first
            // connection does it, and this isn't tried again for a while.
            readerRefusedUntil = Date().addingTimeInterval(10 * 60)
            return try await exclusive { try await self.reliably { try await work(try await self.connected()) } }
        }
        do {
            return try await work(try await readerConnection())
        } catch where MailError.isConnectionProblem(error) {
            await dropReader()
            throw error
        }
    }

    private func readerConnection() async throws -> IMAPClient {
        if let reader { return reader }
        let client = try await signedIn(readTimeout: 30)
        reader = client
        return client
    }

    private func dropReader() async {
        guard let dead = reader else { return }
        reader = nil
        Task.detached { await dead.logout() }
    }

    public func rawSource(of message: MailMessage) async throws -> Data {
        try await exclusive {
            try await self.reliably {
                let client = try await self.connected()
                guard let uid = Self.uid(of: message) else { throw MailError.protocolViolation(String(localized: "Unknown message.")) }
                if await client.selected != message.mailboxID { try await client.select(message.mailboxID) }
                let items = try await client.fetch("\(uid)", "(UID BODY.PEEK[])", byUID: true)
                guard let raw = items.first?.sections[""] else {
                    throw MailError.protocolViolation(String(localized: "The message body was missing."))
                }
                return Data(raw)
            }
        }
    }

    public func perform(_ action: MailAction, on threads: [MailThread]) async throws {
        // Flag changes can be said twice without harm, and a move names its messages by UID: once
        // they've moved, saying it again moves nothing. So these are safe to do over.
        try await exclusive { try await self.reliably { try await self.apply(action, on: threads) } }
    }

    private func apply(_ action: MailAction, on threads: [MailThread]) async throws {
        let client = try await connected()
        let byMailbox = Dictionary(grouping: threads.flatMap(\.messages), by: \.mailboxID)
        for (mailboxID, messages) in byMailbox {
            let uids = messages.compactMap(Self.uid(of:))
            if await client.selected != mailboxID { try await client.select(mailboxID) }
            switch action {
            case .markRead: try await client.store(uids: uids, "+FLAGS.SILENT (\\Seen)")
            case .markUnread: try await client.store(uids: uids, "-FLAGS.SILENT (\\Seen)")
            case .star: try await client.store(uids: uids, "+FLAGS.SILENT (\\Flagged)")
            case .unstar: try await client.store(uids: uids, "-FLAGS.SILENT (\\Flagged)")
            case .done:
                guard let target = folder(.archive) ?? folder(.all) else {
                    throw MailError.notSupported(String(localized: "This account has no Archive folder."))
                }
                if target.id != mailboxID { try await client.move(uids: uids, to: target.id) }
            case .moveToInbox:
                if mailboxID != "INBOX" { try await client.move(uids: uids, to: "INBOX") }
            case .trash:
                guard let target = folder(.trash) else { throw MailError.notSupported(String(localized: "This account has no Trash folder.")) }
                if target.id != mailboxID { try await client.move(uids: uids, to: target.id) }
            case .move(let target):
                if target != mailboxID { try await client.move(uids: uids, to: target) }
            }
        }
    }

    public func send(_ draft: Draft) async throws {
        let message = MessageBuilder.build(draft)
        let smtp = try SMTPClient(endpoint: outgoing)
        try await smtp.open(security: outgoing.security)
        switch account.auth {
        case .password(let username):
            try await smtp.authenticate(username: username, password: try await credentials.secret(for: account))
        case .oauth(_, let username):
            try await smtp.authenticate(username: username, accessToken: try await credentials.secret(for: account))
        case .token:
            throw MailError.notSupported(String(localized: "Sending needs a password or a sign-in."))
        }
        try await smtp.send(from: draft.from.address, to: draft.recipients.map(\.address), message: message)
        await smtp.quit()
        // SMTP doesn't keep a copy; file one in Sent. Some servers (Gmail, Outlook) already do.
        if !Self.serverFilesSent(incoming.host), let sent = folder(.sent) {
            try? await checkedConnection().append(to: sent.id, message: message)
        }
    }

    /// Searches the inbox, the archive (or all mail) and Sent on the server.
    public func search(_ text: String, limit: Int) async throws -> [MailThread] {
        let words = text.split(separator: " ").map(String.init).filter { !$0.contains(":") }
        guard !words.isEmpty else { return [] }
        // Quoted strings must be plain ASCII unless the server accepts UTF-8; others are searched locally only.
        guard let criteria = try? words.map({ word -> String in
            guard word.unicodeScalars.allSatisfy(\.isASCII), let quoted = IMAPParser.quoted(word) else { throw MailError.notSupported("") }
            return "TEXT \(quoted)"
        }).joined(separator: " ") else { return [] }
        return try await exclusive { try await self.reliably { try await self.searchServer(criteria, limit: limit) } }
    }

    private func searchServer(_ criteria: String, limit: Int) async throws -> [MailThread] {
        let client = try await connected()
        var boxes = [folder(.inbox), folder(.archive) ?? folder(.all), folder(.sent)].compactMap { $0 }
        if boxes.isEmpty { boxes = [Mailbox(id: "INBOX", name: "Inbox", role: .inbox)] }
        var messages: [MailMessage] = []
        for mailbox in boxes {
            try await client.select(mailbox.id)
            let uids = try await client.uidSearch(criteria).suffix(limit)
            guard !uids.isEmpty else { continue }
            let items = try await client.fetch(IMAPClient.set(Array(uids)), Self.listItems, byUID: true)
            messages += items.compactMap { message(from: $0, mailbox: mailbox.id) }
        }
        return Array(Threader.threads(from: messages).sorted { $0.date > $1.date }.prefix(limit))
    }

    // MARK: Older mail, in the background

    /// A page of headers below the lowest UID fetched so far (`position`), by sequence number:
    /// the lowest UID's place in the folder is asked for (`UID FETCH u (UID)`), and the
    /// `limit` messages before it are fetched. Nothing is added to `sync`, so a refresh keeps
    /// looking at its own window only. One page holds the main connection for one request or
    /// two; a refresh waits at most that long, and the mail on screen has its own connection.
    public func olderMessages(in mailbox: Mailbox, after position: String?, limit: Int) async throws -> OlderMailPage {
        try await exclusive {
            try await self.reliably {
                let client = try await self.connected()
                let selection = try await client.selectMailbox(mailbox.id)
                let validity = selection.uidValidity.map(String.init)
                guard selection.exists > 0, limit > 0 else { return OlderMailPage(validity: validity) }
                var top = selection.exists
                var below: Int?
                if let position, let uid = Int(position) {
                    below = uid
                    guard uid > 1, let place = try await self.sequence(below: uid, client: client) else {
                        return OlderMailPage(validity: validity)
                    }
                    top = place
                }
                let first = max(1, top - limit + 1)
                let items = try await client.fetch("\(first):\(top)", Self.listItems)
                    .filter { item in below.map { (item.uid ?? .max) < $0 } ?? true }
                var page = IMAPFolderSync(uidValidity: selection.uidValidity ?? 0, uidNext: nil, exists: selection.exists, messages: [:], window: 0)
                await self.add(items, to: &page, mailbox: mailbox.id, client: client)
                let lowest = page.messages.keys.min()
                return OlderMailPage(messages: page.messages.keys.sorted(by: >).compactMap { page.messages[$0] },
                                     next: first > 1 ? (lowest ?? below).map(String.init) : nil, validity: validity)
            }
        }
    }

    /// The sequence number of the highest message below `uid`.
    private func sequence(below uid: Int, client: IMAPClient) async throws -> Int? {
        // Usually the message is still there: its own place, less one.
        if let item = try await client.fetch("\(uid)", "(UID)", byUID: true).first(where: { $0.uid == uid }) {
            return item.sequence > 1 ? item.sequence - 1 : nil
        }
        // It left: the nearest one below it.
        var low = max(1, uid - 2_000)
        while true {
            if let found = try await client.uidSearch("UID \(low):\(uid - 1)").filter({ $0 < uid }).max() {
                return try await client.fetch("\(found)", "(UID)", byUID: true).first(where: { $0.uid == found })?.sequence
            }
            if low == 1 { return nil }
            low = max(1, low - 50_000)
        }
    }

    /// Which saved messages are gone and whose flags changed. With CONDSTORE and a token from
    /// before (`uidvalidity:modseq`) only flags changed since are fetched; without, the flags of
    /// every saved message. Gone ones are found with one `UID SEARCH` over the saved range. A
    /// new UIDVALIDITY means every saved id names another message now: all of them are gone.
    public func checkSaved(_ ids: [String], in mailbox: Mailbox, since token: String?) async throws -> SavedMailCheck {
        var byUID: [Int: String] = [:]
        for id in ids {
            guard id.hasPrefix(mailbox.id + "/"), let uid = Self.uid(of: id) else { continue }
            byUID[uid] = id
        }
        return try await exclusive(.later) {
            try await self.reliably {
                let client = try await self.connected()
                let condStore = await client.supportsCondStore
                let selection = try await client.selectMailbox(mailbox.id, parameters: condStore ? "(CONDSTORE)" : nil)
                var check = SavedMailCheck()
                let validity = selection.uidValidity ?? 0
                check.token = selection.highestModSeq.map { "\(validity):\($0)" }
                guard let low = byUID.keys.min(), let high = byUID.keys.max() else { return check }
                let parts = token?.split(separator: ":").compactMap { Int($0) } ?? []
                if parts.count == 2, parts[0] != validity {
                    check.gone = Array(byUID.values)
                    return check
                }
                let present = Set(try await client.uidSearch("UID \(low):\(high)"))
                check.gone = byUID.filter { !present.contains($0.key) }.map(\.value)
                let asked = byUID.keys.filter(present.contains)
                guard !asked.isEmpty else { return check }
                let since = parts.count == 2 && condStore ? parts[1] : nil
                if let since, let now = selection.highestModSeq, now == since { return check }
                let changes = since.map { " (CHANGEDSINCE \($0))" } ?? ""
                for item in try await client.fetch(IMAPClient.set(asked), "(UID FLAGS)" + changes, byUID: true) {
                    guard let uid = item.uid, item.hasFlags, let id = byUID[uid] else { continue }
                    check.flags[id] = item.flags
                }
                return check
            }
        }
    }

    static func uid(of id: String) -> Int? {
        id.split(separator: "/").last.flatMap { Int($0) }
    }

    public func createMailbox(named name: String) async throws {
        try await checkedConnection().create(name)
        _ = try await listedAgain()
    }

    public func renameMailbox(_ mailbox: Mailbox, to name: String) async throws {
        try await exclusive {
            try await self.checkedConnection().rename(mailbox.id, to: name)
            self.sync[mailbox.id] = nil
            self.saveSync()
        }
        _ = try await listedAgain()
    }

    public func deleteMailbox(_ mailbox: Mailbox) async throws {
        try await exclusive {
            try await self.checkedConnection().delete(mailbox.id)
            self.sync[mailbox.id] = nil
            self.saveSync()
        }
        _ = try await listedAgain()
    }

    /// Appends the message to Drafts with the \Draft flag (RFC 9051 §6.3.12).
    public func saveDraft(_ draft: Draft) async throws {
        guard let drafts = folder(.drafts) else { throw MailError.notSupported(String(localized: "This account has no Drafts folder.")) }
        try await checkedConnection().append(to: drafts.id, message: MessageBuilder.build(draft), flags: "(\\Seen \\Draft)")
    }

    public func disconnect() async {
        // The network changed or the Mac woke: the next check reads the folder list again.
        foldersListed = nil
        await dropConnection()
        await dropReader()
        // The watcher may be deep in a long wait; its line is simply closed.
        if let waiting = watcher {
            watcher = nil
            await waiting.abandon()
        }
    }

    // MARK: Staying connected

    /// Does `work` over the account's connection, and gets over that connection having died.
    ///
    /// A connection is kept open between requests, and it dies without telling anyone: the
    /// computer sleeps, the phone puts the app away, the network changes, or the server hangs up
    /// after a quiet while. The next request then fails with "Socket is not connected", a
    /// timeout, or "connection closed". A dead connection is never kept: it's dropped, and when
    /// the failed work ran on a connection from before, it's done once more on a new one. A
    /// brand-new connection that fails is the real thing (no network, server down) and is
    /// reported as it is.
    private func reliably<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        let reused = client != nil
        do {
            return try await work()
        } catch where MailError.isConnectionProblem(error) {
            await dropConnection()
            guard reused, !Task.isCancelled else { throw error }
        }
        do {
            return try await work()
        } catch where MailError.isConnectionProblem(error) {
            await dropConnection()
            throw error
        }
    }

    /// Forgets the connection in use, so the next request makes a new one. The goodbye is said
    /// on the side: on a dead line it can sit until its timeout, and nobody should wait for that.
    private func dropConnection() async {
        guard let dead = client else { return }
        client = nil
        Task.detached { await dead.logout() }
    }

    /// A connection that was just seen to answer. For work that mustn't be done twice (adding a
    /// message to a folder), which is why it's checked first instead of repeated after.
    private func checkedConnection() async throws -> IMAPClient {
        if let client {
            do {
                _ = try await client.command("NOOP")
                return client
            } catch where MailError.isConnectionProblem(error) {
                await dropConnection()
            }
        }
        return try await connected()
    }

    // MARK: Sync

    /// Brings the remembered copy of a folder up to date in the cheapest way the server allows,
    /// and fetches envelopes only for messages it hasn't seen:
    /// - QRESYNC: SELECT names the last UIDVALIDITY, HIGHESTMODSEQ and known UIDs, and the
    ///   server answers with what vanished and whose flags changed.
    /// - CONDSTORE: when HIGHESTMODSEQ and the count are unchanged nothing happened; otherwise
    ///   one UID SEARCH finds new and removed messages, and `CHANGEDSINCE` the changed flags.
    /// - Neither: UIDNEXT and the count tell whether anything arrived or left; flags are
    ///   fetched for the known messages, which is cheap.
    /// A new UIDVALIDITY, or anything that doesn't add up, falls back to a full fetch.
    private func refresh(_ name: String, limit: Int, client: IMAPClient) async throws -> IMAPFolderSync {
        let condStore = await client.supportsCondStore
        let qresync = await client.qresyncEnabled
        guard var state = sync[name], let lowest = state.messages.keys.min(), let highest = state.messages.keys.max() else {
            return try await fullFetch(name, window: limit, client: client)
        }
        state.window = max(state.window, limit)
        let known = "\(lowest):\(highest)"
        let usedQResync = qresync && state.highestModSeq != nil
        let selection = try await client.selectMailbox(name, parameters: usedQResync
            ? "(QRESYNC (\(state.uidValidity) \(state.highestModSeq!) \(known)))"
            : condStore ? "(CONDSTORE)" : nil)
        guard let validity = selection.uidValidity, validity == state.uidValidity else {
            // The folder's UIDs were renumbered: nothing remembered still holds.
            return try await fullFetch(name, window: state.window, client: client, selected: selection)
        }

        var fresh = Set<Int>()
        if usedQResync, let old = state.highestModSeq, let current = selection.highestModSeq {
            state.messages = state.messages.filter { uid, _ in !selection.vanished.contains { $0.contains(uid) } }
            for item in selection.changed {
                guard let uid = item.uid else { continue }
                if state.messages[uid] != nil { state.update(item) } else if uid > highest { fresh.insert(uid) }
            }
            // Every new message raises HIGHESTMODSEQ, so an unchanged one means none arrived.
            if current != old { fresh.formUnion(try await client.uidSearch("UID \(highest + 1):*").filter { $0 > highest }) }
        } else if let old = state.highestModSeq, let current = selection.highestModSeq {
            if current != old || selection.exists != state.exists {
                // One FETCH says both what changed and what arrived: every new message raises
                // HIGHESTMODSEQ, so it's among the answers. When the count then adds up (the
                // old count plus the arrivals) nothing left either, and no SEARCH is needed.
                var arrived = Set<Int>()
                if current != old {
                    for item in try await client.fetch("\(lowest):*", "(UID FLAGS) (CHANGEDSINCE \(old))", byUID: true) {
                        guard let uid = item.uid else { continue }
                        if uid > highest { arrived.insert(uid) } else { state.update(item) }
                    }
                }
                if selection.exists == state.exists + arrived.count {
                    fresh = arrived
                } else {
                    fresh = try await state.reconcile(with: client.uidSearch("UID \(lowest):*"), above: highest)
                }
            }
        } else {
            let unchanged = selection.exists == state.exists && selection.uidNext != nil && selection.uidNext == state.uidNext
            if !unchanged {
                // The flags of everything from the lowest known UID up: that lists what's still
                // there (and so what left), what's new, and every flag, in one command.
                let items = try await client.fetch("\(lowest):*", "(UID FLAGS)", byUID: true)
                fresh = state.reconcile(with: items.compactMap(\.uid), above: highest)
                for item in items { state.update(item) }
            } else if !state.messages.isEmpty {
                for item in try await client.fetch(known, "(UID FLAGS)", byUID: true) { state.update(item) }
            }
        }

        let wanted = fresh.sorted().suffix(state.window)
        if !wanted.isEmpty {
            await add(try await client.fetch(IMAPClient.set(Array(wanted)), Self.listItems, byUID: true), to: &state, mailbox: name, client: client)
        }
        state.trim()
        state.exists = selection.exists
        state.uidNext = selection.uidNext
        state.highestModSeq = selection.highestModSeq
        try await backfill(&state, mailbox: name, client: client)
        guard state.messages.count == min(state.window, state.exists) else {
            return try await fullFetch(name, window: state.window, client: client, selected: selection)
        }
        sync[name] = state
        return state
    }

    /// The first visit, and the fallback: the newest `window` messages by sequence number,
    /// all fetched whole.
    private func fullFetch(_ name: String, window: Int, client: IMAPClient, selected: IMAPSelection? = nil) async throws -> IMAPFolderSync {
        let condStore = await client.supportsCondStore
        let selection: IMAPSelection
        if let selected { selection = selected } else { selection = try await client.selectMailbox(name, parameters: condStore ? "(CONDSTORE)" : nil) }
        var state = IMAPFolderSync(
            uidValidity: selection.uidValidity ?? 0, highestModSeq: selection.highestModSeq,
            uidNext: selection.uidNext, exists: selection.exists, messages: [:], window: max(0, window)
        )
        if selection.exists > 0, window > 0 {
            let first = max(1, selection.exists - window + 1)
            let started = ContinuousClock.now
            let items = try await client.fetch("\(first):\(selection.exists)", Self.listItems)
            StepTimes.send("\(tag) full download of \(items.count) messages: list items \(StepTimes.milliseconds(since: started)) ms")
            await add(items, to: &state, mailbox: name, client: client)
        }
        // Without UIDVALIDITY the UIDs can't be trusted next time.
        sync[name] = selection.uidValidity == nil ? nil : state
        return state
    }

    /// When messages left (or a caller wants more), fills the window from below. The window
    /// is always the newest messages, so the gap is just under it in sequence numbers.
    private func backfill(_ state: inout IMAPFolderSync, mailbox: String, client: IMAPClient) async throws {
        let missing = min(state.window, state.exists) - state.messages.count
        guard missing > 0 else { return }
        let top = state.exists - state.messages.count
        await add(try await client.fetch("\(top - missing + 1):\(top)", Self.listItems), to: &state, mailbox: mailbox, client: client)
    }

    private func add(_ items: [IMAPFetchItem], to state: inout IMAPFolderSync, mailbox: String, client: IMAPClient) async {
        var parts: [Int: IMAPTextPart] = [:]
        for item in items {
            guard let uid = item.uid, let message = message(from: item, mailbox: mailbox) else { continue }
            state.messages[uid] = message
            if let part = item.textPart { parts[uid] = part }
        }
        // Previews: the start of each message's text. IMAP's list has no preview of its own. A
        // failure only leaves previews empty. A plain part that is really HTML gets one more,
        // longer read, past its style code.
        let started = ContinuousClock.now
        var requests = 0, separate = 0
        for round in 0..<2 where !parts.isEmpty {
            var again: [Int: IMAPTextPart] = [:]
            // One request per part number and length. The encoding and character set only
            // matter for reading each answer; asking per combination of them took dozens of
            // round trips for 200 mixed mails, one after the other (14 s on Outlook.com).
            let requested = Dictionary(grouping: parts.keys) { PreviewRequest(section: parts[$0]!.section, bytes: parts[$0]!.previewBytes) }
            requests += requested.count
            separate += Set(parts.values).count
            for (request, uids) in requested.sorted(by: { $0.key.section < $1.key.section }) {
                let section = "BODY.PEEK[\(request.section)]<0.\(request.bytes)>"
                guard let fetched = try? await client.fetch(IMAPClient.set(uids.sorted()), "(UID \(section))", byUID: true) else { continue }
                for item in fetched {
                    guard let uid = item.uid, let part = parts[uid], let bytes = item.sections[request.section] else { continue }
                    let preview = part.preview(from: bytes)
                    state.messages[uid]?.snippet = preview
                    if round == 0, let longer = part.againAsHTML(after: bytes, preview: preview) { again[uid] = longer }
                }
            }
            parts = again
        }
        if requests > 0 {
            StepTimes.send("\(tag) previews of \(items.count) messages: \(requests) requests (\(separate) before), \(StepTimes.milliseconds(since: started)) ms")
        }
    }

    /// Which line a folder operation waits in.
    enum Lane { case now, later }

    /// Runs one folder operation at a time: each SELECTs, and interleaving would read the
    /// wrong folder and corrupt what's remembered. Work in the `.later` line (downloads nobody
    /// is looking at yet) goes only when nothing in the `.now` line waits, so a check waits
    /// for at most the one download under way, not for every one queued before it: twelve
    /// queued downloads used to hold a check up for twelve round trips.
    private func exclusive<T: Sendable>(_ lane: Lane = .now, _ body: () async throws -> T) async throws -> T {
        if isBusy {
            await withCheckedContinuation { continuation in
                if lane == .now { waiting.append(continuation) } else { waitingLater.append(continuation) }
            }
        }
        isBusy = true
        defer {
            if !waiting.isEmpty {
                waiting.removeFirst().resume()
            } else if !waitingLater.isEmpty {
                waitingLater.removeFirst().resume()
            } else {
                isBusy = false
            }
        }
        return try await body()
    }

    // MARK: Helpers

    public func waitForInboxChange(timeout: Duration) async throws -> Bool {
        let watcher: IMAPClient
        if let existing = self.watcher {
            watcher = existing
        } else {
            watcher = try await signedIn(readTimeout: 30 * 60)
            guard await watcher.supportsIdle else {
                await watcher.logout()
                throw MailError.notSupported(String(localized: "This server can't push new mail."))
            }
            _ = try await watcher.select("INBOX")
            self.watcher = watcher
        }
        do {
            return try await watcher.idle(timeout: timeout)
        } catch {
            // A dropped connection: start fresh next time.
            self.watcher = nil
            await watcher.logout()
            throw error
        }
    }

    private func connected() async throws -> IMAPClient {
        if let client { return client }
        let started = ContinuousClock.now
        let client = try await signedIn(readTimeout: 30)
        let signedIn = StepTimes.milliseconds(since: started)
        // Must come before the first SELECT.
        await client.enableQResync()
        self.client = client
        let listing = ContinuousClock.now
        if folders.isEmpty { _ = try await listMailboxes() }
        StepTimes.send("\(tag) new connection: signed in \(signedIn) ms, then folder list \(StepTimes.milliseconds(since: listing)) ms")
        return client
    }

    /// A new connection, opened and signed in. Outlook.com sometimes answers a good sign-in with
    /// "User is authenticated but not connected" when the mailbox behind it isn't ready yet; that
    /// passes, so it's tried again a few times, a little later each time, before it's an error.
    private func signedIn(readTimeout: TimeInterval) async throws -> IMAPClient {
        var attempt = 0
        while true {
            do {
                return try await signInOnce(readTimeout: readTimeout)
            } catch let MailError.authenticationFailed(detail) where Self.isPassing(detail) {
                StepTimes.send("\(tag) sign-in answered \"not now\", attempt \(attempt + 1)")
                guard attempt < 3 else { throw MailError.connectionFailed(detail) }
                attempt += 1
                try await Task.sleep(for: .milliseconds(800 * attempt))
            }
        }
    }

    /// Server answers to a good sign-in that only mean "not now".
    static func isPassing(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return text.contains("authenticated but not connected") || text.contains("temporarily unavailable")
            || text.contains("try again later")
    }

    private func signInOnce(readTimeout: TimeInterval) async throws -> IMAPClient {
        var laps = StepTimes.Laps()
        defer { StepTimes.send("\(tag) sign-in: \(laps.line)") }
        let client = try IMAPClient(endpoint: incoming, readTimeout: readTimeout)
        try await client.open(security: incoming.security)
        laps.lap("open")
        do {
            switch account.auth {
            case .password(let username):
                let password = try await credentials.secret(for: account)
                laps.lap("token")
                try await client.login(username: username, password: password)
            case .oauth(_, let username):
                let token = try await credentials.secret(for: account)
                laps.lap("token")
                try await client.authenticate(username: username, accessToken: token)
            case .token:
                throw MailError.notSupported(String(localized: "IMAP needs a password or a sign-in."))
            }
            laps.lap("sign in")
        } catch {
            laps.note("failed")
            // Closed straight away, so a retry doesn't leave a connection open on the server.
            await client.logout()
            throw error
        }
        return client
    }

    private func folder(_ role: MailboxRole) -> Mailbox? { folders.first { $0.role == role } }

    private func message(from item: IMAPFetchItem, mailbox: String) -> MailMessage? {
        guard let uid = item.uid, let envelope = item.envelope else { return nil }
        let headerBytes = item.sections.first { $0.key.hasPrefix("HEADER.FIELDS") }?.value ?? []
        let headers = MIMEHeaders.parse(String(decoding: headerBytes, as: UTF8.self))
        return MailMessage(
            id: "\(mailbox)/\(uid)",
            mailboxID: mailbox,
            messageID: envelope.messageID,
            inReplyTo: envelope.inReplyTo,
            references: headers["references"].map(MessageIDs.parse) ?? [],
            from: envelope.from.first ?? EmailAddress(address: "unknown@unknown"),
            to: envelope.to,
            cc: envelope.cc,
            subject: envelope.subject,
            date: envelope.date ?? item.internalDate ?? .distantPast,
            flags: item.flags,
            hasAttachments: item.bodyStructureHasAttachment,
            listHeaders: InboxSplit.compact(headers.fields)
        )
    }

    static func uid(of message: MailMessage) -> Int? {
        uid(of: message.id)
    }

    static func serverFilesSent(_ host: String) -> Bool {
        let lower = host.lowercased()
        return ["gmail.com", "googlemail.com", "office365.com", "outlook.com", "hotmail.com"].contains { lower.hasSuffix($0) }
    }
}

/// One request for previews: a part number and how many bytes of it.
private struct PreviewRequest: Hashable {
    var section: String
    var bytes: Int
}

/// What one folder held at the last refresh.
struct IMAPFolderSync: Sendable, Codable, Equatable {
    var uidValidity: Int
    /// HIGHESTMODSEQ (RFC 7162); nil when the server keeps none.
    var highestModSeq: Int?
    var uidNext: Int?
    /// How many messages the folder held.
    var exists: Int
    /// The newest `window` messages, by UID.
    var messages: [Int: MailMessage]
    /// The most messages any caller asked for.
    var window: Int

    /// Applies new flags from a FETCH.
    mutating func update(_ item: IMAPFetchItem) {
        guard let uid = item.uid, item.hasFlags else { return }
        messages[uid]?.flags = item.flags
    }

    /// Takes the UIDs still in the folder from `lowest` up: drops known ones that are gone
    /// and returns those above `highest`, which are new.
    mutating func reconcile(with present: [Int], above highest: Int) -> Set<Int> {
        let present = Set(present)
        messages = messages.filter { present.contains($0.key) }
        return present.filter { $0 > highest }
    }

    /// Keeps only the newest `window` messages.
    mutating func trim() {
        guard messages.count > window else { return }
        for uid in messages.keys.sorted().prefix(messages.count - window) { messages[uid] = nil }
    }
}
