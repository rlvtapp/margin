import Foundation

/// What a folder is for. Providers name folders differently ("Sent Items",
/// "[Gmail]/Sent Mail"); the role is what the app relies on.
public enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox, sent, drafts, archive, trash, junk, all, flagged, other
}

public struct Mailbox: Identifiable, Hashable, Codable, Sendable {
    /// The provider's own name or id, used verbatim in protocol commands.
    public var id: String
    /// The name to show.
    public var name: String
    public var role: MailboxRole
    public var unreadCount: Int?
    /// The folder this one sits inside, by id; nil at the top level.
    public var parentID: String?

    public init(id: String, name: String, role: MailboxRole, unreadCount: Int? = nil, parentID: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.unreadCount = unreadCount
        self.parentID = parentID
    }

    /// Folders in tree order (each followed by the folders inside it) with how deep each sits.
    /// `order` is the person's own order of folder ids; folders not in it keep name order.
    public static func tree(_ folders: [Mailbox], order: [String] = []) -> [(mailbox: Mailbox, depth: Int)] {
        let ids = Set(folders.map(\.id))
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func sorted(_ list: [Mailbox]) -> [Mailbox] {
            list.sorted { (rank[$0.id] ?? Int.max, $0.name.lowercased()) < (rank[$1.id] ?? Int.max, $1.name.lowercased()) }
        }
        let children = Dictionary(grouping: folders) { $0.parentID.flatMap { ids.contains($0) ? $0 : nil } ?? "" }
        var result: [(Mailbox, Int)] = []
        func walk(_ parent: String, depth: Int) {
            for folder in sorted(children[parent] ?? []) {
                result.append((folder, depth))
                walk(folder.id, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        return result
    }
}

public struct MessageFlags: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let seen = MessageFlags(rawValue: 1 << 0)
    public static let flagged = MessageFlags(rawValue: 1 << 1)
    public static let answered = MessageFlags(rawValue: 1 << 2)
    public static let draft = MessageFlags(rawValue: 1 << 3)
}

public struct MailMessage: Identifiable, Hashable, Codable, Sendable {
    /// Stable within one account: `mailbox/uid` for IMAP, the email id for JMAP.
    public var id: String
    public var mailboxID: String
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var subject: String
    public var date: Date
    public var snippet: String
    public var flags: MessageFlags
    public var hasAttachments: Bool
    /// Header fields the triage rules read (lowercased names).
    public var listHeaders: [String: String]
    /// Filled in once the body has been fetched.
    public var body: MessageBody?

    public init(
        id: String, mailboxID: String, messageID: String? = nil, inReplyTo: String? = nil,
        references: [String] = [], from: EmailAddress, to: [EmailAddress] = [], cc: [EmailAddress] = [],
        subject: String, date: Date, snippet: String = "", flags: MessageFlags = [],
        hasAttachments: Bool = false, listHeaders: [String: String] = [:], body: MessageBody? = nil
    ) {
        self.id = id
        self.mailboxID = mailboxID
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.snippet = snippet
        self.flags = flags
        self.hasAttachments = hasAttachments
        self.listHeaders = listHeaders
        self.body = body
    }

    public var isUnread: Bool { !flags.contains(.seen) }
    public var isStarred: Bool { flags.contains(.flagged) }
}

public struct MessageBody: Hashable, Codable, Sendable {
    public var text: String
    public var html: String?
    public var attachments: [AttachmentInfo]
    /// A meeting invitation carried by the message.
    public var invite: CalendarInvite?
    /// The emoji of a Gmail-format reaction part (`text/vnd.google.email-reaction+json`).
    public var reaction: String?
    /// True while only the start of the message has arrived: the text can be read, the files
    /// sent with it are still on their way. Never saved; the whole message replaces it.
    public var isPartial: Bool?

    public init(text: String, html: String? = nil, attachments: [AttachmentInfo] = [], invite: CalendarInvite? = nil,
                reaction: String? = nil) {
        self.text = text
        self.html = html
        self.attachments = attachments
        self.invite = invite
        self.reaction = reaction
    }

    /// Pictures the HTML shows with `cid:` put in place as `data:` URLs, and taken out of the
    /// attachment list, since they're part of the message rather than files sent with it.
    public func embeddingInlineImages() -> MessageBody {
        guard var html, html.range(of: "cid:", options: .caseInsensitive) != nil else { return self }
        var remaining: [AttachmentInfo] = []
        for file in attachments {
            guard let id = file.contentID, let data = file.data, file.mimeType.lowercased().hasPrefix("image/"),
                  html.range(of: "cid:" + id, options: .caseInsensitive) != nil else {
                remaining.append(file); continue
            }
            let uri = "data:\(file.mimeType.lowercased());base64,\(data.base64EncodedString())"
            for form in ["cid:" + id, "cid:" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)] {
                html = html.replacingOccurrences(of: form, with: uri, options: .caseInsensitive)
            }
        }
        var body = self
        body.html = html
        body.attachments = remaining
        return body
    }
}

public struct AttachmentInfo: Hashable, Codable, Sendable {
    public var filename: String
    public var mimeType: String
    public var size: Int?
    /// The file itself, when the provider sent it with the message (IMAP).
    public var data: Data?
    /// Where to fetch it when it didn't (JMAP blob id).
    public var blobID: String?
    /// Its Content-ID, without the angle brackets, when the HTML shows it with `cid:`.
    public var contentID: String?

