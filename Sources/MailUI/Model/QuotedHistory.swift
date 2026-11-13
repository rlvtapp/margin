import Foundation
import MailCore

/// The earlier mail a reply carries along underneath ("On Tuesday, Jodi wrote: …"). In a
/// conversation those messages are already on the page, so the reader folds that part away
/// behind a "···" button, as other mail apps do.
enum QuotedHistory {
    /// The message's HTML up to where the quoted mail begins, or nil when it quotes nothing (or
    /// is nothing but a quote, which then stays as it is).
    static func htmlWithoutQuote(_ html: String) -> String? {
        let key = "\(TextKey.of(html))" as NSString
        if let known = cache.object(forKey: key) { return known.value }
        let result = cutHTML(html)
        cache.setObject(Box(result), forKey: key)
        return result
    }

    /// The same for a message shown as text.
    static func textWithoutQuote(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let start = MessageTranslation.quoteStart(in: lines), start > 0 else { return nil }
        let head = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return head.contains(where: \.isLetter) ? head : nil
    }

    /// A forwarded message's "history" is the point of it: nothing is folded.
    static func isForward(_ subject: String) -> Bool {
        subject.firstMatch(of: forwardPrefix) != nil
    }

    nonisolated(unsafe) private static let forwardPrefix = /^\s*(fw|fwd|wg|tr|rv|enc|vb|doorst)\s*(\[\d+\])?\s*[:：]/.ignoresCase()

    private final class Box {
        let value: String?
        init(_ value: String?) { self.value = value }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 60
        return cache
    }()

    private static let intros = ["On ", "Op ", "Am ", "Le ", "El ", "Il ", "Em ", "Den ", "В "]
    private static let wrote = ["wrote", "schreef", "schrieb", "a écrit", "escribió", "ha scritto", "escreveu", "skrev", "írta", "написал"]

    private static func cutHTML(_ html: String) -> String? {
        guard let start = HTMLTranslation.quoteStart(in: html) else { return nil }
        var end = start
        // Apple Mail and others put "On … wrote:" just before the quote, outside it: that goes too.
        if let line = attributionStart(in: html[..<start]) { end = line }
        let head = String(html[..<end])
        return HTMLText.plain(head).contains(where: \.isLetter) ? head : nil
    }

    /// Where a closing "On … wrote:" line begins, with the tags that open it, if the HTML ends
    /// with one.
    private static func attributionStart(in head: Substring) -> String.Index? {
        let tail = head.suffix(1500)
        var search = tail.endIndex
        while let found = intros.compactMap({ tail[..<search].range(of: $0, options: .backwards)?.lowerBound }).max() {
            search = found
            // Only at the start of a line of text: right after a tag.
            let before = tail[..<found].last(where: { !$0.isWhitespace })
            guard before == ">" || before == nil else { continue }
            let text = HTMLText.plain(String(tail[found...])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count < 400, text.hasSuffix(":"), wrote.contains(where: text.lowercased().contains) else { continue }
            return openingTags(before: found, in: tail)
        }
        return nil
    }

    /// Steps back over the opening tags that wrap a line (`<div><span>`), so they go with it.
    private static func openingTags(before index: Substring.Index, in text: Substring) -> Substring.Index {
        var start = index
        while true {
            let trimmed = text[..<start]
            guard let last = trimmed.lastIndex(where: { !$0.isWhitespace }), trimmed[last] == ">",
                  let open = trimmed[..<last].lastIndex(of: "<") else { return start }
            let tag = trimmed[trimmed.index(after: open)..<last].lowercased()
            guard !tag.hasPrefix("/"), ["div", "p", "span", "font", "b", "br"].contains(where: { tag == $0 || tag.hasPrefix($0 + " ") || tag.hasPrefix($0 + "/") }) else {
                return start
            }
            start = open
        }
    }
}
