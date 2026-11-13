import Foundation
import MailCore
import NaturalLanguage

/// Translating a message into the reader's language, on the device (the system's own
/// translation, after its languages are downloaded once): which language a message is in,
/// whether the reader reads it already, and the pieces it's translated in so its paragraphs
/// and lines survive.
enum MessageTranslation {
    /// The language a message is written in, when that's clear: enough words and a confident guess.
    static func language(of text: String) -> Locale.Language? {
        let sample = String(text.prefix(2000))
        guard sample.unicodeScalars.filter(CharacterSet.letters.contains).count >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined, confidence >= 0.8 else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Whether someone with these languages (the system's preferred ones) needs it translated.
    static func isForeign(_ language: Locale.Language, readerLanguages: [String] = Locale.preferredLanguages) -> Bool {
        guard let code = language.languageCode?.identifier else { return false }
        let reads = Set(readerLanguages.compactMap { Locale.Language(identifier: $0).languageCode?.identifier })
        return !reads.contains(code)
    }

    /// The language's name in the reader's language ("German", "Duits").
    static func name(of language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// One piece of a message: text to translate, or the line breaks between pieces, kept as they are.
    enum Piece: Equatable {
        case text(String)
        case breaks(String)
    }

    /// A message split into paragraphs to translate one by one. Lines wrapped at a fixed width
    /// (as plain-text mail often is) are joined back into their sentence first; short lines (a
    /// greeting, a list, a signature) stay lines of their own. Quoted history at the end (the
    /// mail being answered, already in the conversation) is kept as it is: less to translate.
    static func pieces(_ text: String, keepsQuote: Bool = false) -> [Piece] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        // In a forward the quoted part is the message: it's translated with the rest.
        if !keepsQuote, let quote = quoteStart(in: lines), quote > 0 {
            let head = lines[..<quote].joined(separator: "\n")
            if head.contains(where: \.isLetter) {
                return pieces(of: head) + [.breaks("\n" + lines[quote...].joined(separator: "\n"))]
            }
        }
        return pieces(of: normalized)
    }

    /// The line where quoted history begins: "> …", "On … wrote:" (in several languages), or a
    /// forwarded-reply header block ("From: … / Sent: …"). Forwarded mail isn't history.
    static func quoteStart(in lines: [String]) -> Int? {
        let intros = ["on ", "op ", "am ", "le ", "el ", "il ", "em ", "в "]
        let wrote = ["wrote", "schreef", "schrieb", "a écrit", "escribió", "ha scritto", "escreveu", "írta", "написал"]
        let froms = ["from:", "van:", "von:", "de :", "de:", "da:", "feladó:", "от:"]
        let sents = ["sent:", "date:", "verzonden:", "datum:", "gesendet:", "envoyé :", "envoyé:", "enviado:", "inviato:", "dátum:", "отправлено:"]
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix(">") { return index }
            if trimmed.hasPrefix("-----original message") || trimmed.hasPrefix("-----oorspronkelijk bericht") || trimmed.hasPrefix("________________") {
                return index
            }
            if intros.contains(where: trimmed.hasPrefix) {
                // "On Tue, Jane <jane@example.com>" can wrap before its "wrote:".
                let joined = trimmed + " " + (index + 1 < lines.count ? lines[index + 1].lowercased() : "")
                if wrote.contains(where: joined.prefix(400).contains), joined.contains(":") { return index }
            }
            if froms.contains(where: trimmed.hasPrefix),
               let next = lines[(index + 1)...].prefix(3).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               sents.contains(where: next.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix) {
                return index
            }
        }
        return nil
    }

    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        let paragraphs = text.components(separatedBy: "\n\n")
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { pieces.append(.breaks("\n\n")) }
            let lines = paragraph.components(separatedBy: "\n")
            let wrapped = lines.count > 1 && lines.dropLast().allSatisfy { $0.count >= 55 && $0.count <= 80 }
            if wrapped {
                let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                pieces.append(.text(joined))
                continue
            }
            for (lineIndex, line) in lines.enumerated() {
                if lineIndex > 0 { pieces.append(.breaks("\n")) }
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !line.isEmpty { pieces.append(.breaks(line)) }
                } else {
                    pieces.append(.text(line))
                }
            }
        }
        return pieces
    }

    /// The pieces put back together, each text piece replaced by its translation.
    static func join(_ pieces: [Piece], translations: [String]) -> String {
        var remaining = translations[...]
        return pieces.map { piece in
            switch piece {
            case .breaks(let breaks): breaks
            case .text(let original): remaining.popFirst() ?? original
            }
        }.joined()
    }
}

/// Translating HTML mail in its own layout: the text between its tags is taken out, translated
/// and put back where it was, so the design, pictures and links stay as the sender made them.
/// Text in styles, scripts and the head is left alone.
enum HTMLTranslation {
    /// One run of text between tags: where it is in the HTML, and the text it shows.
    struct Segment: Equatable {
        let range: Range<String.Index>
        /// The text as shown (entities decoded), without the spaces around it.
        let text: String
        let leading: String
        let trailing: String
    }

