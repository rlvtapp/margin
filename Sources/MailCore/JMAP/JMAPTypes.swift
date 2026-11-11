import Foundation

struct JMAPSession: Sendable {
    var apiURL: URL
    var accountID: String
    /// RFC 8620 URL templates for blobs: `{accountId}`, `{blobId}`, `{type}`, `{name}`.
    var uploadURL: String = ""
    var downloadURL: String = ""

    static func parse(_ data: Data) throws -> JMAPSession {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let api = (object["apiUrl"] as? String).flatMap(URL.init(string:)),
              let primary = object["primaryAccounts"] as? [String: Any],
              let accountID = primary["urn:ietf:params:jmap:mail"] as? String else {
            throw MailError.protocolViolation("The JMAP session has no mail account.")
        }
        return JMAPSession(apiURL: api, accountID: accountID,
                           uploadURL: object["uploadUrl"] as? String ?? "", downloadURL: object["downloadUrl"] as? String ?? "")
    }
}

/// One method response: `[name, arguments, callId]`.
struct JMAPResponse: @unchecked Sendable {
    var name: String
    var arguments: [String: Any]
    var callID: String

    static func parse(_ data: Data) throws -> [JMAPResponse] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = object["methodResponses"] as? [[Any]] else {
            throw MailError.protocolViolation("Malformed JMAP response.")
        }
        return try responses.map { item in
            guard item.count == 3, let name = item[0] as? String, let arguments = item[1] as? [String: Any],
                  let callID = item[2] as? String else {
                throw MailError.protocolViolation("Malformed JMAP method response.")
            }
            if name == "error" {
                throw MailError.serverRejected((arguments["description"] as? String) ?? (arguments["type"] as? String) ?? "JMAP error")
            }
            return JMAPResponse(name: name, arguments: arguments, callID: callID)
        }
    }
}

enum JMAPEmail {
    static let listProperties = [
        "id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "subject", "receivedAt", "sentAt",
        "preview", "hasAttachment", "messageId", "inReplyTo", "references", "header:List-Id:asText",
        "header:List-Unsubscribe:asText", "header:Auto-Submitted:asText", "header:Precedence:asText",
        "header:X-MS-Reactions:asText",
    ] + InboxSplit.bulkHeaders.map { "header:\($0):asText" }

    static func message(from email: [String: Any], folders: [Mailbox], fallbackMailbox: String) -> MailMessage? {
        guard let id = email["id"] as? String else { return nil }
        let keywords = email["keywords"] as? [String: Bool] ?? [:]
        var flags: MessageFlags = []
        if keywords["$seen"] == true { flags.insert(.seen) }
        if keywords["$flagged"] == true { flags.insert(.flagged) }
        if keywords["$answered"] == true { flags.insert(.answered) }
        if keywords["$draft"] == true { flags.insert(.draft) }
        let mailboxIDs = (email["mailboxIds"] as? [String: Bool])?.keys.sorted() ?? []
        var headers: [String: String] = [:]
        for (key, name) in [("header:List-Id:asText", "list-id"), ("header:List-Unsubscribe:asText", "list-unsubscribe"),
                            ("header:Auto-Submitted:asText", "auto-submitted"), ("header:Precedence:asText", "precedence"),
                            ("header:X-MS-Reactions:asText", "x-ms-reactions")] {
            if let value = email[key] as? String { headers[name] = value }
        }
        for name in InboxSplit.bulkHeaders {
            if let value = email["header:\(name):asText"] as? String { headers[name] = value }
        }
        if let thread = email["threadId"] as? String { headers["x-jmap-thread"] = thread }
        let date = (email["receivedAt"] as? String).flatMap(parseDate) ?? (email["sentAt"] as? String).flatMap(parseDate) ?? .distantPast
        return MailMessage(
            id: id,
            mailboxID: mailboxIDs.contains(fallbackMailbox) ? fallbackMailbox : (mailboxIDs.first ?? fallbackMailbox),
            messageID: (email["messageId"] as? [String])?.first,
            inReplyTo: (email["inReplyTo"] as? [String])?.first,
            references: email["references"] as? [String] ?? [],
            from: addresses(email["from"]).first ?? EmailAddress(address: "unknown@unknown"),
            to: addresses(email["to"]),
            cc: addresses(email["cc"]),
            subject: email["subject"] as? String ?? "",
            date: date,
            snippet: email["preview"] as? String ?? "",
            flags: flags,
            hasAttachments: email["hasAttachment"] as? Bool ?? false,
            listHeaders: headers
        )
    }

    static func body(from email: [String: Any]) -> MessageBody {
        let values = email["bodyValues"] as? [String: [String: Any]] ?? [:]
        func text(of parts: Any?) -> String? {
            let ids = (parts as? [[String: Any]] ?? []).compactMap { $0["partId"] as? String }
            let joined = ids.compactMap { values[$0]?["value"] as? String }.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        let html = text(of: email["htmlBody"])
        let plain = text(of: email["textBody"]) ?? html.map(HTMLText.plain) ?? ""
        let attachments = (email["attachments"] as? [[String: Any]] ?? []).map {
            AttachmentInfo(filename: $0["name"] as? String ?? "Attachment", mimeType: $0["type"] as? String ?? "application/octet-stream",
                           size: $0["size"] as? Int, blobID: $0["blobId"] as? String,
                           contentID: ($0["cid"] as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) })
        }
        return MessageBody(text: plain, html: html, attachments: attachments)
    }

    static func addresses(_ value: Any?) -> [EmailAddress] {
        (value as? [[String: Any]] ?? []).compactMap {
            guard let email = $0["email"] as? String else { return nil }
            return EmailAddress(name: $0["name"] as? String, address: email)
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
