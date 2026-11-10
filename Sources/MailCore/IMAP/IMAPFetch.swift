import Foundation

/// The attributes of one `* n FETCH (…)` response.
struct IMAPFetchItem: Sendable {
    var sequence: Int
    var uid: Int?
    var flags: MessageFlags = []
    /// Whether the response carried FLAGS at all, so a missing list isn't read as "no flags".
    var hasFlags = false
    /// The message's mod-sequence (RFC 7162), when CONDSTORE is on.
    var modSeq: Int?
    var envelope: IMAPEnvelope?
    var size: Int?
    var internalDate: Date?
    /// `BODY[…]` sections by their section text (`HEADER.FIELDS (LIST-ID)`, ``, `TEXT`).
    var sections: [String: [UInt8]] = [:]
    var bodyStructureHasAttachment = false
    /// The part a preview is read from, found in BODYSTRUCTURE.
    var textPart: IMAPTextPart?

    init?(_ values: [IMAPValue]) {
        guard values.count >= 3, let sequence = values[0].int,
              values[1].string?.uppercased() == "FETCH", let attributes = values[2].list else { return nil }
        self.sequence = sequence
        var index = 0
        while index + 1 < attributes.count {
            let key = attributes[index].string?.uppercased() ?? ""
            let value = attributes[index + 1]
            index += 2
            switch key {
            case "UID": uid = value.int
            case "FLAGS":
                flags = Self.flags(value.list ?? [])
                hasFlags = true
            case "MODSEQ": modSeq = value.list?.first?.int
            case "ENVELOPE": envelope = value.list.flatMap(IMAPEnvelope.init)
            case "RFC822.SIZE": size = value.int
            case "INTERNALDATE": internalDate = value.string.flatMap(MailDate.parseInternal)
            case "BODYSTRUCTURE", "BODY":
                bodyStructureHasAttachment = Self.containsAttachment(value)
                textPart = IMAPTextPart.find(in: value)
            default:
                if key.hasPrefix("BODY[") || key.hasPrefix("BINARY[") {
                    let open = key.firstIndex(of: "[")!
                    let close = key.lastIndex(of: "]") ?? key.endIndex
                    let section = String(key[key.index(after: open)..<close])
                    sections[section] = value.bytes ?? []
                }
            }
        }
    }

    /// True when any part's disposition is "attachment".
    static func containsAttachment(_ value: IMAPValue) -> Bool {
        guard let items = value.list else { return false }
        if items.count >= 2, items[0].string?.lowercased() == "attachment", items[1].list != nil || items[1] == .none {
            return true
        }
        return items.contains(where: containsAttachment)
    }

    static func flags(_ values: [IMAPValue]) -> MessageFlags {
        var flags: MessageFlags = []
        for value in values {
            switch value.string?.lowercased() {
            case "\\seen": flags.insert(.seen)
            case "\\flagged": flags.insert(.flagged)
            case "\\answered": flags.insert(.answered)
            case "\\draft": flags.insert(.draft)
            default: break
            }
        }
        return flags
    }
}

/// The part of a message its preview comes from: the first plain-text part, or else the first
/// HTML one, with what's needed to decode a few hundred bytes of it.
struct IMAPTextPart: Hashable, Sendable {
    /// The IMAP section ("1", "1.2"); a single-part message's body is section 1.
    var section: String
    var isHTML: Bool
    var encoding: String?
    var charset: String?

    /// How many bytes to fetch: HTML spends its first kilobytes on styles.
    var previewBytes: Int { isHTML ? 6144 : 768 }

    static func find(in value: IMAPValue) -> IMAPTextPart? {
        var plain: IMAPTextPart?
        var html: IMAPTextPart?
        func walk(_ value: IMAPValue, path: [Int]) {
            guard let items = value.list, !items.isEmpty else { return }
            if items[0].list != nil {
                // Multipart: the leading lists are the parts.
                for (index, child) in items.enumerated() where child.list != nil { walk(child, path: path + [index + 1]) }
                return
            }
            guard items.count >= 6, items[0].string?.lowercased() == "text",
                  !IMAPFetchItem.containsAttachment(value) else { return }
            let subtype = items[1].string?.lowercased()
            var params: [String: String] = [:]
            let list = items[2].list ?? []
            for pair in stride(from: 0, to: list.count - 1, by: 2) {
                if let key = list[pair].string?.lowercased() { params[key] = list[pair + 1].string }
            }
            let part = IMAPTextPart(section: path.isEmpty ? "1" : path.map(String.init).joined(separator: "."),
                                    isHTML: subtype == "html", encoding: items[5].string, charset: params["charset"])
            if subtype == "plain", plain == nil { plain = part }
            if subtype == "html", html == nil { html = part }
        }
        walk(value, path: [])
        return plain ?? html
    }