    private static let skipped: Set<String> = ["style", "script", "head", "title", "noscript", "template", "svg", "math"]

    /// The runs of text worth translating: ones with letters in them, that aren't a web or email address.
    static func segments(in html: String, keepsQuote: Bool = false) -> [Segment] {
        var segments: [Segment] = []
        var index = html.startIndex
        var textStart = index
        func closeText(at end: String.Index) {
            guard textStart < end else { return }
            let raw = html[textStart..<end]
            let decoded = HTMLText.decodeEntities(String(raw))
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains(where: \.isLetter), !looksLikeAddress(trimmed) else { return }
            let leading = String(decoded.prefix { $0.isWhitespace })
            let trailing = String(decoded.reversed().prefix { $0.isWhitespace }.reversed())
            segments.append(Segment(range: textStart..<end, text: trimmed, leading: leading, trailing: trailing))
        }
        while index < html.endIndex {
            guard html[index] == "<" else { index = html.index(after: index); continue }
            closeText(at: index)
            // A comment, to its end.
            if html[index...].hasPrefix("<!--") {
                index = html.range(of: "-->", range: index..<html.endIndex)?.upperBound ?? html.endIndex
                textStart = index
                continue
            }
            guard let tagEnd = html[index...].firstIndex(of: ">") else { textStart = html.endIndex; break }
            let inside = html[html.index(after: index)..<tagEnd]
            let name = tagName(inside)
            index = html.index(after: tagEnd)
            // Inside a style, script or the head: on to its closing tag.
            if skipped.contains(name), inside.first != "/", inside.last != "/" {
                if let close = html.range(of: "</\(name)", options: .caseInsensitive, range: index..<html.endIndex) {
                    index = html[close.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                } else {
                    index = html.endIndex
                }
            }
            textStart = index
        }
        closeText(at: html.endIndex)
        // Quoted history (the mail being answered) stays as it is, if there's anything before it.
        if !keepsQuote, let quote = quoteStart(in: html), segments.contains(where: { $0.range.lowerBound < quote }) {
            segments.removeAll { $0.range.lowerBound >= quote }
        }
        return segments
    }

    /// Where the quoted mail begins in a reply's HTML: Apple Mail's and others' blockquote,
    /// Gmail's quote, Outlook's containers, or a "From: / Sent:" header block. A message marked
    /// as forwarded isn't history.
    /// "From" in the languages the header patterns know, as lowered bytes.
    private static let fromLabels: [[UInt8]] = ["from", "van", "von", "de", "da", "från", "fra", "feladó", "от"].map { Array($0.utf8) }

    /// Whether `label` is somewhere followed by a colon, with nothing but blank space between
    /// (the patterns allow any). A cheap "could this mail hold a quoted header at all?".
    private static func hasLabel(_ label: [UInt8], in bytes: [UInt8]) -> Bool {
        var from = 0
        while let found = bytes.firstIndex(of: label, from: from) {
            var next = found + label.count
            while next < bytes.count, [32, 9, 10, 13, 0xC2, 0xA0].contains(bytes[next]) { next += 1 }
            if next < bytes.count, bytes[next] == 58 { return true }
            // "&nbsp;" written out, as Outlook does.
            if bytes.count - next >= 7, Array(bytes[next..<(next + 6)]) == Array("&nbsp;".utf8) { return true }
            from = found + 1
        }
        return false
    }

    static func quoteStart(in html: String) -> String.Index? {
        let markers = ["<blockquote", "class=\"gmail_quote", "divRplyFwdMsg\"", "id=\"appendonsend", "class=\"moz-cite-prefix",
                       "class=\"yahoo_quoted", "mail-editor-reference-message-container\""]
        let forwarded = ["forwarded message", "doorgestuurd bericht", "weitergeleitete nachricht", "message transféré", "mensaje reenviado",
                         "messaggio inoltrato", "mensagem encaminhada", "begin forwarded message", "begin doorgestuurd bericht"]
        // Searched as bytes with ASCII letters lowered, once: seven case-insensitive searches
        // through a 100 KB mail the usual way cost several milliseconds on every mail opened.
        let bytes = html.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        var starts = markers.compactMap { marker -> String.Index? in
            guard let offset = bytes.firstIndex(of: Array(marker.lowercased().utf8)) else { return nil }
            let found = html.utf8.index(html.utf8.startIndex, offsetBy: offset)
            // From the start of the tag the marker is in.
            return html[found] == "<" ? found : (html[..<found].lastIndex(of: "<") ?? found)
        }
        // The two header forms need a "from" label followed by a colon somewhere; most mail
        // (receipts, newsletters) has neither, and is spared the pattern search.
        if Self.fromLabels.contains(where: { Self.hasLabel($0, in: bytes) }) {
            if let block = headerBlockStart(in: html) { starts.append(block) }
            if let rows = headerRowsStart(in: html) { starts.append(rows) }
        }
        guard let found = starts.min() else { return nil }
        let after = html[found...].prefix(600).lowercased()
        if forwarded.contains(where: after.contains) { return nil }
        return found
    }

    /// Another way of quoting: plain rows, "From: Name <address>", then "To:", "Date:" or
    /// "Sent:", often under a rule, with the earlier mail after them. The From row has to hold
    /// an address, so a travel booking's "From: Amsterdam / To: Lisbon" isn't taken for one.
    static func headerRowsStart(in html: String) -> String.Index? {
        let from = "(?:From|Van|Von|De|Da|Från|Fra|Feladó|От)"
        let next = "(?:To|Sent|Date|Cc|Aan|An|À|Para|A|Till|Til|Datum|Verzonden|Gesendet|Envoyé|Enviado|Fecha|Inviato|Data|Skickat|Sendt|Dátum|Кому|Дата)"
        let lineBreak = "(?:<br\\s*/?>|</(?:div|p|span)>\\s*<(?:div|p|span)\\b[^>]*>|\\n)"
        let pattern = "(?:>|\\n|^)\\s*(\(from)\\s*:\\s[^<\\n]{0,200}@[^<\\n]{0,200})\\s*\(lineBreak)\\s*\(next)\\s*:"
        guard let expression = Patterns.expression(pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let label = Range(match.range(at: 1), in: html)?.lowerBound else { return nil }
        // With the rule above it when one is close by; otherwise from the tags that open the row.
        let before = html[..<label]
        if let rule = before.suffix(400).range(of: "<hr", options: [.backwards, .caseInsensitive])?.lowerBound {
            return rule
        }
        var start = label
        while let last = html[..<start].lastIndex(where: { !$0.isWhitespace }), html[last] == ">",
              let open = html[..<last].lastIndex(of: "<") {
            let tag = html[html.index(after: open)..<last].lowercased()
            guard !tag.hasPrefix("/"), ["div", "p", "span", "font", "pre"].contains(where: { tag == $0 || tag.hasPrefix($0 + " ") }) else { break }
            start = open
        }
        return start
    }

    /// Outlook's way of quoting, with no blockquote: a rule, then "From: … Sent: … To: …
    /// Subject: …" in bold labels, then the earlier mail. Returns where that block begins (its
    /// rule or bordered box when it has one).
    static func headerBlockStart(in html: String) -> String.Index? {
        let from = "(?:From|Van|Von|De|Da|Från|Fra|Feladó|От)"
        let sent = "(?:Sent|Date|Verzonden|Datum|Gesendet|Envoyé|Enviado|Fecha|Inviato|Data|Skickat|Sendt|Dátum|Отправлено|Дата)"
        let pattern = "<b\\b[^>]*>\\s*\(from)\\s*:\\s*</b>(?:(?!</b>).){1,400}?<b\\b[^>]*>\\s*\(sent)\\s*:"
        guard let expression = Patterns.expression(pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let label = Range(match.range, in: html)?.lowerBound else { return nil }
        let before = html[..<label].suffix(700)
        // The rule above it, or the box with a line along its top, when one is close by.
        if let rule = before.range(of: "<hr", options: [.backwards, .caseInsensitive])?.lowerBound,
           html.distance(from: rule, to: label) < 500 {
            return rule
        }
        var search = before.endIndex
        var nearest: Substring.Index?
        while let block = before[..<search].range(of: "<div", options: [.backwards, .caseInsensitive])?.lowerBound {
            search = block
            nearest = nearest ?? block
            let tag = before[block...].prefix { $0 != ">" }.lowercased()
            if tag.contains("border") { return block }
        }
        return nearest ?? before[..<before.endIndex].range(of: "<p", options: [.backwards, .caseInsensitive])?.lowerBound ?? label
    }

    /// The HTML with each segment's text swapped for its translation (escaped, with the spaces
    /// around it kept). A missing translation leaves the original.
    static func replacing(_ segments: [Segment], in html: String, with translations: [String]) -> String {
        var result = html
        for (segment, translation) in zip(segments, translations).reversed() {
            let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.replaceSubrange(segment.range, with: escape(segment.leading) + escape(text) + escape(segment.trailing))
        }
        return result
    }

    private static func tagName(_ inside: Substring) -> String {
        var name = inside.drop { $0 == "/" }
        name = name.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }
        return name.lowercased()
    }

    private static func looksLikeAddress(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        return text.contains("://") || text.hasPrefix("www.") || (text.contains("@") && text.contains("."))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Patterns put together once and kept: building one takes far longer than using it.
enum Patterns {
    nonisolated(unsafe) private static var made: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func expression(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock(); defer { lock.unlock() }
        if let known = made[key] { return known }
        guard let fresh = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        made[key] = fresh
        return fresh
    }
}