    public init(filename: String, mimeType: String, size: Int? = nil, data: Data? = nil, blobID: String? = nil, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size ?? data?.count
        self.data = data
        self.blobID = blobID
        self.contentID = contentID
    }
}

/// A file attached to an outgoing message.
public struct OutgoingAttachment: Hashable, Codable, Sendable, Identifiable {
    public var id = UUID()
    public var filename: String
    public var mimeType: String
    public var data: Data
    /// Set for a picture shown inside the message (the HTML refers to it as `cid:<contentID>`);
    /// nil for an ordinary attachment.
    public var contentID: String?

    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}

/// A conversation: messages that answer each other, oldest first.
public struct MailThread: Identifiable, Hashable, Sendable {
    public var id: String
    public var messages: [MailMessage]
    /// The account it came from, set when several accounts are shown together.
    public var accountID: UUID?

    public init(id: String, messages: [MailMessage], accountID: UUID? = nil) {
        self.id = id
        self.messages = messages.sorted { $0.date < $1.date }
        self.accountID = accountID
    }

    public var latest: MailMessage { messages[messages.count - 1] }
    public var subject: String { messages.first?.subject ?? "" }
    public var date: Date { latest.date }
    public var isUnread: Bool { messages.contains(where: \.isUnread) }
    public var isStarred: Bool { messages.contains(where: \.isStarred) }
    public var hasAttachments: Bool { messages.contains(where: \.hasAttachments) }
    public var split: InboxSplit { InboxSplit.classify(messages[0]) }

    /// Senders in order of first appearance, without repeats.
    public var participants: [EmailAddress] {
        var seen = Set<String>()
        return messages.map(\.from).filter { seen.insert($0.address.lowercased()).inserted }
    }
}

/// Things you can do to whole threads. Providers map them to their protocol.
public enum MailAction: Hashable, Sendable {
    case markRead, markUnread, star, unstar
    /// Leaves the inbox: moves to the archive (or the provider's equivalent).
    case done
    case moveToInbox
    case trash
    case move(toMailboxID: String)
}

/// A message being written.
public struct Draft: Hashable, Codable, Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var text: String
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [OutgoingAttachment] = []
    /// A formatted version of `text`, sent alongside it when present.
    public var html: String?
    /// An iCalendar part (an invitation reply), sent alongside the text when present.
    public var calendar: String?
    /// A reaction emoji, sent as Gmail's reaction part between the text and the HTML.
    public var reaction: String?

    public init(
        from: EmailAddress, to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
        subject: String = "", text: String = "", inReplyTo: String? = nil, references: [String] = [],
        attachments: [OutgoingAttachment] = []
    ) {
        self.attachments = attachments
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.inReplyTo = inReplyTo
        self.references = references
    }

    public var recipients: [EmailAddress] { to + cc + bcc }

    /// A reply to the latest message of a thread, quoting nothing (the thread stays visible).
    public static func reply(to thread: MailThread, from me: EmailAddress, all: Bool = false) -> Draft {
        let last = thread.messages.last(where: { $0.from.address.lowercased() != me.address.lowercased() }) ?? thread.latest
        return reply(to: last, in: thread, from: me, all: all)
    }

    /// A reply to one message of a thread, whichever it is: to its sender (or, for one you sent,
    /// to the people you sent it to), and with `all`, copying everyone else who was on it.
    public static func reply(to last: MailMessage, in thread: MailThread, from me: EmailAddress, all: Bool = false) -> Draft {
        var to = [last.from]
        var cc: [EmailAddress] = []
        if all {
            let mine = me.address.lowercased()
            let others = (last.to + last.cc).filter { $0.address.lowercased() != mine && $0.address.lowercased() != last.from.address.lowercased() }
            cc = others
        }
        if last.from.address.lowercased() == me.address.lowercased() { to = last.to }
        let subject = Subject.isReply(thread.subject) ? thread.subject : "Re: \(thread.subject)"
        let references = last.references + [last.messageID].compactMap { $0 }
        return Draft(from: me, to: to, cc: cc, subject: subject, inReplyTo: last.messageID, references: references)
    }
}

/// Subject helpers shared by threading and replies.
public enum Subject {
    private static let prefixes = ["re", "fw", "fwd", "aw", "sv", "wg", "antw", "vs", "réf", "tr"]

    /// Strips reply and forward prefixes, any number of them, and lowercases.
    public static func normalized(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes {
                for form in ["\(prefix):", "\(prefix) :"] where text.lowercased().hasPrefix(form) {
                    text = String(text.dropFirst(form.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
            // "Re[2]:" style counters.
            if let match = text.range(of: #"^(re|aw|fw)\[\d+\]:\s*"#, options: [.regularExpression, .caseInsensitive]) {
                text = String(text[match.upperBound...])
                changed = true
            }
        }
        return text.lowercased()
    }

    public static func isReply(_ subject: String) -> Bool {
        let lower = subject.lowercased()
        return ["re:", "aw:", "sv:", "antw:"].contains { lower.hasPrefix($0) }
    }
}
