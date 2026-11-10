import Foundation

/// A message written in blocks: headings, paragraphs, lists, checklists, quotes, code, dividers
/// and simple tables. It can come from structure typed in the composer (`## Heading`, `- item`,
/// `- [ ] task`, `> quote`) or, later, from Relevate's block editor. It turns into standard email:
/// conservative HTML with inline styles that every mail app shows, and a plain-text version that
/// keeps the structure readable.
public struct MailDocument: Equatable, Sendable {
    public var blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    public enum Block: Equatable, Sendable {
        case heading(level: Int, [Run])
        case paragraph([Run])
        case bullets([[Run]])
        case numbered([[Run]])
        case tasks([Task])
        case quote([Run])
        case code(String)
        case divider
        case table([[String]])
        /// A picture sent inside the message: an attachment with this Content-ID, shown at
        /// `width` pixels at most.
        case image(contentID: String, alt: String, width: Int?)
    }

    public struct Task: Equatable, Sendable {
        public var done: Bool
        public var text: [Run]
        public init(done: Bool, text: [Run]) { self.done = done; self.text = text }
    }

    /// A stretch of text with one style.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var code = false
        public var strike = false
        public var underline = false
        public var link: URL?

        public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: URL? = nil,
                    strike: Bool = false, underline: Bool = false) {
            self.text = text
            self.strike = strike
            self.underline = underline
            self.bold = bold
            self.italic = italic
            self.code = code
            self.link = link
        }
    }

    /// Whether there's anything beyond plain paragraphs, so plain mail stays plain.
    public var hasStructure: Bool {
        blocks.contains { block in
            switch block {
            case .paragraph(let runs): runs.contains { $0.bold || $0.italic || $0.code || $0.strike || $0.underline }
            default: true
            }
        }
    }
}

// MARK: Reading typed structure

