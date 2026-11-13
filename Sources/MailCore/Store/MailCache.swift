import Foundation
import SQLite3

/// Mail kept on this device: folders, recent conversations, message bodies, and a
/// full-text index over all of it. The app opens with what's here and works offline;
/// servers are asked for anything newer or older.
///
/// Everything here is looked up through an index, and a refresh writes only what changed, so
/// it costs the same whether a hundred messages are saved or a million: each message has a
/// row number (`n`) that is also its row in the full-text index, and a `mark` that says what
/// was last written for it.
public actor MailCache {
    /// Opened once in `init` and closed in `deinit`; SQLite is in serialized (full mutex) mode.
    nonisolated(unsafe) private let db: OpaquePointer?
    /// Statements compiled once and used again (a refresh runs the same few hundreds of times).
    private let statements = Statements()
    /// Attachments larger than this are listed but fetched again when opened.
    static let keepAttachmentBytes = 2 * 1024 * 1024
    /// How many message rows have been written since this was opened (for tests and the
    /// benchmark: a refresh that brings nothing new writes none).
    public private(set) var rowsWritten = 0
    /// The layout of the file; see `prepare(_:)`.
    static let version = 1

    /// `nil` keeps everything in memory (previews and tests).
    public init(url: URL?) {
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(url?.path ?? ":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        db = opened == SQLITE_OK ? handle : nil
        self.url = url
        Self.prepare(db)
        Self.keepOutOfBackups(url)
    }

    private let url: URL?

    /// Everything here can be downloaded again, and with older mail saved it can grow to
    /// gigabytes: it isn't part of the device's iCloud or computer backups.
    nonisolated static func keepOutOfBackups(_ url: URL?) {
        guard let url else { return }
        for suffix in ["", "-wal", "-shm"] {
            var file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
        }
    }

    deinit {
        statements.finalizeAll()
        sqlite3_close(db)
    }

    /// Creates the tables, or brings a file from before row numbers up to date: its messages
    /// are copied into the new table and the full-text index is filled again from the old one,
    /// in one transaction (a few milliseconds per thousand messages, once).
    private static func prepare(_ db: OpaquePointer?) {
        run(db, "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        let tables = """
        CREATE TABLE IF NOT EXISTS messages (
            n INTEGER PRIMARY KEY, account TEXT NOT NULL, id TEXT NOT NULL, mailbox TEXT, date REAL,
            mark INTEGER, json BLOB NOT NULL, body BLOB, UNIQUE (account, id));
        CREATE INDEX IF NOT EXISTS messages_by_mailbox ON messages (account, mailbox, date DESC);
        CREATE INDEX IF NOT EXISTS messages_by_date ON messages (date);
        CREATE TABLE IF NOT EXISTS mailboxes (account TEXT PRIMARY KEY, json BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS downloads (
            account TEXT NOT NULL, mailbox TEXT NOT NULL, position TEXT, validity TEXT, done TEXT, checked REAL, token TEXT,
            PRIMARY KEY (account, mailbox)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS written (
            sender TEXT NOT NULL, person TEXT NOT NULL, account TEXT NOT NULL, PRIMARY KEY (sender, person, account)) WITHOUT ROWID;
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
            subject, people, body, tokenize = 'unicode61 remove_diacritics 2');
        """
        let hasOldMessages = scalar(db, "SELECT count(*) FROM pragma_table_info('messages')") > 0
            && scalar(db, "SELECT count(*) FROM pragma_table_info('messages') WHERE name = 'n'") == 0
        guard hasOldMessages else {
            run(db, tables + "PRAGMA user_version = \(version);")
            return
        }
        run(db, """
        BEGIN;
        ALTER TABLE messages RENAME TO messages_before;
        DROP INDEX IF EXISTS messages_by_mailbox;
        ALTER TABLE search RENAME TO search_before;
        \(tables)
        INSERT INTO messages (account, id, mailbox, date, json, body)
            SELECT account, id, mailbox, date, json, body FROM messages_before;
        INSERT OR IGNORE INTO written (sender, person, account)
            SELECT lower(json_extract(CAST(m.json AS TEXT), '$.from.address')), lower(json_extract(person.value, '$.address')), m.account
            FROM messages m, json_each(CAST(m.json AS TEXT), '$.to') AS person
            WHERE json_extract(CAST(m.json AS TEXT), '$.from.address') IS NOT NULL AND json_extract(person.value, '$.address') IS NOT NULL;
        INSERT OR IGNORE INTO written (sender, person, account)
            SELECT lower(json_extract(CAST(m.json AS TEXT), '$.from.address')), lower(json_extract(person.value, '$.address')), m.account
            FROM messages m, json_each(CAST(m.json AS TEXT), '$.cc') AS person
            WHERE json_extract(CAST(m.json AS TEXT), '$.from.address') IS NOT NULL AND json_extract(person.value, '$.address') IS NOT NULL;
        INSERT OR REPLACE INTO search (rowid, subject, people, body)
            SELECT m.n, s.subject, s.people, s.body FROM search_before s JOIN messages m ON m.account = s.account AND m.id = s.id;
        DROP TABLE messages_before;
        DROP TABLE search_before;
        PRAGMA user_version = \(version);
        COMMIT;
        """)
    }

    // MARK: Folders

    public func saveMailboxes(_ mailboxes: [Mailbox], account: UUID) {
        guard let json = try? JSONEncoder().encode(mailboxes) else { return }
        execute("INSERT OR REPLACE INTO mailboxes (account, json) VALUES (?, ?)", [.text(account.uuidString), .blob(json)])
    }

    public func mailboxes(account: UUID) -> [Mailbox]? {
        query("SELECT json FROM mailboxes WHERE account = ?", [.text(account.uuidString)]) { row in
            row.blob(0).flatMap { try? JSONDecoder().decode([Mailbox].self, from: $0) }
        }.first ?? nil
    }

    // MARK: Conversations

    /// Takes in the newest conversations of a folder as the server has them now. Only what
    /// changed is written: a message that's new, or whose flags or preview differ from what
    /// was saved. Messages that left the folder stay searchable but no longer show in it.
    ///
    /// `limit` is how many were asked for. When that many came back, older mail may exist that
    /// this snapshot doesn't cover, so saved messages older than its oldest are left alone
    /// (they were saved when the list was scrolled that far). With fewer, or no limit, the
    /// snapshot is the whole folder.
    public func saveThreads(_ threads: [MailThread], account: UUID, mailbox: String, limit: Int? = nil) {
        let messages = threads.flatMap(\.messages)
        let isWhole = limit.map { threads.count < $0 && messages.count < $0 } ?? true
        write(messages, account: account, mailbox: mailbox, replacing: isWhole ? .everything : .from(messages.map(\.date.timeIntervalSince1970).min()))
    }

    /// Adds conversations to what's saved for a folder without saying anything about the rest
    /// of it: a page of older mail.
    public func addThreads(_ threads: [MailThread], account: UUID, mailbox: String) {
        write(threads.flatMap(\.messages), account: account, mailbox: mailbox, replacing: .nothing)
    }

    /// Which saved messages of the folder a snapshot stands in for: those not in it have left.
    private enum Replacing {
        case nothing, everything
        case from(Double?)
    }

    private func write(_ messages: [MailMessage], account: UUID, mailbox: String, replacing: Replacing) {
        let owner = account.uuidString
        transaction {
            // What the folder was known to hold over the stretch this snapshot covers.
            var known = Set<String>()
            let isWhole: Bool, oldest: Double?
            switch replacing {
            case .nothing: isWhole = false; oldest = nil
            case .everything: isWhole = true; oldest = nil
            case .from(let date): isWhole = date == nil; oldest = date
            }
            if case .nothing = replacing {
            } else if isWhole {
                known = Set(query("SELECT id FROM messages WHERE account = ? AND mailbox = ?", [.text(owner), .text(mailbox)]) { $0.text(0) }.compactMap { $0 })
            } else if let oldest {
                known = Set(query("SELECT id FROM messages WHERE account = ? AND mailbox = ? AND date >= ?",
                                  [.text(owner), .text(mailbox), .real(oldest)]) { $0.text(0) }.compactMap { $0 })
            }
            let encoder = JSONEncoder()
            for message in messages {
                known.remove(message.id)
                let mark = Self.mark(of: message, in: mailbox)
                let saved = query("SELECT n, mark FROM messages WHERE account = ? AND id = ?", [.text(owner), .text(message.id)]) {
                    (n: $0.int(0), mark: $0.isNull(1) ? nil : Optional($0.int(1)))
                }.first
                if let saved, saved.mark == mark { continue }
                rowsWritten += 1
                var light = message
                light.body = nil
                guard let json = try? encoder.encode(light) else { continue }
                let date = message.date.timeIntervalSince1970
                if let saved {
                    execute("UPDATE messages SET mailbox = ?, date = ?, mark = ?, json = ? WHERE n = ?",
                            [.text(mailbox), .real(date), .int(mark), .blob(json), .int(saved.n)])
                    // Its place in the search index is from when it was first saved; a message's
                    // subject and people don't change, and its text is indexed by `saveBody`.
                    if saved.mark == nil, !hasSearchRow(saved.n) { index(message, row: saved.n, body: nil) }
                } else {
                    execute("INSERT INTO messages (account, id, mailbox, date, mark, json) VALUES (?, ?, ?, ?, ?, ?)",
                            [.text(owner), .text(message.id), .text(mailbox), .real(date), .int(mark), .blob(json)])
                    index(message, row: Int(sqlite3_last_insert_rowid(db)), body: nil)
                    // Who wrote to whom, so "people you've written to" is a lookup.
                    let sender = message.from.address.lowercased()
                    for person in message.to + message.cc {
                        execute("INSERT OR IGNORE INTO written (sender, person, account) VALUES (?, ?, ?)",
                                [.text(sender), .text(person.address.lowercased()), .text(owner)])
                    }
                }
            }
            for id in known {
                rowsWritten += 1
                execute("UPDATE messages SET mailbox = NULL, mark = NULL WHERE account = ? AND id = ?", [.text(owner), .text(id)])
            }
        }
    }

    /// The newest saved conversations of a folder; with `before`, the newest ones older than
    /// that (the next page as the list is scrolled).
    ///
    /// The rows are read here and unpacked by the caller's own task, so several folders (every
    /// mailbox's inbox at launch) are unpacked side by side instead of one after another.
    /// `bodies` false leaves the saved texts where they are: a list doesn't need them, and
    /// `body(of:)` reads one when its mail is opened.
    nonisolated public func threads(account: UUID, mailbox: String, limit: Int = 200, before: Date? = nil, bodies: Bool = true) async -> [MailThread] {
        let packed = await rows(account: account, mailbox: mailbox, count: limit * 3, before: before, bodies: bodies)
        let messages = packed.compactMap { Self.unpack(json: $0.json, body: $0.body) }
        return Threader.threads(from: messages).sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    private func rows(account: UUID, mailbox: String, count: Int, before: Date?, bodies: Bool) -> [(json: Data, body: Data?)] {
        let columns = bodies ? "json, body" : "json, NULL"
        func packed(_ row: Row) -> (json: Data, body: Data?)? { row.blob(0).map { ($0, row.blob(1)) } }
        if let before {
            return query("SELECT \(columns) FROM messages WHERE account = ? AND mailbox = ? AND date < ? ORDER BY date DESC LIMIT ?",
                         [.text(account.uuidString), .text(mailbox), .real(before.timeIntervalSince1970), .int(count)], packed).compactMap { $0 }
        }
        return query("SELECT \(columns) FROM messages WHERE account = ? AND mailbox = ? ORDER BY date DESC LIMIT ?",
                     [.text(account.uuidString), .text(mailbox), .int(count)], packed).compactMap { $0 }
    }

    /// How many messages are saved, in one folder or (with nil) in all.
    public func messageCount(account: UUID? = nil, mailbox: String? = nil) -> Int {
        if let account, let mailbox {
            return query("SELECT count(*) FROM messages WHERE account = ? AND mailbox = ?", [.text(account.uuidString), .text(mailbox)]) { $0.int(0) }.first ?? 0
        }
        return query("SELECT count(*) FROM messages", []) { $0.int(0) }.first ?? 0
    }

    public func saveBody(_ body: MessageBody, of message: MailMessage, account: UUID) {
        var kept = body
        kept.attachments = kept.attachments.map { attachment in
            var copy = attachment
            if (copy.data?.count ?? 0) > Self.keepAttachmentBytes { copy.data = nil }
            return copy
        }
        guard let json = try? JSONEncoder().encode(kept),
              let row = query("SELECT n FROM messages WHERE account = ? AND id = ?", [.text(account.uuidString), .text(message.id)], { $0.int(0) }).first
        else { return }
        execute("UPDATE messages SET body = ? WHERE n = ?", [.blob(json), .int(row)])
        index(message, row: row, body: body.text)
    }

    /// Saved messages from every folder since a date whose subject contains one of the words,
    /// oldest first: invitations, also ones moved to Deleted Items once answered, and your replies.
    public func recentMessages(since date: Date, subjectWords: [String], limit: Int = 80) -> [(account: UUID, message: MailMessage)] {
        let words = subjectWords.map { $0.lowercased() }
        let rows = query("SELECT account, json, body FROM messages WHERE date > ? ORDER BY date ASC",
                         [.real(date.timeIntervalSince1970)]) { row -> (UUID, MailMessage)? in
            guard let account = row.text(0).flatMap(UUID.init(uuidString:)),
                  let json = row.blob(1), var message = try? JSONDecoder().decode(MailMessage.self, from: json) else { return nil }
            let subject = message.subject.lowercased()
            guard words.contains(where: subject.contains) else { return nil }
            message.body = row.blob(2).flatMap { try? JSONDecoder().decode(MessageBody.self, from: $0) }
            return (account, message)
        }
        return Array(rows.compactMap { $0 }.suffix(limit))
    }

    /// One saved message.
    public func message(id: String, account: UUID) -> MailMessage? {
        query("SELECT json, body FROM messages WHERE account = ? AND id = ?", [.text(account.uuidString), .text(id)], Self.message)
            .compactMap { $0 }.first
    }

    public func body(of messageID: String, account: UUID) -> MessageBody? {
        query("SELECT body FROM messages WHERE account = ? AND id = ?", [.text(account.uuidString), .text(messageID)]) { row in
            row.blob(0).flatMap { try? JSONDecoder().decode(MessageBody.self, from: $0) }
        }.first ?? nil
    }

    /// Saved messages of an account without a saved text, newest first, from `since` on and
    /// older than `before` (nil: from the newest).
    public func messagesWithoutText(account: UUID, since: Date, before: Date?, limit: Int) -> [MailMessage] {
        let decoder = JSONDecoder()
        return query("SELECT json FROM messages WHERE account = ? AND body IS NULL AND date >= ? AND date < ? ORDER BY date DESC LIMIT ?",
                     [.text(account.uuidString), .real(since.timeIntervalSince1970),
                      .real(before?.timeIntervalSince1970 ?? .greatestFiniteMagnitude), .int(limit)]) { row in
            row.blob(0).flatMap { try? decoder.decode(MailMessage.self, from: $0) }
        }.compactMap { $0 }
    }

    /// How many saved messages have their text saved.
    public func textCount() -> Int {
        query("SELECT COUNT(*) FROM messages WHERE body IS NOT NULL", []) { $0.int(0) }.first ?? 0
    }

    // MARK: Older mail downloaded in the background

    /// How far the background download of one folder has come.
    public struct DownloadProgress: Sendable, Equatable {
        /// Where the next page starts (`OlderMailPage.next`); nil: from the newest.
        public var position: String?
        /// The folder's id validity the position belongs to.
        public var validity: String?
        /// The stretch of mail (a `KeepMail` raw value) this folder was downloaded for in full.
        public var done: String?
        /// When saved mail was last compared with the server, and what to hand back next time.
        public var checked: Date?
        public var token: String?

        public init(position: String? = nil, validity: String? = nil, done: String? = nil, checked: Date? = nil, token: String? = nil) {
            self.position = position
            self.validity = validity
            self.done = done
            self.checked = checked
            self.token = token
        }
    }

    public func downloadProgress(account: UUID, mailbox: String) -> DownloadProgress? {
        query("SELECT position, validity, done, checked, token FROM downloads WHERE account = ? AND mailbox = ?",
              [.text(account.uuidString), .text(mailbox)]) { row in
            DownloadProgress(position: row.text(0), validity: row.text(1), done: row.text(2),
                             checked: row.isNull(3) ? nil : Date(timeIntervalSince1970: row.real(3)), token: row.text(4))
        }.first
    }

    public func saveDownloadProgress(_ progress: DownloadProgress, account: UUID, mailbox: String) {
        func text(_ value: String?) -> Value { value.map(Value.text) ?? .null }
        execute("INSERT OR REPLACE INTO downloads (account, mailbox, position, validity, done, checked, token) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(account.uuidString), .text(mailbox), text(progress.position), text(progress.validity), text(progress.done),
                 progress.checked.map { .real($0.timeIntervalSince1970) } ?? .null, text(progress.token)])
        if !keptOutOfBackups {
            keptOutOfBackups = true
            Self.keepOutOfBackups(url)
        }
    }

    private var keptOutOfBackups = false

    /// The ids of every message saved for a folder (to compare with the server).
    public func savedIDs(account: UUID, mailbox: String) -> [String] {
        query("SELECT id FROM messages WHERE account = ? AND mailbox = ?", [.text(account.uuidString), .text(mailbox)]) { $0.text(0) }.compactMap { $0 }
    }

    /// Puts what the server said about saved mail into it: new flags, moves, and messages that
    /// are gone (taken out, search index included, so deleted mail doesn't turn up in search).
    public func apply(_ check: SavedMailCheck, account: UUID, mailbox: String) {
        let owner = account.uuidString
        transaction {
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            func change(_ id: String, _ edit: (inout MailMessage) -> Void) {
                guard let row = query("SELECT n, json, mailbox FROM messages WHERE account = ? AND id = ?", [.text(owner), .text(id)], { row in
                    (n: row.int(0), json: row.blob(1), mailbox: row.text(2))
                }).first, let json = row.json, var message = try? decoder.decode(MailMessage.self, from: json) else { return }
                let before = message
                edit(&message)
                guard message != before, let data = try? encoder.encode(message) else { return }
                let folder = message.mailboxID == before.mailboxID ? (row.mailbox ?? mailbox) : message.mailboxID
                rowsWritten += 1
                execute("UPDATE messages SET mailbox = ?, mark = ?, json = ? WHERE n = ?",
                        [.text(folder), .int(Self.mark(of: message, in: folder)), .blob(data), .int(row.n)])
            }
            for (id, flags) in check.flags { change(id) { $0.flags = flags } }
            for (id, folder) in check.moved { change(id) { $0.mailboxID = folder } }
            for id in check.gone {
                rowsWritten += 1
                execute("DELETE FROM search WHERE rowid IN (SELECT n FROM messages WHERE account = ? AND id = ? AND mailbox = ?)",
                        [.text(owner), .text(id), .text(mailbox)])
                execute("DELETE FROM messages WHERE account = ? AND id = ? AND mailbox = ?", [.text(owner), .text(id), .text(mailbox)])
            }
        }
    }

    /// How much is saved: messages, and the bytes the file takes.
    public func usage() -> (messages: Int, bytes: Int) {
        let pages = query("PRAGMA page_count", []) { $0.int(0) }.first ?? 0
        let size = query("PRAGMA page_size", []) { $0.int(0) }.first ?? 0
        return (messageCount(), pages * size)
    }

    /// Takes out the older mail downloaded in the background: in each folder it went through,
    /// messages without a saved text below the newest `keepNewest`. What was opened, and the
    /// newest of every folder, stay. The file is then made small again.
    public func clearDownloaded(keepNewest: Int = 500) {
        let folders = query("SELECT account, mailbox FROM downloads", []) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        transaction {
            for (owner, mailbox) in folders {
                let floor = query("SELECT date FROM messages WHERE account = ? AND mailbox = ? ORDER BY date DESC LIMIT 1 OFFSET ?",
                                  [.text(owner), .text(mailbox), .int(keepNewest)]) { $0.real(0) }.first
                guard let floor else { continue }
                execute("DELETE FROM search WHERE rowid IN (SELECT n FROM messages WHERE account = ? AND mailbox = ? AND body IS NULL AND date <= ?)",
                        [.text(owner), .text(mailbox), .real(floor)])
                execute("DELETE FROM messages WHERE account = ? AND mailbox = ? AND body IS NULL AND date <= ?",
                        [.text(owner), .text(mailbox), .real(floor)])
            }
            execute("DELETE FROM downloads", [])
        }
        Self.run(db, "VACUUM")
    }

    // MARK: Search

    /// Full-text search over everything kept here: subjects, people, and bodies once read.
    /// Every word must match; the last one may be a prefix ("lisb" finds Lisbon).
    /// `anyWord`: match conversations with any of the words, best matches first (for
    /// questions, where not every word appears).
    public func search(_ text: String, limit: Int = 100, anyWord: Bool = false) -> [(account: UUID, message: MailMessage)] {
        guard let match = anyWord ? Self.ftsAnyQuery(text) : Self.ftsQuery(text) else { return [] }
        // Best matches first, then newest. With a word that's in tens of thousands of messages,
        // the latest few thousand saved are ranked, not all of them: the time a search takes
        // doesn't grow with how much mail is saved.
        let rows = query("""
        SELECT m.account, m.json, m.body FROM
            (SELECT rowid, bm25(search) AS score FROM search WHERE search MATCH ? ORDER BY rowid DESC LIMIT \(Self.matchesLookedAt)) s
        JOIN messages m ON m.n = s.rowid ORDER BY s.score, m.date DESC LIMIT ?
        """, [.text(match), .int(limit)]) { row -> (UUID, MailMessage)? in
            guard let account = row.text(0).flatMap(UUID.init(uuidString:)),
                  let json = row.blob(1), var message = try? JSONDecoder().decode(MailMessage.self, from: json) else { return nil }
            message.body = row.blob(2).flatMap { try? JSONDecoder().decode(MessageBody.self, from: $0) }
            return (account, message)
        }
        return rows.compactMap { $0 }
    }

    /// Words become quoted FTS terms; the last also matches as a prefix.
    /// People on saved mail in every folder and account (senders and recipients, so Sent
    /// counts too) whose name or address starts with what's typed, most frequent first.
    /// `accounts` limits it to those accounts' mail; nil for all.
    public func people(matching text: String, limit: Int = 12, accounts: Set<UUID>? = nil) -> [EmailAddress] {
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let word = typed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
        guard word.count >= 2 else { return [] }
        if let accounts, accounts.isEmpty { return [] }
        let only = accounts.map { " AND m.account IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
        // At most the latest few thousand matches are looked at, however much mail is saved.
        let rows = query("""
        SELECT m.json, NULL FROM (SELECT rowid FROM search WHERE search MATCH ? ORDER BY rowid DESC LIMIT \(Self.matchesLookedAt)) s
        JOIN messages m ON m.n = s.rowid WHERE 1\(only) ORDER BY m.date DESC LIMIT 400
        """, [.text("people : \"\(word.replacingOccurrences(of: "\"", with: ""))\"*")] + (accounts ?? []).map { .text($0.uuidString) }, Self.message)
        var counts: [String: (person: EmailAddress, count: Int)] = [:]
        for message in rows.compactMap({ $0 }) {
            for person in [message.from] + message.to + message.cc {
                let address = person.address.lowercased()
                let name = person.name?.lowercased() ?? ""
                let matches = address.hasPrefix(typed) || name.hasPrefix(typed)
                    || name.split(separator: " ").contains { $0.hasPrefix(typed) }
                guard matches else { continue }
                let current = counts[address]
                // Keep a version with a name when there is one.
                let best = (current?.person.name?.isEmpty == false) ? current!.person : person
                counts[address] = (best, (current?.count ?? 0) + 1)
            }
        }
        return counts.values.sorted { $0.count > $1.count }.prefix(limit).map(\.person)
    }

    /// Saved mail with this address on it (from, to or cc), newest first, across every folder
    /// and account; one copy per message.
    public func history(with address: String, limit: Int = 200) -> [MailMessage] {
        let target = address.lowercased()
        let words = target.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        let rows = query("""
        SELECT m.json, NULL FROM (SELECT rowid FROM search WHERE search MATCH ? ORDER BY rowid DESC LIMIT \(Self.matchesLookedAt)) s
        JOIN messages m ON m.n = s.rowid ORDER BY m.date DESC LIMIT ?
        """, [.text("people : \"\(words.joined(separator: " "))\""), .int(limit * 3)], Self.message)
        var seen = Set<String>()
        return rows.compactMap { $0 }.filter { message in
            ([message.from] + message.to + message.cc).contains { $0.address.lowercased() == target }
                && seen.insert(message.messageID ?? message.id).inserted
        }.prefix(limit).map { $0 }
    }

    /// How many full-text matches are read at most when the answer is put in date order.
    static let matchesLookedAt = 4_000

    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || ",;:()\"'".contains($0) })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty && !$0.contains(":") }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { index, word in
            index == words.count - 1 ? "\"\(word)\"*" : "\"\(word)\""
        }.joined(separator: " ")
    }

    /// Small words that say nothing about which mail is meant.
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "about", "did", "do", "does", "for", "from", "has", "have", "how", "i", "in", "is", "it",
        "me", "my", "of", "on", "or", "say", "said", "tell", "that", "the", "to", "was", "were", "what", "when", "where",
        "which", "who", "why", "will", "with", "you", "de", "het", "een", "en", "van", "wat", "wie", "waar", "wanneer",
    ]

    static func ftsAnyQuery(_ text: String) -> String? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 && !stopWords.contains($0) }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    /// Everyone written to from one of `me`, in To or Cc, lowercased: who you correspond with.
    /// Noted as each message is saved (`written`), so asking doesn't read any mail.
    public func correspondents(of me: Set<String>) -> Set<String> {
        guard !me.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: me.count).joined(separator: ", ")
        return Set(query("SELECT DISTINCT person FROM written WHERE sender IN (\(marks))", me.sorted().map(Value.text)) { $0.text(0) }.compactMap { $0 })
    }

    /// Every account with anything saved here.
    public func savedAccounts() -> Set<UUID> {
        // Hops from one account to the next through the index instead of reading every row.
        let ids = query("""
        WITH RECURSIVE owners(x) AS (
            SELECT min(account) FROM messages
            UNION ALL SELECT (SELECT min(account) FROM messages WHERE account > owners.x) FROM owners WHERE owners.x IS NOT NULL)
        SELECT x FROM owners WHERE x IS NOT NULL UNION SELECT account FROM mailboxes
        """, []) { $0.text(0) }
        return Set(ids.compactMap { $0.flatMap(UUID.init(uuidString:)) })
    }

    public func removeAccount(_ account: UUID) {
        transaction {
            execute("DELETE FROM downloads WHERE account = ?", [.text(account.uuidString)])
            execute("DELETE FROM search WHERE rowid IN (SELECT n FROM messages WHERE account = ?)", [.text(account.uuidString)])
            execute("DELETE FROM messages WHERE account = ?", [.text(account.uuidString)])
            execute("DELETE FROM written WHERE account = ?", [.text(account.uuidString)])
            execute("DELETE FROM mailboxes WHERE account = ?", [.text(account.uuidString)])
        }
    }

    // MARK: SQLite

    /// Writes a message's row in the full-text index (the same row number as in `messages`).
    /// Without a body, the text already indexed is kept, or its preview is used.
    private func index(_ message: MailMessage, row: Int, body: String?) {
        let people = ([message.from] + message.to + message.cc).map { "\($0.displayName) \($0.address)" }.joined(separator: " ")
        let text = body ?? query("SELECT body FROM search WHERE rowid = ?", [.int(row)]) { $0.text(0) }.first ?? message.snippet
        execute("DELETE FROM search WHERE rowid = ?", [.int(row)])
        execute("INSERT INTO search (rowid, subject, people, body) VALUES (?, ?, ?, ?)",
                [.int(row), .text(message.subject), .text(people), .text(text ?? "")])
    }

    private func hasSearchRow(_ row: Int) -> Bool {
        !query("SELECT rowid FROM search WHERE rowid = ?", [.int(row)]) { $0.int(0) }.isEmpty
    }

    /// A number that changes when anything a list shows about a message does (its flags, its
    /// preview, the folder it's in): what was saved is only written again when this differs.
    static func mark(of message: MailMessage, in mailbox: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func add(_ text: String) {
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            hash = (hash ^ 0xff) &* 0x0000_0100_0000_01b3
        }
        func add(_ number: Int) {
            hash = (hash ^ UInt64(bitPattern: Int64(number))) &* 0x0000_0100_0000_01b3
        }
        add(mailbox); add(message.mailboxID); add(message.subject); add(message.snippet)
        add(message.flags.rawValue); add(Int(message.date.timeIntervalSince1970)); add(message.hasAttachments ? 1 : 0)
        add(message.from.address); add(message.from.name ?? "")
        add(message.to.count); add(message.cc.count); add(message.references.count); add(message.listHeaders.count)
        add(message.messageID ?? ""); add(message.inReplyTo ?? "")
        return Int(Int64(bitPattern: hash))
    }

    private static func message(_ row: Row) -> MailMessage? {
        row.blob(0).flatMap { unpack(json: $0, body: row.blob(1)) }
    }

    private static func unpack(json: Data, body: Data?) -> MailMessage? {
        guard var message = try? JSONDecoder().decode(MailMessage.self, from: json) else { return nil }
        // Previews saved before dividers were tidied away ("------") or HTML was recognised.
        message.snippet = HTMLText.cleanedPreview(message.snippet)
        message.body = body.flatMap { try? JSONDecoder().decode(MessageBody.self, from: $0) }
        return message
    }

    enum Value { case text(String), blob(Data), real(Double), int(Int), null }

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func blob(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    }

    /// Compiled statements by their text. Only touched from inside the actor.
    private final class Statements: @unchecked Sendable {
        var known: [String: OpaquePointer] = [:]
        func finalizeAll() {
            for statement in known.values { sqlite3_finalize(statement) }
            known = [:]
        }
    }

    private func transaction(_ body: () -> Void) {
        execute("BEGIN", [])
        body()
        execute("COMMIT", [])
    }

    @discardableResult
    private func execute(_ sql: String, _ values: [Value]) -> Bool {
        guard let statement = prepare(sql, values) else { return false }
        defer { sqlite3_reset(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func query<T>(_ sql: String, _ values: [Value], _ map: (Row) -> T) -> [T] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_reset(statement) }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { results.append(map(Row(statement: statement))) }
        return results
    }

    /// The compiled statement for this text (compiled the first time), with its values bound.
    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        let statement: OpaquePointer
        if let known = statements.known[sql] {
            statement = known
            sqlite3_clear_bindings(statement)
        } else {
            var made: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &made, nil) == SQLITE_OK, let made else { return nil }
            statements.known[sql] = made
            statement = made
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .int(let number): sqlite3_bind_int64(statement, index, Int64(number))
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private static func run(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func scalar(_ db: OpaquePointer?, _ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }
}
