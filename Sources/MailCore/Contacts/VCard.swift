import Foundation

/// Reads the parts of vCard 3.0 and 4.0 text that address completion needs.
public enum VCard {
    /// One card: its UID, display name, email addresses and organization.
    public struct ParsedCard: Hashable, Sendable {
        public var uid: String?
        public var name: String?
        public var emails: [String]
        public var organization: String?

        public init(uid: String? = nil, name: String? = nil, emails: [String] = [], organization: String? = nil) {
            self.uid = uid
            self.name = name
            self.emails = emails
            self.organization = organization
        }

        /// The card as a contact with the given id and source.
        public func contact(id: String, source: ContactSource) -> Contact {
            Contact(id: id, name: name, emails: emails, organization: organization, source: source)
        }
    }

    /// Every card in the text, in order. Cards nested inside another card are skipped.
    public static func parse(_ text: String) -> [ParsedCard] {
        var cards: [ParsedCard] = []
        var current: Card?
        var depth = 0
        for line in unfold(text) {
            guard let property = Property(line: line) else { continue }
            switch property.name {
            case "BEGIN" where property.rawValue.uppercased() == "VCARD":
                depth += 1
                if depth == 1 { current = Card() }
            case "END" where property.rawValue.uppercased() == "VCARD":
                if depth == 1, let card = current { cards.append(card.parsed) }
                depth = max(0, depth - 1)
                if depth == 0 { current = nil }
            default:
                if depth == 1 { current?.read(property) }
            }
        }
        return cards
    }

    /// Joins folded lines: a line break followed by a space or tab continues the previous line.
    static func unfold(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else {
                lines.append(String(line))
            }
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Splits a value on separators that aren't escaped with a backslash, then unescapes each part.
    static func components(_ value: String, separator: Character = ";") -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                parts.append(unescape(current))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        parts.append(unescape(current))
        return parts
    }

    /// Turns `\n`, `\,`, `\;` and `\\` back into the characters they stand for.
    static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private struct Property {
        /// Upper-cased, without any group prefix such as `item1.`.
        var name: String
        var rawValue: String

        init?(line: String) {
            var inQuotes = false
            var colon: String.Index?
            for index in line.indices {
                let character = line[index]
                if character == "\"" { inQuotes.toggle() }
                if character == ":" && !inQuotes { colon = index; break }
            }
            guard let colon else { return nil }
            let head = line[..<colon]
            let fullName = head.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let bareName = fullName.split(separator: ".").last.map(String.init) ?? fullName
            name = bareName.trimmingCharacters(in: .whitespaces).uppercased()
            rawValue = String(line[line.index(after: colon)...])
        }
    }

    private struct Card {
        var uid: String?
        var formattedName: String?
        var structuredName: String?
        var emails: [String] = []
        var organization: String?

        mutating func read(_ property: Property) {
            switch property.name {
            case "UID":
                uid = VCard.unescape(property.rawValue).cardTrimmed
            case "FN":
                formattedName = VCard.unescape(property.rawValue).cardTrimmed
            case "N":
                // Family; Given; Additional; Prefixes; Suffixes
                let parts = VCard.components(property.rawValue)
                let ordered = [1, 2, 0].compactMap { parts.indices.contains($0) ? parts[$0].cardTrimmed : nil }
                structuredName = ordered.joined(separator: " ").cardTrimmed
            case "EMAIL":
                var email = VCard.unescape(property.rawValue).cardTrimmed ?? ""
                if email.lowercased().hasPrefix("mailto:") { email = String(email.dropFirst(7)) }
                if !email.isEmpty, !emails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
                    emails.append(email)
                }
            case "ORG":
                organization = VCard.components(property.rawValue).first?.cardTrimmed
            default:
                break
            }
        }

        var parsed: ParsedCard {
            ParsedCard(uid: uid, name: formattedName ?? structuredName, emails: emails, organization: organization)
        }
    }
}

private extension String {
    /// Trimmed, or nil when nothing is left.
    var cardTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
