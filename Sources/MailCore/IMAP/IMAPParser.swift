import Foundation

/// A value in an IMAP response (RFC 9051 §4).
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case quoted(String)
    case literal([UInt8])
    case list([IMAPValue])
    case none

    /// Text of an atom, quoted string or literal; nil for NIL and lists.
    public var string: String? {
        switch self {
        case .atom(let text), .quoted(let text): text
        case .literal(let bytes): String(decoding: bytes, as: UTF8.self)
        case .list, .none: nil
        }
    }

    public var bytes: [UInt8]? {
        switch self {
        case .literal(let bytes): bytes
        case .quoted(let text), .atom(let text): Array(text.utf8)
        case .list, .none: nil
        }
    }

    public var int: Int? { string.flatMap { Int($0) } }

    public var list: [IMAPValue]? {
        if case .list(let values) = self { return values }
        return nil
    }
}

public enum IMAPStatus: String, Sendable {
    case ok = "OK", no = "NO", bad = "BAD", bye = "BYE", preauth = "PREAUTH"
}

public enum IMAPResponse: Equatable, Sendable {
    /// `* OK …`, `* BYE …`: status text is kept raw, never tokenized.
    case untaggedStatus(IMAPStatus, String)
    /// `* 12 EXISTS`, `* LIST …`, `* 3 FETCH (…)`.
    case untagged([IMAPValue])
    case tagged(tag: String, status: IMAPStatus, text: String)
    case continuation(String)
}

public enum IMAPParser {
    /// Parses one complete response, as framed by `literalLength(endingLine:)`.
    public static func parse(_ bytes: [UInt8]) throws -> IMAPResponse {
        var trimmed = bytes
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        if trimmed.first == UInt8(ascii: "+") {
            return .continuation(text(after: 1, in: trimmed))
        }
        guard let space = trimmed.firstIndex(of: 0x20) else {
            throw MailError.protocolViolation("Response without a tag.")
        }
        let tag = String(decoding: trimmed[..<space], as: UTF8.self)
        let rest = Array(trimmed[(space + 1)...])
        let firstWord = rest.prefix { $0 != 0x20 }
        let status = IMAPStatus(rawValue: String(decoding: firstWord, as: UTF8.self).uppercased())
        if tag == "*" {
            if let status { return .untaggedStatus(status, text(after: firstWord.count, in: rest)) }
            var tokenizer = Tokenizer(bytes: rest)
            return .untagged(try tokenizer.values(closing: nil))
        }
        guard let status else { throw MailError.protocolViolation("Tagged response without a status.") }
        return .tagged(tag: tag, status: status, text: text(after: firstWord.count, in: rest))
    }

    /// If a line ends by announcing a literal (`{123}` or `{123+}`), its byte count.
    /// The reader then takes that many raw bytes and keeps reading the same response.
    public static func literalLength(endingLine line: [UInt8]) -> Int? {
        var end = line.count
        while end > 0, line[end - 1] == 0x0A || line[end - 1] == 0x0D { end -= 1 }
        guard end > 2, line[end - 1] == UInt8(ascii: "}") else { return nil }
        var index = end - 2
        if line[index] == UInt8(ascii: "+") { index -= 1 }
        var digits: [UInt8] = []
        while index >= 0, (0x30...0x39).contains(line[index]) {
            digits.insert(line[index], at: 0)
            index -= 1
        }
        guard index >= 0, line[index] == UInt8(ascii: "{"), !digits.isEmpty else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// Quotes a string for a command, or nil when it needs a literal (line breaks, NUL).
    public static func quoted(_ text: String) -> String? {
        guard !text.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { return nil }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The response code at the start of status text: `[UIDVALIDITY 3857529045] UIDs valid`
    /// → ("UIDVALIDITY", "3857529045"). `[NOMODSEQ] …` → ("NOMODSEQ", "").
    public static func responseCode(_ text: String) -> (name: String, value: String)? {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let parts = text[text.index(after: text.startIndex)..<close].split(separator: " ", maxSplits: 1)
        guard let name = parts.first else { return nil }
        return (name.uppercased(), parts.count > 1 ? String(parts[1]) : "")
    }

    /// A UID set without `*`, as in VANISHED (`41,43:116`), as ranges.
    public static func ranges(_ set: String) -> [ClosedRange<Int>] {
        set.split(separator: ",").compactMap { part in
            let ends = part.split(separator: ":").compactMap { Int($0) }
            guard let first = ends.first else { return nil }
            let last = ends.count > 1 ? ends[1] : first
            return min(first, last)...max(first, last)
        }
    }

    private static func text(after count: Int, in bytes: [UInt8]) -> String {
        guard count < bytes.count else { return "" }
        return String(decoding: bytes[count...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

/// Splits response bytes into values. Atoms keep bracketed sections whole, so
/// `BODY[HEADER.FIELDS (LIST-ID)]` stays one atom.
struct Tokenizer {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func values(closing: UInt8?) throws -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            while index < bytes.count, bytes[index] == 0x20 { index += 1 }
            guard index < bytes.count, bytes[index] != 0x0D, bytes[index] != 0x0A else {
                if closing != nil { throw MailError.protocolViolation("Unclosed list.") }
                return values
            }
            switch bytes[index] {
            case UInt8(ascii: "("):
                index += 1
                values.append(.list(try self.values(closing: UInt8(ascii: ")"))))
            case UInt8(ascii: ")"):
                guard closing == UInt8(ascii: ")") else { throw MailError.protocolViolation("Unexpected “)”.") }
                index += 1
                return values
            case UInt8(ascii: "\""):
                values.append(.quoted(try quotedString()))
            case UInt8(ascii: "{"):
                values.append(.literal(try literal()))
            default:
                let atom = self.atom()
                values.append(atom.uppercased() == "NIL" ? .none : .atom(atom))
            }
        }
    }

    private mutating func quotedString() throws -> String {
        index += 1
        var out: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                out.append(bytes[index + 1])
                index += 2
                continue
            }
            index += 1
            if byte == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
            out.append(byte)
        }
        throw MailError.protocolViolation("Unclosed quoted string.")
    }

    private mutating func literal() throws -> [UInt8] {
        index += 1
        var digits: [UInt8] = []
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            digits.append(bytes[index])
            index += 1
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "}"),
              let count = Int(String(decoding: digits, as: UTF8.self)) else {
            throw MailError.protocolViolation("Malformed literal.")
        }
        index += 1
        if index < bytes.count, bytes[index] == 0x0D { index += 1 }
        if index < bytes.count, bytes[index] == 0x0A { index += 1 }
        guard index + count <= bytes.count else { throw MailError.protocolViolation("Literal shorter than announced.") }
        let value = Array(bytes[index..<(index + count)])
        index += count
        return value
    }

    private mutating func atom() -> String {
        var out: [UInt8] = []
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "[") { depth += 1 }
            if byte == UInt8(ascii: "]") { depth = max(0, depth - 1) }
            if depth == 0 {
                let stops: [UInt8] = [0x20, 0x0D, 0x0A, UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\""), UInt8(ascii: "{")]
                if stops.contains(byte) && byte != UInt8(ascii: "]") { break }
            }
            out.append(byte)
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
