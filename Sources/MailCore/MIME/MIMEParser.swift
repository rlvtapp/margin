import Foundation

/// A parsed RFC 5322 / MIME message: enough to read it, not to re-serialize it.
public struct MIMEMessage: Sendable {
    public var headers: MIMEHeaders
    public var text: String
    public var html: String?
    public var attachments: [AttachmentInfo]
    public var invite: CalendarInvite?
    /// The emoji of a Gmail-format reaction part.
    public var reaction: String?

    public var body: MessageBody {
        let readable = text.isEmpty ? (html.map(HTMLText.plain) ?? "") : text
        return MessageBody(text: readable.trimmingCharacters(in: .whitespacesAndNewlines), html: html, attachments: attachments, invite: invite,
                           reaction: reaction)
            .embeddingInlineImages()
    }

    public static func parse(_ bytes: [UInt8]) -> MIMEMessage {
        var message = MIMEMessage(headers: MIMEHeaders(), text: "", html: nil, attachments: [], invite: nil)
        let (headers, body) = MIMEHeaders.split(bytes)
        message.headers = headers
        message.collect(headers: headers, body: body, depth: 0)
        return message
    }

    private mutating func collect(headers: MIMEHeaders, body: [UInt8], depth: Int) {
        guard depth < 12 else { return }
        let type = headers.contentType
        let disposition = headers.parameters(of: "content-disposition")
        let filename = disposition.params["filename"] ?? type.params["name"]
        let contentID = headers["content-id"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>\t")) }.flatMap { $0.isEmpty ? nil : $0 }
        if type.value.hasPrefix("multipart/"), let boundary = type.params["boundary"] {
            for part in Self.parts(of: body, boundary: boundary) {
                let (partHeaders, partBody) = MIMEHeaders.split(part)
                collect(headers: partHeaders, body: partBody, depth: depth + 1)
            }
            return
        }
        if type.value == "message/rfc822", disposition.value != "attachment" {
            let (innerHeaders, innerBody) = MIMEHeaders.split(body)
            collect(headers: innerHeaders, body: innerBody, depth: depth + 1)
            return
        }
        if type.value == "text/calendar" || (filename?.lowercased().hasSuffix(".ics") ?? false) {
            let decoded = Self.decode(body, encoding: headers["content-transfer-encoding"])
            if invite == nil { invite = CalendarInvite.parse(Charset.string(from: decoded, charset: type.params["charset"])) }
            if disposition.value != "attachment" { return }
        }
        let isAttachment = disposition.value == "attachment" || (filename != nil && !type.value.hasPrefix("text/"))
        if isAttachment {
            let data = Data(Self.decode(body, encoding: headers["content-transfer-encoding"]))
            attachments.append(AttachmentInfo(filename: MIMEWords.decode(filename ?? "Attachment"), mimeType: type.value, data: data, contentID: contentID))
            return
        }
        let decoded = Self.decode(body, encoding: headers["content-transfer-encoding"])
        // A reaction in Gmail's documented format: {"version":1,"emoji":"👍"}.
        if type.value == MailReaction.gmailType {
            if reaction == nil { reaction = MailReaction.gmailEmoji(Data(decoded)) }
            return
        }
        let content = Charset.string(from: decoded, charset: type.params["charset"])
        // The first text part wins; alternatives that come later are the same content.
        if type.value == "text/plain", text.isEmpty {
            text = content.replacingOccurrences(of: "\r\n", with: "\n")
        } else if type.value == "text/html", html == nil {
            html = content
        } else if !type.value.hasPrefix("text/") {
            attachments.append(AttachmentInfo(filename: "Attachment", mimeType: type.value, data: Data(decoded), contentID: contentID))
        }
    }

    static func decode(_ body: [UInt8], encoding: String?) -> [UInt8] {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let compact = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters).map(Array.init) ?? []
        case "quoted-printable":
            return QuotedPrintable.decode(String(decoding: body, as: UTF8.self))
        default:
            return body
        }
    }

    /// Splits on `--boundary` at line starts, working on bytes so 8-bit parts in
    /// other charsets survive until they're decoded.
    static func parts(of body: [UInt8], boundary: String) -> [[UInt8]] {
        let marker = Array(("--" + boundary).utf8)
        var starts: [Int] = []
        var index = 0
        while index + marker.count <= body.count {
            let atLineStart = index == 0 || body[index - 1] == 0x0A
            if atLineStart && body[index] == marker[0] && Array(body[index..<(index + marker.count)]) == marker {
                starts.append(index)
                index += marker.count
            } else {
                index += 1
            }
        }
        var parts: [[UInt8]] = []
        for (offset, start) in starts.enumerated() {
            var from = start + marker.count
            if from + 1 < body.count, body[from] == UInt8(ascii: "-"), body[from + 1] == UInt8(ascii: "-") { break }
            while from < body.count, body[from] != 0x0A { from += 1 } // rest of the delimiter line
            from += 1
            var end = offset + 1 < starts.count ? starts[offset + 1] : body.count
            if end > from, body[end - 1] == 0x0A { end -= 1 }
            if end > from, body[end - 1] == 0x0D { end -= 1 }
            if from < end { parts.append(Array(body[from..<end])) }
        }
        return parts
    }
}

public struct MIMEHeaders: Sendable {
    /// Lowercased name → unfolded, undecoded value. Repeated headers keep the first.
    public private(set) var fields: [String: String] = [:]

    public init(fields: [String: String] = [:]) { self.fields = fields }

    public subscript(name: String) -> String? { fields[name.lowercased()] }

    public static func parse(_ text: String) -> MIMEHeaders {
        var headers = MIMEHeaders()
        var name: String?
        var value = ""
        func flush() {
            if let name, headers.fields[name] == nil {
                headers.fields[name] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                value += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                value = String(line[line.index(after: colon)...])
            }
        }
        flush()
        return headers
    }

