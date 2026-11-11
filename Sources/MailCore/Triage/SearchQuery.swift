import Foundation

/// A search typed in the search field: free words plus operators.
/// `from:maya is:unread has:attachment "launch plan"`
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
    /// it ends in "?", or starts with a question word, has at least three words, and uses no
    /// search operators (`from:`, `is:`…). "when is my flight to lisbon" → yes; "lisbon flight" → no.
    public static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, !words.contains(where: { $0.contains(":") }) else { return false }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return true }
        let first = words[0].lowercased().trimmingCharacters(in: .punctuationCharacters)
        let firstTwo = words.prefix(2).joined(separator: " ").lowercased()
        return questionWords.contains(first) || questionWords.contains(firstTwo)
    }

    /// Words that start a question in English and the app's other main languages.
    static let questionWords: Set<String> = [
        // English
        "what", "when", "where", "who", "whom", "whose", "why", "how", "which", "did", "do", "does",
        "is", "are", "was", "were", "can", "could", "should", "has", "have", "will", "would", "summarize", "find me",
        // Dutch
        "wat", "wanneer", "waar", "wie", "waarom", "hoe", "welke", "welk", "heb", "heeft", "is er", "kan", "moet",
        // German
        "was", "wann", "wo", "wer", "warum", "wie", "welche", "welcher", "hat", "habe", "gibt es",
        // French
        "quoi", "quand", "où", "qui", "pourquoi", "comment", "quel", "quelle", "est-ce",
        // Spanish and Portuguese
        "qué", "que", "cuándo", "quando", "dónde", "onde", "quién", "quem", "por qué", "cómo", "como", "cuál", "qual",
        // Italian
        "cosa", "chi", "perché", "dove", "quale",
    ]

    public init(_ text: String) {
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
                default: words.append(token.lowercased())
                }
            case "has" where value.hasPrefix("attachment"): hasAttachment = true
            case "in": split = InboxSplit(rawValue: value)
            default: words.append(token.lowercased())
            }
        }
    }

    public var isEmpty: Bool { self == SearchQuery("") }

    public func matches(_ thread: MailThread) -> Bool {
        if let isUnread, thread.isUnread != isUnread { return false }
        if let isStarred, thread.isStarred != isStarred { return false }
        if hasAttachment && !thread.hasAttachments { return false }
        if let split, thread.split != split { return false }
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
