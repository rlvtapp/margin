import Foundation

/// A To, Cc or Bcc line as people and the bit still being typed. The composer keeps each line as
/// header text (`Maya <maya@example.com>, sam@example.com`); this turns that into separate
/// recipients for the field's badges and back, so what's stored never comes out malformed.
public enum RecipientList {
    /// The complete addresses in a line, and whatever is left that isn't one yet.
    public static func parse(_ text: String) -> (recipients: [EmailAddress], pending: String) {
        var recipients: [EmailAddress] = []
        var rest: [String] = []
        for part in parts(of: text) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let address = EmailAddress.parseOne(trimmed) {
                add(address, to: &recipients)
            } else {
                rest.append(trimmed)
            }
        }
        return (recipients, rest.joined(separator: ", "))
    }

    /// The line as header text: every recipient, then what's being typed (so sending still
    /// catches an address that was typed but never finished).
    public static func text(_ recipients: [EmailAddress], pending: String = "") -> String {
        let typed = pending.trimmingCharacters(in: .whitespaces)
        return (recipients.map(\.headerValue) + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }

    /// What typing has finished: an address followed by a comma, a semicolon or a space becomes a
    /// recipient, and so does everything pasted in as a list. `force` also takes the last piece
    /// (Return, Tab, or leaving the field). Anything that isn't an address stays as typed.
    public static func commit(_ typed: String, force: Bool = false) -> (added: [EmailAddress], pending: String) {
        var pieces = parts(of: typed)
        // A space closes a plain address ("sam@example.com "), but not a name still being typed.
        let endsWithSpace = typed.last == " " || typed.last == "\n"
        let closesLast = force || (endsWithSpace && EmailAddress.isValid(typed.trimmingCharacters(in: .whitespacesAndNewlines)))
        let last = closesLast ? nil : pieces.popLast()
        var added: [EmailAddress] = []
        var rest: [String] = []
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let address = EmailAddress.parseOne(trimmed) {
                add(address, to: &added)
            } else {
                rest.append(trimmed)
            }
        }
        if let last {
            // Still typing this one: it keeps its spaces, apart from any it starts with.
            let kept = String(last.drop { $0 == " " })
            if !kept.isEmpty || rest.isEmpty { rest.append(kept) }
        }
        return (added, rest.joined(separator: ", "))
    }

    /// `more` added to `recipients`, without anyone twice.
    public static func adding(_ more: [EmailAddress], to recipients: [EmailAddress]) -> [EmailAddress] {
        var result = recipients
        for address in more { add(address, to: &result) }
        return result
    }

    private static func add(_ address: EmailAddress, to list: inout [EmailAddress]) {
        guard !list.contains(where: { $0.address.lowercased() == address.address.lowercased() }) else { return }
        list.append(address)
    }

    /// Split at commas and semicolons, except inside quotes or angle brackets.
    private static func parts(of text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for char in text {
            switch char {
            case "\"": inQuotes.toggle(); current.append(char)
            case "<": inAngle = true; current.append(char)
            case ">": inAngle = false; current.append(char)
            case _ where (char == "," || char == ";") && !inQuotes && !inAngle:
                parts.append(current)
                current = ""
            default: current.append(char)
            }
        }
        parts.append(current)
        return parts
    }
}