    /// A one-line preview from the start of the part.
    func preview(from bytes: [UInt8]) -> String {
        var raw = bytes
        if encoding?.lowercased() == "base64" {
            // A cut-off base64 run only decodes in whole groups of four.
            let compact = bytes.filter { !($0 == 10 || $0 == 13 || $0 == 32 || $0 == 9) }
            raw = Array(compact.prefix(compact.count / 4 * 4))
        }
        let text = Charset.string(from: MIMEMessage.decode(raw, encoding: encoding), charset: charset)
        return HTMLText.snippet(isHTML ? HTMLText.plain(text) : HTMLText.decodeEntities(text))
    }
}

/// ENVELOPE: date, subject, from, sender, reply-to, to, cc, bcc, in-reply-to, message-id.
struct IMAPEnvelope: Sendable {
    var date: Date?
    var subject: String
    var from: [EmailAddress]
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var inReplyTo: String?
    var messageID: String?

    init?(_ values: [IMAPValue]) {
        guard values.count >= 10 else { return nil }
        date = values[0].string.flatMap(MailDate.parse)
        subject = MIMEWords.decode(values[1].string ?? "")
        from = Self.addresses(values[2])
        to = Self.addresses(values[5])
        cc = Self.addresses(values[6])
        inReplyTo = values[8].string.flatMap { MessageIDs.parse($0).first }
        messageID = values[9].string.flatMap { MessageIDs.parse($0).first }
    }

    /// Each address is (name adl mailbox host). Group markers (host NIL) are skipped.
    static func addresses(_ value: IMAPValue) -> [EmailAddress] {
        (value.list ?? []).compactMap { item in
            guard let parts = item.list, parts.count >= 4,
                  let mailbox = parts[2].string, let host = parts[3].string else { return nil }
            let name = parts[0].string.map(MIMEWords.decode)
            return EmailAddress(name: name, address: "\(mailbox)@\(host)")
        }
    }
}

/// `* LIST (\HasNoChildren \Sent) "/" "Sent Items"`
struct IMAPListItem: Sendable {
    var attributes: [String]
    var name: String
    /// The hierarchy delimiter ("/" or "."), when the server uses one.
    var delimiter: String?

    init?(_ values: [IMAPValue]) {
        guard values.count >= 4, values[0].string?.uppercased() == "LIST",
              let attributes = values[1].list, let name = values[3].string else { return nil }
        self.attributes = attributes.compactMap { $0.string?.lowercased() }
        self.name = name
        self.delimiter = values[2].string.flatMap { $0.isEmpty || $0.uppercased() == "NIL" ? nil : $0 }
    }

    /// "Projects/2026" → "Projects".
    var parent: String? {
        guard let delimiter, let range = name.range(of: delimiter, options: .backwards) else { return nil }
        return String(name[..<range.lowerBound])
    }

    /// "Projects/2026" → "2026".
    var shortName: String {
        guard let delimiter, let range = name.range(of: delimiter, options: .backwards) else { return name }
        return String(name[range.upperBound...])
    }

    var isSelectable: Bool { !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent") }

    /// RFC 6154 special-use attributes first, then common names.
    var role: MailboxRole {
        if name.uppercased() == "INBOX" { return .inbox }
        let byAttribute: [String: MailboxRole] = [
            "\\sent": .sent, "\\drafts": .drafts, "\\archive": .archive, "\\trash": .trash,
            "\\junk": .junk, "\\all": .all, "\\flagged": .flagged,
        ]
        for attribute in attributes { if let role = byAttribute[attribute] { return role } }
        let leaf = (name.split(separator: "/").last ?? Substring(name)).lowercased()
        switch leaf {
        case "sent", "sent items", "sent mail", "sent messages": return .sent
        case "drafts": return .drafts
        case "archive", "archives": return .archive
        case "trash", "deleted items", "deleted messages", "bin": return .trash
        case "junk", "spam", "junk e-mail", "junk email": return .junk
        default: return .other
        }
    }
}

/// Modified UTF-7 for mailbox names (RFC 3501 §5.1.3): `&AOk-t&AOk-` is "été".
enum ModifiedUTF7 {
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            guard char == "&", let end = text[index...].firstIndex(of: "-") else {
                result.append(char)
                index = text.index(after: index)
                continue
            }
            let encoded = text[text.index(after: index)..<end]
            if encoded.isEmpty {
                result.append("&")
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64.append("=") }
                if let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf16BigEndian) {
                    result += decoded
                } else {
                    result += text[index...end]
                }
            }
            index = text.index(after: end)
        }
        return result
    }
}
