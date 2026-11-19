import Foundation

/// A folder as Graph lists it (`mailFolder`).
struct GraphFolder: Decodable, Sendable {
    var id: String
    var displayName: String?
    var parentFolderId: String?
    var unreadItemCount: Int?
    var childFolderCount: Int?
}

/// A message as Graph lists it. Delta pages carry only some of the fields, and `@removed` for
/// messages that left the folder.
struct GraphMessage: Decodable, Sendable {
    var id: String
    var odataType: String?
    var conversationId: String?
    var internetMessageId: String?
    var subject: String?
    var bodyPreview: String?
    var receivedDateTime: String?
    var sentDateTime: String?
    var isRead: Bool?
    var isDraft: Bool?
    var hasAttachments: Bool?
    var flag: Flag?
    var categories: [String]?
    var from: GraphMailRecipient?
    var toRecipients: [GraphMailRecipient]?
    var ccRecipients: [GraphMailRecipient]?
    var parentFolderId: String?
    var internetMessageHeaders: [Header]?
    var body: Body?
    var removed: Removed?

    struct Flag: Decodable, Sendable { var flagStatus: String? }
    struct Header: Decodable, Sendable { var name: String; var value: String }
    struct Body: Decodable, Sendable { var contentType: String?; var content: String? }
    struct Removed: Decodable, Sendable { var reason: String? }

    enum CodingKeys: String, CodingKey {
        case id, conversationId, internetMessageId, subject, bodyPreview, receivedDateTime, sentDateTime, isRead, isDraft
        case hasAttachments, flag, categories, from, toRecipients, ccRecipients, parentFolderId, internetMessageHeaders, body
        case odataType = "@odata.type"
        case removed = "@removed"
    }

    /// What the message list asks for.
    static let listFields = [
        "id", "conversationId", "internetMessageId", "subject", "bodyPreview", "receivedDateTime", "sentDateTime",
        "isRead", "isDraft", "hasAttachments", "flag", "categories", "from", "toRecipients", "ccRecipients",
        "parentFolderId", "internetMessageHeaders",
    ].joined(separator: ",")

    /// What a delta page asks for: enough to update flags; new messages are then read whole.
    static let deltaFields = ["id", "isRead", "flag", "categories", "parentFolderId", "receivedDateTime"].joined(separator: ",")

    var flags: MessageFlags {
        var flags: MessageFlags = []
        if isRead == true { flags.insert(.seen) }
        if flag?.flagStatus?.lowercased() == "flagged" { flags.insert(.flagged) }
        if isDraft == true { flags.insert(.draft) }
        return flags
    }

    var date: Date {
        receivedDateTime.flatMap(JMAPEmail.parseDate) ?? sentDateTime.flatMap(JMAPEmail.parseDate) ?? .distantPast
    }

    /// The calendar METHOD an Outlook meeting message stands for (see `MailMessage.calendarMethod`).
    var calendarMethod: String? {
        switch odataType {
        case "#microsoft.graph.eventMessageRequest": "REQUEST"
        case "#microsoft.graph.eventMessageResponse": "REPLY"
        case "#microsoft.graph.eventMessage": ""
        default: nil
        }
    }

    /// The header fields the triage rules read, lowercased, with threading's own.
    var headers: [String: String] {
        var found: [String: String] = [:]
        let kept = Set(["list-id", "list-unsubscribe", "auto-submitted", "precedence", "x-ms-reactions", "in-reply-to", "references"]
            + InboxSplit.bulkHeaders)
        for header in internetMessageHeaders ?? [] where kept.contains(header.name.lowercased()) {
            found[header.name.lowercased()] = header.value
        }
        return found
    }

    /// The message as seen from a folder; "" takes the folder Graph names (search results).
    func message(in mailboxID: String) -> MailMessage {
        var listHeaders = headers
        let inReplyTo = listHeaders.removeValue(forKey: "in-reply-to")?.trimmingCharacters(in: .whitespaces)
        let references = (listHeaders.removeValue(forKey: "references") ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var message = MailMessage(
            id: id, mailboxID: mailboxID.isEmpty ? (parentFolderId ?? "") : mailboxID, messageID: internetMessageId,
            inReplyTo: inReplyTo?.isEmpty == false ? inReplyTo : nil, references: references,
            from: from?.address ?? EmailAddress(address: "unknown@unknown"),
            to: (toRecipients ?? []).compactMap(\.address), cc: (ccRecipients ?? []).compactMap(\.address),
            subject: subject ?? "", date: date, snippet: bodyPreview.map(HTMLText.cleanedPreview) ?? "",
            flags: flags, hasAttachments: hasAttachments ?? false, listHeaders: listHeaders, calendarMethod: calendarMethod
        )
        // Outlook's categories are the mailbox's labels: plain names, never folders.
        message.labels = categories ?? []
        message.threadID = conversationId
        return message
    }

    /// Takes the flags and categories of a delta entry into a message already known.
    func update(_ message: inout MailMessage) {
        if let isRead {
            if isRead { message.flags.insert(.seen) } else { message.flags.remove(.seen) }
        }
        if let status = flag?.flagStatus {
            if status.lowercased() == "flagged" { message.flags.insert(.flagged) } else { message.flags.remove(.flagged) }
        }
        if let categories { message.labels = categories }
    }
}

struct GraphMailRecipient: Decodable, Sendable {
    var emailAddress: Inner?
    struct Inner: Decodable, Sendable { var name: String?; var address: String? }

    var address: EmailAddress? {
        guard let address = emailAddress?.address, !address.isEmpty else { return nil }
        let name = emailAddress?.name?.trimmingCharacters(in: .whitespaces)
        return EmailAddress(name: name?.isEmpty == false && name != address ? name : nil, address: address)
    }

    static func json(_ address: EmailAddress) -> [String: Any] {
        var inner: [String: Any] = ["address": address.address]
        if let name = address.name, !name.isEmpty { inner["name"] = name }
        return ["emailAddress": inner]
    }
}

/// A page of a delta query: more to come (`nextLink`), or the link for next time (`deltaLink`).
struct GraphDeltaPage: Decodable, Sendable {
    var value: [GraphMessage]
    var nextLink: String?
    var deltaLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }
}

/// A folder's newest mail as last seen, and where its changes continue from.
struct GraphFolderList: Sendable {
    var messages: [String: MailMessage] = [:]
    var deltaLink: String?
    var limit: Int
}

/// One request of a JSON batch (at most 20 go together).
struct GraphBatchItem: Sendable {
    var id: String
    var method: String
    /// Relative to the API version: "/me/messages/…".
    var url: String
    var body: [String: any Sendable]?
}
