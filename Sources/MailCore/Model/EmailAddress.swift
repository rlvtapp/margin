import Foundation

/// One mailbox address, with an optional display name.
public struct EmailAddress: Hashable, Codable, Sendable {
    public var name: String?
    public var address: String

    public init(name: String? = nil, address: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        self.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.address = address.trimmingCharacters(in: .whitespaces)
    }

    /// The name if there is one, otherwise the part before the @.
    public var displayName: String {
        if let name { return name }
        return address.split(separator: "@").first.map(String.init) ?? address
    }

    /// Lowercased part before the @, used for sender heuristics.
    public var localPart: String {
        address.split(separator: "@").first.map { $0.lowercased() } ?? ""
    }

    public var domain: String {
        address.split(separator: "@").last.map { $0.lowercased() } ?? ""
    }

    /// `"Name" <address>` as written in a header.
    public var headerValue: String {
        guard let name else { return address }
        let needsQuotes = name.contains { ",;<>\"@:()[]".contains($0) }
        let quoted = needsQuotes ? "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"" : name
        return "\(MIMEWords.encodeIfNeeded(quoted)) <\(address)>"
    }

    /// Parses a typed list such as `Maya <maya@example.com>, sam@example.com`.
    /// Returns nil when any entry isn't an address.
    public static func parseList(_ text: String) -> [EmailAddress]? {
        var result: [EmailAddress] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for char in text {
            switch char {
            case "\"": inQuotes.toggle(); current.append(char)
            case "<": inAngle = true; current.append(char)
            case ">": inAngle = false; current.append(char)
            case _ where (char == "," || char == ";") && !inQuotes && !inAngle:
                if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let address = parseOne(current) else { return nil }
                    result.append(address)
                }
                current = ""
            default: current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let address = parseOne(current) else { return nil }
            result.append(address)
        }
        return result
    }

    static func parseOne(_ raw: String) -> EmailAddress? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let address = String(text[text.index(after: open)..<close])
            let name = String(text[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return isValid(address) ? EmailAddress(name: name, address: address) : nil
        }
        return isValid(text) ? EmailAddress(address: text) : nil
    }

    public static func isValid(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(" ")
    }
}
