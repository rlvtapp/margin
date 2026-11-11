import Foundation

/// Mail that lives only in memory, so the app can be tried with no account at all.
/// Sent messages land in Sent; nothing goes over the network.
public actor SampleProvider: MailProvider {
    private var messages: [MailMessage]
    private let me: EmailAddress
    private var folders = [
        Mailbox(id: "INBOX", name: "Inbox", role: .inbox),
        Mailbox(id: "Drafts", name: "Drafts", role: .drafts),
        Mailbox(id: "Sent", name: "Sent", role: .sent),
        Mailbox(id: "Archive", name: "Archive", role: .archive),
        Mailbox(id: "Junk", name: "Junk", role: .junk),
        Mailbox(id: "Trash", name: "Trash", role: .trash),
        Mailbox(id: "Clients", name: "Clients", role: .other),
        Mailbox(id: "Receipts", name: "Receipts", role: .other),
    ]

    public enum Variant: Sendable { case work, personal }

    public init(me: EmailAddress = MailAccount.sample.address, variant: Variant = .work, now: Date = Date()) {
        self.me = me
        messages = variant == .work ? SampleMail.messages(me: me, now: now) : SampleMail.personal(me: me, now: now)
    }

    public func mailboxes() async throws -> [Mailbox] {
        folders.map { folder in
            var copy = folder
            copy.unreadCount = messages.filter { $0.mailboxID == folder.id && $0.isUnread }.count
            return copy
        }
    }

    public func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] {
        let inFolder = messages.filter { $0.mailboxID == mailbox.id }
        return Array(Threader.threads(from: inFolder).sorted { $0.date > $1.date }.prefix(limit))
    }

    public func body(of message: MailMessage) async throws -> MessageBody {
        messages.first { $0.id == message.id }?.body ?? MessageBody(text: message.snippet)
    }

    public func perform(_ action: MailAction, on threads: [MailThread]) async throws {
        let ids = Set(threads.flatMap { $0.messages.map(\.id) })
        for index in messages.indices where ids.contains(messages[index].id) {
            switch action {
            case .markRead: messages[index].flags.insert(.seen)
            case .markUnread: messages[index].flags.remove(.seen)
            case .star: messages[index].flags.insert(.flagged)
            case .unstar: messages[index].flags.remove(.flagged)
            case .done: messages[index].mailboxID = "Archive"
            case .moveToInbox: messages[index].mailboxID = "INBOX"
            case .trash: messages[index].mailboxID = "Trash"
            case .move(let target): messages[index].mailboxID = target
            }
        }
    }

    public func send(_ draft: Draft) async throws {
        guard !draft.recipients.isEmpty else { throw MailError.invalidAddress("") }
        let id = "Sent/\(UUID().uuidString)"
        messages.append(MailMessage(
            id: id, mailboxID: "Sent", messageID: "\(UUID().uuidString)@example.com",
            inReplyTo: draft.inReplyTo, references: draft.references, from: draft.from,
            to: draft.to, cc: draft.cc, subject: draft.subject, date: Date(),
            snippet: HTMLText.snippet(draft.text), flags: [.seen], body: MessageBody(text: draft.text)
        ))
    }

    /// The sample mail as it would arrive: built from its fields.
    public func rawSource(of message: MailMessage) async throws -> Data {
        var draft = Draft(from: message.from, to: message.to, cc: message.cc, subject: message.subject,
                          text: message.body?.text ?? message.snippet)
        draft.html = message.body?.html
        draft.inReplyTo = message.inReplyTo
        draft.references = message.references
        return Data(MessageBuilder.build(draft, date: message.date, messageID: message.messageID))
    }

    public func disconnect() async {}

    public func search(_ text: String, limit: Int) async throws -> [MailThread] {
        let query = SearchQuery(text)
        let matching = messages.filter { query.matches(MailThread(id: $0.id, messages: [$0])) }
        return Array(Threader.threads(from: matching).sorted { $0.date > $1.date }.prefix(limit))
    }

    public func createMailbox(named name: String) async throws {
        guard !folders.contains(where: { $0.name.lowercased() == name.lowercased() }) else { throw MailError.serverRejected("A folder with that name exists.") }
        folders.append(Mailbox(id: name, name: name, role: .other))
    }

    public func renameMailbox(_ mailbox: Mailbox, to name: String) async throws {
        guard let index = folders.firstIndex(where: { $0.id == mailbox.id }), mailbox.role == .other else { throw MailError.notSupported("Only your own folders can be renamed.") }
        folders[index] = Mailbox(id: name, name: name, role: .other)
        for i in messages.indices where messages[i].mailboxID == mailbox.id { messages[i].mailboxID = name }
    }

    public func deleteMailbox(_ mailbox: Mailbox) async throws {
        guard mailbox.role == .other else { throw MailError.notSupported("Only your own folders can be deleted.") }
        folders.removeAll { $0.id == mailbox.id }
        for i in messages.indices where messages[i].mailboxID == mailbox.id { messages[i].mailboxID = "Trash" }
    }

    public func saveDraft(_ draft: Draft) async throws {
        messages.append(MailMessage(
            id: "Drafts/\(UUID().uuidString)", mailboxID: "Drafts", from: draft.from, to: draft.to, cc: draft.cc,
            subject: draft.subject, date: Date(), snippet: HTMLText.snippet(draft.text), flags: [.seen, .draft],
            body: MessageBody(text: draft.text)
        ))
    }
}
