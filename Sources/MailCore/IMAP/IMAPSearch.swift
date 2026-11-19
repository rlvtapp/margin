import Foundation

/// A typed search (`SearchQuery`) as an IMAP `SEARCH` (RFC 9051 §6.4.4), or as the raw-search
/// extension some servers offer (`X-GM-RAW`, announced as `X-GM-EXT-1`), which reads the same
/// operators the search field does.
///
/// `in:` isn't part of either: it picks which folder is selected. Parts of the inbox
/// (`in:people`) aren't known to any server; they narrow what comes back, on the device.
enum IMAPSearch {
    /// The capability a server announces when it reads `X-GM-RAW`.
    static let rawCapability = "X-GM-EXT-1"

    /// The criteria for `UID SEARCH`, or nil when the query holds text the server can't be sent
    /// (outside ASCII: quoted strings must be 7-bit), or nothing at all.
    ///
    /// There's no standard key for "has an attachment": `has:attachment` asks for a
    /// `multipart/mixed` message, and what comes back is narrowed to real attachments on the
    /// device.
    static func criteria(_ query: SearchQuery, calendar: Calendar = .current) -> String? {
        guard !query.isEmpty else { return nil }
        var keys: [String] = []
        func add(_ key: String, _ value: String) -> Bool {
            guard value.unicodeScalars.allSatisfy(\.isASCII), let quoted = IMAPParser.quoted(value) else { return false }
            keys.append("\(key) \(quoted)")
            return true
        }
        for value in query.from { guard add("FROM", value) else { return nil } }
        for value in query.to {
            guard value.unicodeScalars.allSatisfy(\.isASCII), let quoted = IMAPParser.quoted(value) else { return nil }
            keys.append("OR TO \(quoted) CC \(quoted)")
        }
        for value in query.subject { guard add("SUBJECT", value) else { return nil } }
        if query.hasAttachment { keys.append("HEADER Content-Type \"multipart/mixed\"") }
        if let isUnread = query.isUnread { keys.append(isUnread ? "UNSEEN" : "SEEN") }
        if let isStarred = query.isStarred { keys.append(isStarred ? "FLAGGED" : "UNFLAGGED") }
        if let after = query.after { keys.append("SINCE \(date(after, calendar: calendar))") }
        if let before = query.before { keys.append("BEFORE \(date(before, calendar: calendar))") }
        for word in query.words { guard add("TEXT", word) else { return nil } }
        return keys.isEmpty ? "ALL" : keys.joined(separator: " ")
    }

    /// The query rebuilt in the raw-search syntax, as one `X-GM-RAW` key; nil as for `criteria`.
    /// Rebuilt from the parsed query rather than passed on as typed, so only what the server
    /// understands reaches it.
    static func rawCriteria(_ query: SearchQuery, calendar: Calendar = .current) -> String? {
        guard !query.isEmpty else { return nil }
        let raw = rawText(query, calendar: calendar)
        guard raw.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        guard !raw.isEmpty else { return "ALL" }
        return IMAPParser.quoted(raw).map { "X-GM-RAW \($0)" }
    }

    static func rawText(_ query: SearchQuery, calendar: Calendar = .current) -> String {
        func term(_ value: String) -> String {
            value.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "\"\(value.replacingOccurrences(of: "\"", with: ""))\"" : value
        }
        var parts: [String] = []
        parts += query.from.map { "from:\(term($0))" }
        parts += query.to.map { "to:\(term($0))" }
        parts += query.subject.map { "subject:\(term($0))" }
        if query.hasAttachment { parts.append("has:attachment") }
        if let isUnread = query.isUnread { parts.append(isUnread ? "is:unread" : "is:read") }
        if let isStarred = query.isStarred { parts.append(isStarred ? "is:starred" : "-is:starred") }
        // Seconds since 1970 keep `older_than:` to the moment; whole days would round it.
        if let after = query.after { parts.append("after:\(Int(after.timeIntervalSince1970))") }
        if let before = query.before { parts.append("before:\(Int(before.timeIntervalSince1970))") }
        parts += query.words.map(term)
        return parts.joined(separator: " ")
    }

    /// `14-Mar-2026`: IMAP's date, with its fixed English month names.
    static func date(_ date: Date, calendar: Calendar = .current) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.day ?? 1)-\(months[(parts.month ?? 1) - 1])-\(parts.year ?? 1970)"
    }
}
