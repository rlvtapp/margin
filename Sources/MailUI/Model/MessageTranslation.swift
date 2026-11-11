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
    static func pieces(_ text: String) -> [Piece] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        if let quote = quoteStart(in: lines), quote > 0 {
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
    static func segments(in html: String) -> [Segment] {
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
        if let quote = quoteStart(in: html), segments.contains(where: { $0.range.lowerBound < quote }) {
            segments.removeAll { $0.range.lowerBound >= quote }
        }
        return segments
    }

    /// Where the quoted mail begins in a reply's HTML: Apple Mail's and others' blockquote,
    /// Gmail's quote, Outlook's reply header. A forwarded message isn't history.
    static func quoteStart(in html: String) -> String.Index? {
        let markers = ["<blockquote", "class=\"gmail_quote", "id=\"divRplyFwdMsg", "id=\"appendonsend", "class=\"moz-cite-prefix", "class=\"yahoo_quoted"]
        let forwarded = ["forwarded message", "doorgestuurd bericht", "weitergeleitete nachricht", "message transféré", "mensaje reenviado",
                         "messaggio inoltrato", "mensagem encaminhada", "begin forwarded message", "begin doorgestuurd bericht"]
        let found = markers.compactMap { html.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
        guard let found else { return nil }
        let after = html[found...].prefix(600).lowercased()
        if forwarded.contains(where: after.contains) { return nil }
        // From the start of the tag the marker is in.
        return html[found] == "<" ? found : (html[..<found].lastIndex(of: "<") ?? found)
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
