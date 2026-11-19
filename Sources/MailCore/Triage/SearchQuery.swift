import Foundation

/// A search typed in the search field: free words plus operators.
/// `from:maya is:unread has:attachment after:2026/01/01 in:sent "launch plan"`
public struct SearchQuery: Equatable, Sendable {
    public var words: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var subject: [String] = []
    public var isUnread: Bool?
    public var isStarred: Bool?
    public var hasAttachment = false
    public var split: InboxSplit?

    /// Whether what was typed reads as a question for the assistant rather than words to find:
    /// it ends in a question mark, or runs to five words or more, and uses no search operators
    /// (`from:`, `is:`…). Its words aren't read, so it works the same in every language.
    public static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, !words.contains(where: { $0.contains(":") }) else { return false }
        return trimmed.hasSuffix("?") || trimmed.hasSuffix("？") || words.count >= 5
    }

    /// Mail on or after this moment (`after:`, `newer_than:`).
    public var after: Date?
    /// Mail before this moment (`before:`, `older_than:`).
    public var before: Date?
    /// `in:` naming a folder rather than a part of the inbox: a standard one (`inbox`, `sent`,
    /// `drafts`, `archive`, `trash`, `spam`) or one of the person's own, by name.
    public var mailbox: String?

    /// Reads typed text. Operators are a fixed syntax in every language; anything that isn't
    /// one stays a word to find. Dates are read against `now` in `calendar`.
    public init(_ text: String, now: Date = Date(), calendar: Calendar = .current) {
        for token in Self.tokens(text) {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else {
                words.append(token.lowercased())
                continue
            }
            let value = parts[1].lowercased()
            switch parts[0].lowercased() {
            case "from": from.append(value)
            case "to", "cc": to.append(value)
            case "subject": subject.append(value)
            case "is":
                switch value {
                case "unread": isUnread = true
                case "read": isUnread = false
                case "starred", "flagged": isStarred = true
                case "unstarred", "unflagged": isStarred = false
                default: words.append(token.lowercased())
                }
            case "has" where value.hasPrefix("attachment"): hasAttachment = true
            case "in":
                if let part = InboxSplit(rawValue: value) {
                    split = part
                } else if value == "starred" || value == "flagged" {
                    isStarred = true
                } else if !["all", "anywhere"].contains(value) {
                    mailbox = value
                }
            case "after", "since":
                if let day = Self.day(value, calendar: calendar) { after = day } else { words.append(token.lowercased()) }
            case "before":
                if let day = Self.day(value, calendar: calendar) { before = day } else { words.append(token.lowercased()) }
            case "older_than", "older":
                if let moment = Self.ago(value, from: now, calendar: calendar) { before = moment } else { words.append(token.lowercased()) }
            case "newer_than", "newer":
                if let moment = Self.ago(value, from: now, calendar: calendar) { after = moment } else { words.append(token.lowercased()) }
            default: words.append(token.lowercased())
            }
        }
    }

    public var isEmpty: Bool { self == SearchQuery("") }

    /// The standard folder an `in:` names, if it names one.
    public var mailboxRole: MailboxRole? {
        guard let mailbox else { return nil }
        return Self.roles[mailbox]
    }

    static let roles: [String: MailboxRole] = [
        "inbox": .inbox, "sent": .sent, "drafts": .drafts, "draft": .drafts, "archive": .archive,
        "trash": .trash, "bin": .trash, "spam": .junk, "junk": .junk,
    ]

    /// The folder `in:` points at among an account's folders: a standard one by role (Archive
    /// falls back to All Mail), else one of the person's own by name, or by its path's last
    /// part. Nil when there's no `in:`, or no folder by that name.
    public func mailbox(in boxes: [Mailbox]) -> Mailbox? {
        guard let mailbox else { return nil }
        if let role = mailboxRole {
            return boxes.first { $0.role == role } ?? (role == .archive ? boxes.first { $0.role == .all } : nil)
        }
        return boxes.first { $0.name.lowercased() == mailbox || $0.id.lowercased() == mailbox }
            ?? boxes.first { box in
                let last = box.id.split(whereSeparator: { "/.".contains($0) }).last.map { $0.lowercased() }
                return last == mailbox
            }
    }

    /// What saved mail is searched for before the operators narrow it down: the words, and the
    /// people and subjects named, so `from:maya` alone still finds Maya's mail.
    public var savedMailTerms: String {
        (words + from + to + subject).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// Whether the thread fits, leaving `in:<folder>` out (no folders to look it up in).
    public func matches(_ thread: MailThread) -> Bool { matches(thread, in: []) }

    /// Whether the thread fits. `boxes` are its account's folders, for `in:`; a folder that
    /// isn't found there doesn't narrow anything.
    public func matches(_ thread: MailThread, in boxes: [Mailbox]) -> Bool {
        if let isUnread, thread.isUnread != isUnread { return false }
        if let isStarred, thread.isStarred != isStarred { return false }
        if hasAttachment && !thread.hasAttachments { return false }
        if let split, thread.split != split { return false }
        if after != nil || before != nil {
            let fits = thread.messages.contains { message in
                (after.map { message.date >= $0 } ?? true) && (before.map { message.date < $0 } ?? true)
            }
            if !fits { return false }
        }
        if let folder = mailbox(in: boxes), !thread.messages.contains(where: { $0.mailboxID == folder.id }) { return false }
        let senders = thread.messages.map { "\($0.from.displayName) \($0.from.address)".lowercased() }
        if !from.allSatisfy({ term in senders.contains { $0.contains(term) } }) { return false }
        let recipients = thread.messages.flatMap { $0.to + $0.cc }.map { "\($0.displayName) \($0.address)".lowercased() }
        if !to.allSatisfy({ term in recipients.contains { $0.contains(term) } }) { return false }
        let subjectText = thread.subject.lowercased()
        if !subject.allSatisfy(subjectText.contains) { return false }
        let haystack = ([subjectText] + senders + recipients + thread.messages.map { ($0.body?.text ?? $0.snippet).lowercased() })
            .joined(separator: "\n")
        return words.allSatisfy(haystack.contains)
    }

    /// `2026/03/14`, `2026-03-14` or `2026/3/4`: the start of that day.
    static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 999, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }

    /// `7d`, `2w`, `3m` or `1y` before `now`.
    static func ago(_ text: String, from now: Date, calendar: Calendar) -> Date? {
        guard let unit = text.last, let count = Int(text.dropLast()), count >= 0 else { return nil }
        let component: Calendar.Component
        var amount = count
        switch unit {
        case "d": component = .day
        case "w": component = .day; amount = count * 7
        case "m": component = .month
        case "y": component = .year
        default: return nil
        }
        return calendar.date(byAdding: component, value: -amount, to: now)
    }

    /// Splits on spaces, keeping "quoted phrases" (and `from:"Maya L"`) together.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for char in text {
            if char == "\"" { inQuotes.toggle(); continue }
            if char == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
