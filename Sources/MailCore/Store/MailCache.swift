import Foundation
import SQLite3

/// Mail kept on this device: folders, recent conversations, message bodies, and a
/// full-text index over all of it. The app opens with what's here and works offline;
/// servers are asked for anything newer or older.
public actor MailCache {
    /// Opened once in `init` and closed in `deinit`; SQLite is in serialized (full mutex) mode.
    nonisolated(unsafe) private let db: OpaquePointer?
    /// Attachments larger than this are listed but fetched again when opened.
    static let keepAttachmentBytes = 2 * 1024 * 1024

    /// `nil` keeps everything in memory (previews and tests).
    public init(url: URL?) {
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(url?.path ?? ":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        db = opened == SQLITE_OK ? handle : nil
        Self.run(db, """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS messages (
            account TEXT NOT NULL, id TEXT NOT NULL, mailbox TEXT, date REAL, json BLOB NOT NULL, body BLOB,
            PRIMARY KEY (account, id));
        CREATE INDEX IF NOT EXISTS messages_by_mailbox ON messages (account, mailbox, date DESC);
        CREATE TABLE IF NOT EXISTS mailboxes (account TEXT PRIMARY KEY, json BLOB NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
            account UNINDEXED, id UNINDEXED, subject, people, body, tokenize = 'unicode61 remove_diacritics 2');
        """)
    }

    deinit { sqlite3_close(db) }

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

    /// Replaces what's known to be in a folder with the latest snapshot. Messages that
    /// left the folder stay searchable but no longer show in it.
    public func saveThreads(_ threads: [MailThread], account: UUID, mailbox: String) {
        let messages = threads.flatMap(\.messages)
        transaction {
            execute("UPDATE messages SET mailbox = NULL WHERE account = ? AND mailbox = ?", [.text(account.uuidString), .text(mailbox)])
            for message in messages {
                var light = message
                light.body = nil
                guard let json = try? JSONEncoder().encode(light) else { continue }
                execute("""
                INSERT INTO messages (account, id, mailbox, date, json) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (account, id) DO UPDATE SET mailbox = excluded.mailbox, date = excluded.date, json = excluded.json
                """, [.text(account.uuidString), .text(message.id), .text(mailbox), .real(message.date.timeIntervalSince1970), .blob(json)])
                index(message, account: account, body: nil)
            }
        }
    }

    public func threads(account: UUID, mailbox: String, limit: Int = 200) -> [MailThread] {
        let messages = query("SELECT json, body FROM messages WHERE account = ? AND mailbox = ? ORDER BY date DESC LIMIT ?",
                             [.text(account.uuidString), .text(mailbox), .int(limit * 3)], Self.message)
        return Threader.threads(from: messages.compactMap { $0 }).sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    public func saveBody(_ body: MessageBody, of message: MailMessage, account: UUID) {
        var kept = body
        kept.attachments = kept.attachments.map { attachment in
            var copy = attachment
            if (copy.data?.count ?? 0) > Self.keepAttachmentBytes { copy.data = nil }
            return copy
        }
        guard let json = try? JSONEncoder().encode(kept) else { return }
        execute("UPDATE messages SET body = ? WHERE account = ? AND id = ?", [.blob(json), .text(account.uuidString), .text(message.id)])
        index(message, account: account, body: body.text)
    }

    public func body(of messageID: String, account: UUID) -> MessageBody? {
        query("SELECT body FROM messages WHERE account = ? AND id = ?", [.text(account.uuidString), .text(messageID)]) { row in
            row.blob(0).flatMap { try? JSONDecoder().decode(MessageBody.self, from: $0) }
        }.first ?? nil
    }

    // MARK: Search

    /// Full-text search over everything kept here: subjects, people, and bodies once read.
    /// Every word must match; the last one may be a prefix ("lisb" finds Lisbon).
    /// `anyWord`: match conversations with any of the words, best matches first (for
    /// questions, where not every word appears).
    public func search(_ text: String, limit: Int = 100, anyWord: Bool = false) -> [(account: UUID, message: MailMessage)] {
        guard let match = anyWord ? Self.ftsAnyQuery(text) : Self.ftsQuery(text) else { return [] }
        let rows = query("""
        SELECT m.account, m.json, m.body FROM search s JOIN messages m ON m.account = s.account AND m.id = s.id
        WHERE search MATCH ? ORDER BY bm25(search), m.date DESC LIMIT ?
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
    public func people(matching text: String, limit: Int = 12) -> [EmailAddress] {
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let word = typed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
        guard word.count >= 2 else { return [] }
        let rows = query("""
        SELECT m.json, NULL FROM search s JOIN messages m ON m.account = s.account AND m.id = s.id
        WHERE search MATCH ? ORDER BY m.date DESC LIMIT 400
        """, [.text("people : \"\(word.replacingOccurrences(of: "\"", with: ""))\"*")], Self.message)
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
    public func correspondents(of me: Set<String>) -> Set<String> {
        guard !me.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: me.count).joined(separator: ", ")
        let sql = """
            SELECT lower(json_extract(person.value, '$.address')) FROM messages,
                json_each(CAST(messages.json AS TEXT), '$.to') AS person
            WHERE lower(json_extract(CAST(messages.json AS TEXT), '$.from.address')) IN (\(marks))
            UNION
            SELECT lower(json_extract(person.value, '$.address')) FROM messages,
                json_each(CAST(messages.json AS TEXT), '$.cc') AS person
            WHERE lower(json_extract(CAST(messages.json AS TEXT), '$.from.address')) IN (\(marks))
            """
        let values = me.sorted().map(Value.text)
        return Set(query(sql, values + values) { $0.text(0) }.compactMap { $0 })
    }

    public func removeAccount(_ account: UUID) {
        for table in ["messages", "mailboxes", "search"] {
            execute("DELETE FROM \(table) WHERE account = ?", [.text(account.uuidString)])
        }
    }

    // MARK: SQLite

    private func index(_ message: MailMessage, account: UUID, body: String?) {
        let people = ([message.from] + message.to + message.cc).map { "\($0.displayName) \($0.address)" }.joined(separator: " ")
        let text = body ?? query("SELECT body FROM search WHERE account = ? AND id = ?", [.text(account.uuidString), .text(message.id)]) {
            $0.text(0)
        }.first ?? message.snippet
        execute("DELETE FROM search WHERE account = ? AND id = ?", [.text(account.uuidString), .text(message.id)])
        execute("INSERT INTO search (account, id, subject, people, body) VALUES (?, ?, ?, ?, ?)",
                [.text(account.uuidString), .text(message.id), .text(message.subject), .text(people), .text(text ?? "")])
    }

    private static func message(_ row: Row) -> MailMessage? {
        guard let json = row.blob(0), var message = try? JSONDecoder().decode(MailMessage.self, from: json) else { return nil }
        message.body = row.blob(1).flatMap { try? JSONDecoder().decode(MessageBody.self, from: $0) }
        return message
    }

    enum Value { case text(String), blob(Data), real(Double), int(Int) }

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func blob(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
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
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func query<T>(_ sql: String, _ values: [Value], _ map: (Row) -> T) -> [T] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { results.append(map(Row(statement: statement))) }
        return results
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .int(let number): sqlite3_bind_int64(statement, index, Int64(number))
            }
        }
        return statement
    }

    private static func run(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