extension MailDocument {
    /// Reads Markdown-style structure from plain text. Anything it doesn't recognise stays a
    /// paragraph, line breaks included.
    public static func parse(_ text: String) -> MailDocument {
        var blocks: [Block] = []
        var paragraph: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }
        func collect(_ matches: (String) -> String?) -> [String] {
            var items: [String] = []
            while index < lines.count, let item = matches(lines[index]) { items.append(item); index += 1 }
            return items
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if trimmed.hasPrefix("```") {
                flush()
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[index]); index += 1 }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, inline(String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))))
                index += 1
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "———" {
                flush(); blocks.append(.divider); index += 1; continue
            }
            if task(trimmed) != nil {
                flush()
                var items: [Task] = []
                while index < lines.count, let item = task(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(Task(done: item.done, text: inline(item.text)))
                    index += 1
                }
                blocks.append(.tasks(items))
                continue
            }
            if bullet(trimmed) != nil {
                flush()
                // A checklist item right after a list starts a checklist of its own.
                blocks.append(.bullets(collect { line in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    return task(text) == nil ? bullet(text) : nil
                }.map(inline)))
                continue
            }
            if numbered(trimmed) != nil {
                flush()
                blocks.append(.numbered(collect { numbered($0.trimmingCharacters(in: .whitespaces)) }.map(inline)))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                let quoted = collect { line in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    return text.hasPrefix(">") ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : nil
                }
                blocks.append(.quote(inline(quoted.joined(separator: "\n"))))
                continue
            }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                flush()
                let rows = collect { line in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    return text.hasPrefix("|") && text.hasSuffix("|") ? text : nil
                }
                let cells = rows.map { row in row.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) } }
                    // A "|---|---|" line only marks the header.
                    .filter { !$0.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } } }
                blocks.append(.table(cells))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return MailDocument(blocks: blocks)
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) { return String(line.dropFirst(marker.count)) }
        return nil
    }

    static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    static func task(_ line: String) -> (done: Bool, text: String)? {
        guard let item = bullet(line) else { return nil }
        let lower = item.lowercased()
        if lower.hasPrefix("[ ] ") { return (false, String(item.dropFirst(4))) }
        if lower.hasPrefix("[x] ") { return (true, String(item.dropFirst(4))) }
        return nil
    }

    /// `**bold**`, `*italic*` or `_italic_`, `` `code` ``, `[text](https://…)` and bare links.
    static func inline(_ text: String) -> [Run] {
        var runs: [Run] = []
        var plain = ""
        var rest = Substring(text)
        func push(_ run: Run) {
            if !plain.isEmpty { runs.append(contentsOf: links(plain)); plain = "" }
            runs.append(run)
        }
        while let first = rest.first {
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**"), end.lowerBound > rest.index(rest.startIndex, offsetBy: 2) {
                push(Run(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]), bold: true))
                rest = rest[end.upperBound...]
            } else if first == "`", let end = rest.dropFirst().firstIndex(of: "`") {
                push(Run(String(rest[rest.index(after: rest.startIndex)..<end]), code: true))
                rest = rest[rest.index(after: end)...]
            } else if first == "[", let close = rest.range(of: "]("), let end = rest[close.upperBound...].firstIndex(of: ")"),
                      let url = URL(string: String(rest[close.upperBound..<end])), url.scheme != nil {
                push(Run(String(rest[rest.index(after: rest.startIndex)..<close.lowerBound]), link: url))
                rest = rest[rest.index(after: end)...]
            } else if first == "*" || first == "_", rest.count > 2, rest.dropFirst().first?.isWhitespace == false,
                      (runs.isEmpty && plain.isEmpty) || plain.last?.isWhitespace == true || plain.isEmpty,
                      let end = rest.dropFirst().firstIndex(of: first), rest[rest.index(before: end)].isWhitespace == false {
                push(Run(String(rest[rest.index(after: rest.startIndex)..<end]), italic: true))
                rest = rest[rest.index(after: end)...]
            } else {
                plain.append(first)
                rest = rest.dropFirst()
            }
        }
        if !plain.isEmpty { runs.append(contentsOf: links(plain)) }
        return runs
    }

    /// Plain text with any web addresses made into links.
    static func links(_ text: String) -> [Run] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [Run(text)] }
        let ns = text as NSString
        var runs: [Run] = []
        var cursor = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, url.scheme == "https" || url.scheme == "http" || url.scheme == "mailto" else { continue }
            if match.range.location > cursor { runs.append(Run(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))) }
            runs.append(Run(ns.substring(with: match.range), link: url))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { runs.append(Run(ns.substring(from: cursor))) }
        return runs
    }
}

// MARK: Email HTML

extension MailDocument {
    /// HTML that mail apps show the same way: only common tags, every style inline, no classes,
    /// no stylesheet, no scripts.
    public func html() -> String {
        let font = "font-family:-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1d1f23"
        let body = blocks.map(Self.html).joined(separator: "\n")
        return "<div style=\"\(font)\">\n\(body)\n</div>"
    }

