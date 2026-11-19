import Foundation

/// A Sieve script (RFC 5228) as Margin edits it: the rules it understands, and everything else
/// kept word for word so rules made elsewhere keep running. Rules are written the way common
/// webmail writes them (`# rule:[name]` above an `if`), so both can edit them.
public struct SieveScript: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        /// A rule; `source` is its text as read, written back word for word until it's changed.
        case rule(ServerRule, source: String? = nil)
        /// Text Margin doesn't edit, kept as it was.
        case other(String)
    }

    /// Extensions named in the script's own `require`s, kept for the parts Margin doesn't edit.
    public var requires: [String]
    public var parts: [Part]

    public init(requires: [String] = [], parts: [Part] = []) {
        self.requires = requires
        self.parts = parts
    }

    /// The rules, with ids that say where each one is (`sieve-<part index>`).
    public var rules: [ServerRule] {
        parts.enumerated().compactMap { index, part in
            guard case .rule(var rule, _) = part else { return nil }
            rule.id = "sieve-\(index)"
            return rule
        }
    }

    /// Margin's rule in place of the one with this id, or added at the end.
    public mutating func put(_ rule: ServerRule) {
        var rule = rule
        rule.isEditable = true
        if let index = Self.index(of: rule.id), parts.indices.contains(index) {
            parts[index] = .rule(rule)
        } else {
            parts.append(.rule(rule))
        }
    }

    public mutating func remove(id: String) {
        guard let index = Self.index(of: id), parts.indices.contains(index) else { return }
        parts.remove(at: index)
    }

    static func index(of id: String) -> Int? {
        id.hasPrefix("sieve-") ? Int(id.dropFirst(6)) : nil
    }

    // MARK: Writing

    /// What the server offers that the script may use, from its SIEVE capability.
    public struct Options: Equatable, Sendable {
        public var extensions: Set<String>
        /// The folder "delete" moves mail to; mail is never discarded.
        public var trashFolder: String
        /// The folder "archive" moves mail to, when the mailbox has one.
        public var archiveFolder: String?

        public init(extensions: Set<String>, trashFolder: String = "Trash", archiveFolder: String? = nil) {
            self.extensions = extensions
            self.trashFolder = trashFolder
            self.archiveFolder = archiveFolder
        }

        /// Attachments are found by MIME part headers (RFC 5703) when offered, otherwise by
        /// the email being multipart/mixed, which is how attachments are almost always sent.
        var findsAttachmentsByPart: Bool { extensions.contains("mime") }
    }

    public func text(options: Options) -> String {
        var needed = Set(requires)
        var body: [String] = []
        for part in parts {
            switch part {
            case .other(let text):
                body.append(text)
            case .rule(_, let source?):
                body.append(source)
            case .rule(let rule, nil):
                let (text, uses) = Self.text(for: rule, options: options)
                needed.formUnion(uses)
                body.append(text)
            }
        }
        var lines: [String] = []
        if !needed.isEmpty {
            lines.append("require [" + needed.sorted().map(Self.quoted).joined(separator: ", ") + "];")
        }
        lines += body
        return lines.joined(separator: "\n") + "\n"
    }

    /// One rule as Sieve, and the extensions it needs.
    static func text(for rule: ServerRule, options: Options) -> (String, Set<String>) {
        var uses = Set<String>()
        var tests: [String] = []
        if !rule.trimmedFrom.isEmpty { tests.append("address :contains \"from\" \(quoted(rule.trimmedFrom))") }
        if !rule.trimmedTo.isEmpty { tests.append("address :contains [\"to\", \"cc\"] \(quoted(rule.trimmedTo))") }
        if !rule.trimmedSubject.isEmpty { tests.append("header :contains \"subject\" \(quoted(rule.trimmedSubject))") }
        if rule.hasAttachment {
            if options.findsAttachmentsByPart {
                uses.insert("mime")
                tests.append("header :mime :anychild :contains \"Content-Disposition\" \"attachment\"")
            } else {
                tests.append("header :contains \"Content-Type\" \"multipart/mixed\"")
            }
        }
        let test = switch tests.count {
        case 0: "true"
        case 1: tests[0]
        default: "allof (" + tests.joined(separator: ", ") + ")"
        }
        var actions: [String] = []
        // Flags first, so the copy filed into a folder carries them.
        var flags: [String] = []
        if rule.markRead { flags.append("\\Seen") }
        if rule.flag { flags.append("\\Flagged") }
        if !flags.isEmpty {
            uses.insert("imap4flags")
            actions.append("addflag " + (flags.count == 1 ? quoted(flags[0]) : "[" + flags.map(quoted).joined(separator: ", ") + "]") + ";")
        }
        let archiveFolder = rule.archive ? options.archiveFolder : nil
        let files = rule.delete || rule.moveTo != nil || archiveFolder != nil
        if !rule.trimmedForward.isEmpty {
            if options.extensions.contains("copy") {
                uses.insert("copy")
                actions.append("redirect :copy \(quoted(rule.trimmedForward));")
            } else {
                actions.append("redirect \(quoted(rule.trimmedForward));")
                // Redirecting cancels keeping it; keep a copy unless it's filed somewhere.
                if !files { actions.append("keep;") }
            }
        }
        if rule.delete {
            uses.insert("fileinto")
            actions.append("fileinto \(quoted(options.trashFolder));")
        } else if let folder = archiveFolder ?? rule.moveTo {
            uses.insert("fileinto")
            actions.append("fileinto \(quoted(folder));")
        }
        var lines = ["# rule:[\(rule.title.replacingOccurrences(of: "\n", with: " "))]"]
        lines.append((rule.isEnabled ? "if " : "if false # ") + test)
        lines.append("{")
        lines += actions.map { "\t" + $0 }
        lines.append("}")
        return (lines.joined(separator: "\n"), uses)
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Reading

    /// Splits a script into its `require`s, rules Margin understands, and the rest as it was.
    public init(parsing source: String, trashFolder: String = "Trash", archiveFolder: String? = nil) {
        self.init()
        for chunk in SieveChunker.chunks(source) {
            if let names = SieveRuleReader.requires(chunk) {
                for name in names where !requires.contains(name) { requires.append(name) }
            } else if let rule = SieveRuleReader.rule(chunk, trashFolder: trashFolder, archiveFolder: archiveFolder) {
                parts.append(.rule(rule, source: chunk.trimmingCharacters(in: .newlines)))
            } else if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(.other(chunk.trimmingCharacters(in: .newlines)))
            }
        }
        // Extensions only Margin's rules used are added again when written; text kept as it was
        // keeps what it needs.
        let othersText = parts.compactMap { part -> String? in
            switch part {
            case .other(let text), .rule(_, let text?): text
            case .rule(_, nil): nil
            }
        }.joined(separator: "\n")
        requires = requires.filter { name in
            !["fileinto", "imap4flags", "copy", "mime"].contains(name) || Self.mentions(othersText, extension: name)
        }
    }

    /// Whether text Margin keeps as it is uses an extension.
    static func mentions(_ text: String, extension name: String) -> Bool {
        switch name {
        case "fileinto": text.contains("fileinto")
        case "imap4flags": ["addflag", "setflag", "removeflag", "hasflag", ":flags"].contains { text.contains($0) }
        case "copy": text.contains(":copy")
        case "mime": text.contains(":mime") || text.contains("foreverypart")
        default: true
        }
    }
}

