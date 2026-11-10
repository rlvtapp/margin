import Foundation

/// RFC 2047 encoded words in headers: `=?UTF-8?B?…?=` and `=?ISO-8859-1?Q?…?=`.
public enum MIMEWords {
    public static func decode(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        var lastWasEncoded = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between two encoded words is not part of the text.
            if !(lastWasEncoded && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += between
            }
            let charset = ns.substring(with: match.range(at: 1))
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes: [UInt8]? = mode == "B"
                ? Data(base64Encoded: padded(payload)).map(Array.init)
                : QuotedPrintable.decode(payload.replacingOccurrences(of: "_", with: " "))
            if let bytes {
                result += Charset.string(from: bytes, charset: charset)
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            lastWasEncoded = true
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Encodes as one UTF-8 B word when the text isn't plain ASCII.
    public static func encodeIfNeeded(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return text }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    private static func padded(_ base64: String) -> String {
        var text = base64
        while text.count % 4 != 0 { text.append("=") }
        return text
    }
}

public enum QuotedPrintable {
    public static func decode(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "=") else {
                out.append(byte)
                index += 1
                continue
            }
            // Soft line break.
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
            if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
            if index + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                out.append(value)
                index += 3
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out
    }

    /// Encodes UTF-8 text with lines of at most 76 characters.
    public static func encode(_ text: String) -> String {
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var encoded = ""
            var length = 0
            let bytes = Array(line.utf8)
            for (offset, byte) in bytes.enumerated() {
                let isLast = offset == bytes.count - 1
                let safe = (byte >= 33 && byte <= 126 && byte != UInt8(ascii: "=")) || ((byte == 0x20 || byte == 0x09) && !isLast)
                let piece = safe ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                if length + piece.count > 75 {
                    encoded += "=\r\n"
                    length = 0
                }
                encoded += piece
                length += piece.count
            }
            lines.append(encoded)
        }
        return lines.joined(separator: "\r\n")
    }
}

enum Charset {
    static func string(from bytes: [UInt8], charset: String?) -> String {
        let name = (charset ?? "utf-8").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if name == "utf-8" || name == "utf8" || name == "us-ascii" {
            return String(decoding: bytes, as: UTF8.self)
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            if let text = String(data: Data(bytes), encoding: encoding) { return text }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum MessageIDs {
    /// `<a@b> <c@d>` → ["a@b", "c@d"] (without angle brackets).
    public static func parse(_ text: String) -> [String] {
        var ids: [String] = []
        var current: String?
        for char in text {
            if char == "<" { current = "" } else if char == ">" {
                if let id = current, !id.isEmpty { ids.append(id) }
                current = nil
            } else if current != nil { current!.append(char) }
        }
        if ids.isEmpty {
            let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if bare.contains("@") && !bare.contains(" ") { ids.append(bare) }
        }
        return ids
    }
}

public enum MailDate {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yy HH:mm:ss Z",
    ]

    /// RFC 5322 dates, with the comment some servers append ("(UTC)") removed.
    public static func parse(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comment = value.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            value.removeSubrange(comment)
        }
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// IMAP INTERNALDATE: `17-Jul-1996 02:44:25 -0700`.
    static func parseInternal(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    public static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
