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
    /// What each folder held at the last refresh, by mailbox name.
    private var sync: [String: IMAPFolderSync] = [:]
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// The parts of a message a list needs: no body.
    static let listItems = "(UID FLAGS ENVELOPE RFC822.SIZE INTERNALDATE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (LIST-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST PRECEDENCE REFERENCES AUTO-SUBMITTED FEEDBACK-ID X-CSA-COMPLAINTS X-MAILGUN-SID X-SES-OUTGOING X-SG-EID X-MC-USER X-MS-REACTIONS)])"

    public init(account: MailAccount, credentials: any CredentialSource) throws {
        guard case .imap(let incoming, let outgoing) = account.connection else {
            throw MailError.notSupported(String(localized: "Not an IMAP account."))
        }
        self.account = account
        self.incoming = incoming
        self.outgoing = outgoing
        self.credentials = credentials
    }

    public func mailboxes() async throws -> [Mailbox] {
        let client = try await connected()
        let items = try await client.list().filter(\.isSelectable)
        let names = Set(items.map(\.name))
        folders = items.map { item in
            // Folders inside others show their own name, nested under the parent.
            let parent = item.parent.flatMap { names.contains($0) ? $0 : nil }
            return Mailbox(id: item.name, name: ModifiedUTF7.decode(parent == nil ? item.name : item.shortName), role: item.role, parentID: parent)
        }
        return folders
    }

    /// The newest `limit` messages, threaded. The first visit to a folder fetches them all;
    /// later ones fetch only what changed (see `refresh`).
    public func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] {
        try await exclusive {
            let client = try await self.connected()
            let state = try await self.refresh(mailbox.id, limit: limit, client: client)
            let newest = state.messages.keys.sorted(by: >).prefix(max(0, limit)).compactMap { state.messages[$0] }
            return Threader.threads(from: newest).sorted { $0.date > $1.date }
        }
    }

    public func body(of message: MailMessage) async throws -> MessageBody {
        try await exclusive { try await self.fetchBody(of: message) }
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

    public func rawSource(of message: MailMessage) async throws -> Data {
        try await exclusive {
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

    public func perform(_ action: MailAction, on threads: [MailThread]) async throws {
        try await exclusive { try await self.apply(action, on: threads) }
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
            try? await connected().append(to: sent.id, message: message)
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
        return try await exclusive { try await self.searchServer(criteria, limit: limit) }
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

    public func createMailbox(named name: String) async throws {
        try await connected().create(name)
        _ = try await mailboxes()
    }

    public func renameMailbox(_ mailbox: Mailbox, to name: String) async throws {
        try await exclusive {
            try await self.connected().rename(mailbox.id, to: name)
            self.sync[mailbox.id] = nil
        }
        _ = try await mailboxes()
    }

    public func deleteMailbox(_ mailbox: Mailbox) async throws {
        try await exclusive {
            try await self.connected().delete(mailbox.id)
            self.sync[mailbox.id] = nil
        }
        _ = try await mailboxes()
    }

    /// Appends the message to Drafts with the \Draft flag (RFC 9051 §6.3.12).
    public func saveDraft(_ draft: Draft) async throws {
        guard let drafts = folder(.drafts) else { throw MailError.notSupported(String(localized: "This account has no Drafts folder.")) }
        try await connected().append(to: drafts.id, message: MessageBuilder.build(draft), flags: "(\\Seen \\Draft)")
    }

    public func disconnect() async {
        await client?.logout()
        client = nil
        await watcher?.logout()
        watcher = nil
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
                fresh = try await state.reconcile(with: client.uidSearch("UID \(lowest):*"), above: highest)
                if current != old, !state.messages.isEmpty {
                    for item in try await client.fetch(known, "(UID FLAGS) (CHANGEDSINCE \(old))", byUID: true) { state.update(item) }
                }
            }
        } else {
            let unchanged = selection.exists == state.exists && selection.uidNext != nil && selection.uidNext == state.uidNext
            if !unchanged {
                fresh = try await state.reconcile(with: client.uidSearch("UID \(lowest):*"), above: highest)
            }
            if !state.messages.isEmpty {
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
            await add(try await client.fetch("\(first):\(selection.exists)", Self.listItems), to: &state, mailbox: name, client: client)
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
        // Previews: the start of each message's text, one request per kind of part. IMAP's list
        // has no preview of its own. A failure only leaves previews empty.
        for (part, uids) in Dictionary(grouping: parts.keys, by: { parts[$0]! }) {
            let section = "BODY.PEEK[\(part.section)]<0.\(part.previewBytes)>"
            guard let fetched = try? await client.fetch(IMAPClient.set(uids.sorted()), "(UID \(section))", byUID: true) else { continue }
            for item in fetched {
                guard let uid = item.uid, let bytes = item.sections[part.section] else { continue }
                state.messages[uid]?.snippet = part.preview(from: bytes)
            }
        }
    }

    /// Runs one folder operation at a time: each SELECTs, and interleaving would read the
    /// wrong folder and corrupt what's remembered.
    private func exclusive<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if isBusy { await withCheckedContinuation { waiting.append($0) } }
        isBusy = true
        defer {
            if waiting.isEmpty { isBusy = false } else { waiting.removeFirst().resume() }
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
        let client = try await signedIn(readTimeout: 30)
        // Must come before the first SELECT.
        await client.enableQResync()
        self.client = client
        if folders.isEmpty { _ = try await mailboxes() }
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
            } catch let MailError.authenticationFailed(detail) where Self.isPassing(detail) && attempt < 3 {
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
        let client = try IMAPClient(endpoint: incoming, readTimeout: readTimeout)
        try await client.open(security: incoming.security)
        do {
            switch account.auth {
            case .password(let username):
                try await client.login(username: username, password: try await credentials.secret(for: account))
            case .oauth(_, let username):
                try await client.authenticate(username: username, accessToken: try await credentials.secret(for: account))
            case .token:
                throw MailError.notSupported(String(localized: "IMAP needs a password or a sign-in."))
            }
        } catch {
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
            listHeaders: headers.fields
        )
    }

    static func uid(of message: MailMessage) -> Int? {
        message.id.split(separator: "/").last.flatMap { Int($0) }
    }

    static func serverFilesSent(_ host: String) -> Bool {
        let lower = host.lowercased()
        return ["gmail.com", "googlemail.com", "office365.com", "outlook.com", "hotmail.com"].contains { lower.hasSuffix($0) }
    }
}

/// What one folder held at the last refresh.
struct IMAPFolderSync: Sendable {
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