    /// Splits at the first blank line into headers and body.
    static func split(_ bytes: [UInt8]) -> (MIMEHeaders, [UInt8]) {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    return (parse(String(decoding: bytes[..<index], as: UTF8.self)), Array(bytes[(index + 2)...]))
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    return (parse(String(decoding: bytes[..<index], as: UTF8.self)), Array(bytes[(index + 3)...]))
                }
            }
            index += 1
        }
        return (parse(String(decoding: bytes, as: UTF8.self)), [])
    }

    var contentType: (value: String, params: [String: String]) {
        let parsed = parameters(of: "content-type")
        return (parsed.value.isEmpty ? "text/plain" : parsed.value, parsed.params)
    }

    /// `text/plain; charset="utf-8"` → ("text/plain", ["charset": "utf-8"]).
    func parameters(of name: String) -> (value: String, params: [String: String]) {
        guard let raw = self[name] else { return ("", [:]) }
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for char in raw {
            if char == "\"" { inQuotes.toggle() }
            if char == ";" && !inQuotes { pieces.append(current); current = "" } else { current.append(char) }
        }
        pieces.append(current)
        let value = pieces.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var params: [String: String] = [:]
        for piece in pieces {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var val = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            // RFC 2231 `filename*=utf-8''r%C3%A9sum%C3%A9.pdf`
            if key.hasSuffix("*") {
                key.removeLast()
                if let quote = val.range(of: "''") { val = String(val[quote.upperBound...]).removingPercentEncoding ?? val }
            }
            params[key] = val
        }
        return (value, params)
    }
}

/// Readable text from HTML mail, for previews and as a fallback when no plain part exists.
public enum HTMLText {
    public static func plain(_ html: String) -> String {
        var text = html
        // What comes before <body> is never shown.
        if let body = text.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            text = String(text[body.upperBound...])
        }
        for tag in ["style", "script", "head", "title"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
            // A preview fetches only the start, which can stop inside a style block.
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*$", with: "", options: [.regularExpression, .caseInsensitive])
        }
        // …or inside a tag.
        text = text.replacingOccurrences(of: "<[^>]*$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|div|tr|h[1-6]|li|blockquote)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTML mail as light Markdown, for screens with no web view (Apple Watch): headings and
    /// bold text stay bold, list items get a bullet, links stay tappable, pictures, tracking
    /// pixels and layout tables are dropped. Markdown already in the text is escaped.
    public static func markdown(_ html: String) -> String {
        var text = html
        for tag in ["style", "script", "head", "title"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<img[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        // Characters that would read as Markdown in the mail's own words.
        for character in ["\\", "*", "_", "`", "[", "]"] {
            text = text.replacingOccurrences(of: character, with: "\\" + character)
        }
        // Links: only web and mail links stay; the text keeps its words either way.
        text = text.replacingOccurrences(
            of: "<a[^>]*href\\s*=\\s*[\"']((?:https?|mailto):[^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
            with: "\u{1}$2\u{2}($1)", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<h[1-6][^>]*>", with: "\n\n\u{3}", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\u{3}\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<(b|strong)(\\s[^>]*)?>", with: "\u{3}", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(b|strong)>", with: "\u{3}", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</li>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|div|tr|blockquote|ul|ol|table)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&zwnj;": "", "&#8203;": "", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, replacement) in entities { text = text.replacingOccurrences(of: entity, with: replacement) }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        // Bold markers that wrap nothing, then the real Markdown.
        text = text.replacingOccurrences(of: "\u{3}\\s*\u{3}", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{3}", with: "**")
        text = text.replacingOccurrences(of: "\u{1}", with: "[").replacingOccurrences(of: "\u{2}", with: "]")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first line or two of text, for list rows.
    /// `&nbsp;`, `&amp;`, `&#160;`, `&#x2019;` and the like as the characters they stand for.
    /// `&amp;` goes last, so `&amp;nbsp;` stays the text "&nbsp;".
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&zwnj;": "", "&zwj;": "",
                     "&shy;": "", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&ndash;": "–", "&mdash;": "—",
                     "&hellip;": "…", "&euro;": "€", "&copy;": "©", "&reg;": "®", "&trade;": "™"]
        for (entity, replacement) in named { result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive) }
        if let numeric = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in numeric.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let value = Range(match.range(at: 1), in: result) else { continue }
                let digits = result[value]
                let code = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                let character = code.flatMap(Unicode.Scalar.init).map { [0x200B, 0x200C, 0x200D, 0xFEFF, 0xAD, 0x34F].contains($0.value) ? "" : String(Character($0)) }
                result.replaceSubrange(whole, with: (character ?? "").replacingOccurrences(of: "\u{A0}", with: " "))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "\u{A0}", with: " ")
    }

    public static func snippet(_ text: String, length: Int = 160) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }
        let joined = tidyPreview(lines.joined(separator: " "))
        return joined.count > length ? String(joined.prefix(length)) + "…" : joined
    }

    /// A preview without the dividers plain-text mail draws with characters ("-------",
    /// "=====", "_____", "*****"): runs of three or more go, and the spaces close up.
    public static func tidyPreview(_ text: String) -> String {
        guard text.contains(where: { dividerCharacters.contains($0) }) else { return text }
        var result = ""
        var run = ""
        func flush() {
            if run.count < 3 { result += run }
            run = ""
        }
        for character in text {
            if dividerCharacters.contains(character) {
                if let last = run.last, last != character { flush() }
                run.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let dividerCharacters: Set<Character> = ["-", "_", "=", "*", "~", "—", "–", "·", "•", "#"]
}