/// Cuts a script into top-level commands, each with the comments just above it. An `if` keeps
/// its `elsif`/`else` branches with it.
enum SieveChunker {
    static func chunks(_ source: String) -> [String] {
        let characters = Array(source)
        var chunks: [String] = []
        var start = 0
        var depth = 0
        var index = 0
        /// After a top-level block ends, a following `elsif`/`else` still belongs to it.
        var closedBlockAt: Int?

        func finish(at end: Int) {
            chunks.append(String(characters[start..<end]))
            start = end
            closedBlockAt = nil
        }

        while index < characters.count {
            let character = characters[index]
            if let closed = closedBlockAt, !character.isWhitespace {
                let rest = String(characters[index..<min(index + 6, characters.count)]).lowercased()
                if !(rest.hasPrefix("elsif") || rest.hasPrefix("else")) || character == "#" {
                    finish(at: closed)
                }
                closedBlockAt = nil
            }
            switch character {
            case "#":
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            case "/" where index + 1 < characters.count && characters[index + 1] == "*":
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index += 2
                continue
            case "\"":
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\" { index += 1 }
                    index += 1
                }
            case "t" where depth >= 0 && String(characters[index..<min(index + 5, characters.count)]) == "text:":
                // Multi-line string: up to a line holding only ".".
                while index < characters.count {
                    let lineEnd = characters[index...].firstIndex(of: "\n") ?? characters.count
                    let line = String(characters[index..<lineEnd]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    index = lineEnd + 1
                    if line == "." { break }
                }
                continue
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { closedBlockAt = index + 1 }
            case ";" where depth == 0:
                finish(at: index + 1)
            default:
                break
            }
            index += 1
        }
        if start < characters.count {
            chunks.append(String(characters[start...]))
        }
        return chunks
    }
}