    static func html(_ block: Block) -> String {
        switch block {
        case .heading(let level, let runs):
            let size = [1: 22, 2: 19, 3: 16][level] ?? 16
            // h2 and h3: many mail apps give h1 their own oversized look.
            return "<h\(level + 1) style=\"font-size:\(size)px;line-height:1.3;margin:20px 0 8px;font-weight:600\">\(html(runs))</h\(level + 1)>"
        case .paragraph(let runs):
            return "<p style=\"margin:0 0 12px\">\(html(runs).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        case .bullets(let items):
            return "<ul style=\"margin:0 0 12px;padding-left:24px\">" + items.map { "<li style=\"margin:0 0 4px\">\(html($0))</li>" }.joined() + "</ul>"
        case .numbered(let items):
            return "<ol style=\"margin:0 0 12px;padding-left:24px\">" + items.map { "<li style=\"margin:0 0 4px\">\(html($0))</li>" }.joined() + "</ol>"
        case .tasks(let items):
            // Forms don't work in mail; a box character shows the same everywhere.
            return "<p style=\"margin:0 0 12px\">" + items.map { item in
                let text = html(item.text)
                return (item.done ? "☑ <span style=\"color:#8a8f97;text-decoration:line-through\">\(text)</span>" : "☐ \(text)")
            }.joined(separator: "<br>") + "</p>"
        case .quote(let runs):
            return "<blockquote style=\"margin:0 0 12px;padding:2px 0 2px 12px;border-left:3px solid #d7dade;color:#565b63\">\(html(runs).replacingOccurrences(of: "\n", with: "<br>"))</blockquote>"
        case .code(let text):
            return "<pre style=\"margin:0 0 12px;padding:10px 12px;background:#f3f4f6;border-radius:6px;font-family:Menlo,Consolas,monospace;font-size:13px;white-space:pre-wrap\">\(escape(text))</pre>"
        case .divider:
            return "<hr style=\"border:none;border-top:1px solid #e1e3e6;margin:16px 0\">"
        case .image(let contentID, let alt, let width):
            // width as an attribute too: some mail apps ignore max-width.
            let size = width.map { " width=\"\(min($0, 600))\"" } ?? ""
            return "<p style=\"margin:0 0 12px\"><img src=\"cid:\(escape(contentID))\" alt=\"\(escape(alt))\"\(size) style=\"display:block;max-width:100%;height:auto;border-radius:4px\"></p>"
        case .table(let rows):
            let cells = rows.enumerated().map { index, row in
                "<tr>" + row.map { cell in
                    index == 0
                        ? "<th style=\"border:1px solid #e1e3e6;padding:6px 10px;text-align:left;background:#f6f7f8\">\(escape(cell))</th>"
                        : "<td style=\"border:1px solid #e1e3e6;padding:6px 10px\">\(escape(cell))</td>"
                }.joined() + "</tr>"
            }.joined()
            return "<table cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;margin:0 0 12px\">\(cells)</table>"
        }
    }

    static func html(_ runs: [Run]) -> String {
        runs.map { run in
            var text = escape(run.text)
            if run.code { text = "<code style=\"font-family:Menlo,Consolas,monospace;font-size:13px;background:#f3f4f6;padding:1px 4px;border-radius:4px\">\(text)</code>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.strike { text = "<s>\(text)</s>" }
            if run.underline { text = "<u>\(text)</u>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if let link = run.link { text = "<a href=\"\(escape(link.absoluteString))\" style=\"color:#2f78f5\">\(text)</a>" }
            return text
        }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: Plain text

extension MailDocument {
    /// The plain-text part: the same structure in characters any mail app shows.
    public func plainText() -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(let level, let runs): String(repeating: "#", count: level) + " " + Self.plain(runs)
            case .paragraph(let runs): Self.plain(runs)
            case .bullets(let items): items.map { "- " + Self.plain($0) }.joined(separator: "\n")
            case .numbered(let items): items.enumerated().map { "\($0.offset + 1). " + Self.plain($0.element) }.joined(separator: "\n")
            case .tasks(let items): items.map { ($0.done ? "[x] " : "[ ] ") + Self.plain($0.text) }.joined(separator: "\n")
            case .quote(let runs): Self.plain(runs).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .code(let text): text.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
            case .divider: "———"
            case .image(_, let alt, _): alt.isEmpty ? "[Picture]" : "[Picture: \(alt)]"
            case .table(let rows):
                rows.map { row in row.joined(separator: " | ") }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    static func plain(_ runs: [Run]) -> String {
        runs.map { run in
            if let link = run.link, link.absoluteString != run.text, link.absoluteString != "mailto:" + run.text {
                return "\(run.text) (\(link.absoluteString))"
            }
            return run.text
        }.joined()
    }
}