/// Reads the rules Margin writes (and the same shapes written elsewhere); anything else is nil.
enum SieveRuleReader {
    enum Token: Equatable {
        case word(String)
        case tag(String)
        case string(String)
        case symbol(Character)
    }

    static func tokens(_ text: String) -> [Token]? {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character == "#" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "\"" {
                var value = ""
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count { index += 1 }
                    value.append(characters[index])
                    index += 1
                }
                guard index < characters.count else { return nil }
                index += 1
                tokens.append(.string(value))
                continue
            }
            if "[](),;{}".contains(character) {
                tokens.append(.symbol(character)); index += 1; continue
            }
            if character == ":" || character.isLetter {
                var word = String(character)
                index += 1
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" || characters[index] == "-" {
                    word.append(characters[index]); index += 1
                }
                tokens.append(word.hasPrefix(":") ? .tag(String(word.dropFirst()).lowercased()) : .word(word.lowercased()))
                continue
            }
            // Numbers, text: blocks and anything else are beyond what Margin edits.
            return nil
        }
        return tokens
    }

    static func requires(_ chunk: String) -> [String]? {
        guard let tokens = tokens(chunk), tokens.first == .word("require") else { return nil }
        let names = tokens.compactMap { if case .string(let name) = $0 { name } else { nil } }
        return names.isEmpty ? nil : names
    }

    /// `# rule:[name]` then `if <tests> { <actions> }`, with tests and actions Margin knows.
    static func rule(_ chunk: String, trashFolder: String, archiveFolder: String? = nil) -> ServerRule? {
        var rule = ServerRule()
        var source = chunk
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
        if let named = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# rule:[") }) {
            let text = named.trimmingCharacters(in: .whitespaces).dropFirst(8)
            rule.name = String(text.hasSuffix("]") ? text.dropLast() : text)
        }
        // A rule turned off: `if false # <test>`.
        if let range = source.range(of: #"if\s+false\s*#\s*"#, options: .regularExpression) {
            rule.isEnabled = false
            source.replaceSubrange(range, with: "if ")
        }
        // Other comments, such as the name, carry no meaning here.
        source = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        guard var tokens = tokens(source), tokens.first == .word("if") else { return nil }
        tokens.removeFirst()
        guard let open = tokens.firstIndex(of: .symbol("{")), tokens.last == .symbol("}") else { return nil }
        let test = Array(tokens[..<open])
        let actions = Array(tokens[(open + 1)..<(tokens.count - 1)])
        guard read(test: test, into: &rule), read(actions: actions, into: &rule, trashFolder: trashFolder, archiveFolder: archiveFolder),
              rule.hasCondition, rule.hasAction else { return nil }
        return rule
    }

    static func read(test: [Token], into rule: inout ServerRule) -> Bool {
        var tests: [[Token]]
        if let first = test.first, first == .word("allof") || first == .word("anyof") {
            guard test.count >= 3, test[1] == .symbol("("), test.last == .symbol(")") else { return false }
            tests = Array(test[2..<(test.count - 1)]).split(separator: .symbol(",")).map(Array.init)
            // "Any of" only means the same as "all of" with a single test.
            if first == .word("anyof"), tests.count > 1 { return false }
        } else {
            tests = [test]
        }
        guard !tests.isEmpty else { return false }
        for single in tests {
            guard read(single: single, into: &rule) else { return false }
        }
        return true
    }

    static func read(single: [Token], into rule: inout ServerRule) -> Bool {
        guard case .word(let command) = single.first, command == "address" || command == "header" else { return false }
        var tags = Set<String>()
        var strings: [[String]] = []
        var index = 1
        while index < single.count {
            switch single[index] {
            case .tag(let tag): tags.insert(tag)
            case .string(let value): strings.append([value])
            case .symbol("["):
                var list: [String] = []
                index += 1
                while index < single.count, single[index] != .symbol("]") {
                    if case .string(let value) = single[index] { list.append(value) } else if single[index] != .symbol(",") { return false }
                    index += 1
                }
                strings.append(list)
            default: return false
            }
            index += 1
        }
        guard tags.contains("contains"), strings.count == 2, strings[1].count == 1 else { return false }
        let fields = Set(strings[0].map { $0.lowercased() })
        let value = strings[1][0]
        let extra = tags.subtracting(["contains", "all", "comparator"])
        if command == "header", tags.contains("mime"), fields == ["content-disposition"], value.lowercased() == "attachment",
           extra.subtracting(["mime", "anychild"]).isEmpty {
            rule.hasAttachment = true
            return true
        }
        guard extra.isEmpty else { return false }
        switch fields {
        case ["from"] where rule.from.isEmpty: rule.from = value
        case ["to"] where rule.to.isEmpty, ["to", "cc"] where rule.to.isEmpty: rule.to = value
        case ["subject"] where command == "header" && rule.subject.isEmpty: rule.subject = value
        case ["content-type"] where command == "header" && value.lowercased() == "multipart/mixed": rule.hasAttachment = true
        default: return false
        }
        return true
    }

    static func read(actions: [Token], into rule: inout ServerRule, trashFolder: String, archiveFolder: String? = nil) -> Bool {
        var keeps = false
        /// Parts Margin would write differently (stopping later rules, forwarding without a
        /// copy, deleting for good): the rule can be removed here, not changed.
        var exact = true
        var copies = false
        for command in actions.split(separator: .symbol(";")).map(Array.init) where !command.isEmpty {
            guard case .word(let name) = command[0] else { return false }
            let strings = command.compactMap { if case .string(let value) = $0 { value } else { nil } }
            let tags = command.compactMap { if case .tag(let tag) = $0 { tag } else { nil } }
            switch name {
            case "fileinto":
                guard strings.count == 1, tags.isEmpty, rule.moveTo == nil, !rule.delete, !rule.archive else { return false }
                if strings[0].caseInsensitiveCompare(trashFolder) == .orderedSame {
                    rule.delete = true
                } else if let archiveFolder, strings[0].caseInsensitiveCompare(archiveFolder) == .orderedSame {
                    rule.archive = true
                } else {
                    rule.moveTo = strings[0]
                }
            case "discard":
                rule.delete = true
                exact = false
            case "addflag":
                guard !strings.isEmpty, tags.isEmpty else { return false }
                for flag in strings {
                    switch flag.lowercased() {
                    case "\\seen": rule.markRead = true
                    case "\\flagged": rule.flag = true
                    default: return false
                    }
                }
            case "redirect":
                guard strings.count == 1, rule.forwardTo.isEmpty, Set(tags).isSubset(of: ["copy"]) else { return false }
                rule.forwardTo = strings[0]
                copies = tags.contains("copy")
            case "keep":
                keeps = true
            case "stop":
                exact = false
            default:
                return false
            }
        }
        // `keep` is only part of forwarding a copy.
        guard !keeps || !rule.forwardTo.isEmpty else { return false }
        if !rule.forwardTo.isEmpty, !copies, !keeps, !rule.delete, !rule.archive, rule.moveTo == nil { exact = false }
        if !exact { rule.isEditable = false }
        return true
    }
}
