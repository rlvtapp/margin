import Foundation

/// One connected account. Every implementation talks to the mail server directly
/// from the device; there is no relay in between.
public protocol MailProvider: Sendable {
    /// Folders, with roles filled in.
    func mailboxes() async throws -> [Mailbox]
    /// The most recent conversations in a folder, newest first.
    func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread]
    /// The full text of one message.
    func body(of message: MailMessage) async throws -> MessageBody
    /// The message someone just opened, as fast as it can be shown. `isComplete` false means the
    /// text is there but files sent with it are still to come: `bodies(of:)` brings the whole.
    /// Never waits behind background work (refreshing, reading ahead).
    func openedBody(of message: MailMessage) async throws -> (body: MessageBody, isComplete: Bool)
    /// Several messages whole, in as few requests as the server allows, by message id. Ones
    /// that couldn't be read are left out. History and attachments must leave the connection
    /// used by `openedBody` free so opening another message stays responsive.
    func bodies(of messages: [MailMessage]) async throws -> [String: MessageBody]
    /// The readable text of several messages, by message id, for saving ahead of time. Heavy
    /// files are left out and the body is then marked partial (`MessageBody.isPartial`); ones
    /// that couldn't be read are left out. Background work: never on `openedBody`'s connection.
    func readableBodies(of messages: [MailMessage]) async throws -> [String: MessageBody]
    /// Applies an action to every message of the given threads.
    func perform(_ action: MailAction, on threads: [MailThread]) async throws
    /// Sends a message, and files a copy in Sent where the protocol doesn't.
    func send(_ draft: Draft) async throws
    /// The message exactly as the server keeps it (headers and MIME), for "Show source".
    func rawSource(of message: MailMessage) async throws -> Data
    /// An attachment's bytes, for providers that don't send them with the body.
    func attachmentData(_ attachment: AttachmentInfo, of message: MailMessage) async throws -> Data
    /// Mail matching the words, from the whole account, newest first.
    func search(_ text: String, limit: Int) async throws -> [MailThread]
    /// Folder management.
    func createMailbox(named name: String) async throws
    func renameMailbox(_ mailbox: Mailbox, to name: String) async throws
    func deleteMailbox(_ mailbox: Mailbox) async throws
    /// Files an unsent message in Drafts; returns nothing the caller needs.
    func saveDraft(_ draft: Draft) async throws
    /// Closes connections. Safe to call more than once.
    func disconnect() async
    /// Waits until the inbox changes, or `timeout` passes. Returns whether it changed.
    /// Throws `notSupported` when the account can't push; callers then check on a timer.
    func waitForInboxChange(timeout: Duration) async throws -> Bool
    /// A page of a folder's older mail, headers only (no texts, no files), newest first: the
    /// messages just older than `position`, which is the `next` of the page before; nil starts
    /// at the newest. Unlike `threads(in:limit:)` this keeps nothing: what it returns isn't
    /// added to what a refresh brings up to date. Never waits behind a mail being opened.
    func olderMessages(in mailbox: Mailbox, after position: String?, limit: Int) async throws -> OlderMailPage
    /// Compares saved copies of a folder's mail (`ids`) with the server: which are gone, moved,
    /// or carry other flags now. `token` is the `token` of the answer before; with it, a server
    /// that keeps count of changes (CONDSTORE, QRESYNC, JMAP states) says only what changed.
    func checkSaved(_ ids: [String], in mailbox: Mailbox, since token: String?) async throws -> SavedMailCheck
}

/// A page of older mail (see `MailProvider.olderMessages`).
public struct OlderMailPage: Sendable {
    public var messages: [MailMessage]
    /// Where the page after this one starts; nil when this one reached the folder's oldest.
    public var next: String?
    /// What the folder's message ids are good for (IMAP's UIDVALIDITY). When it changes, ids
    /// saved before name other messages now. Nil when ids last for ever.
    public var validity: String?

    public init(messages: [MailMessage] = [], next: String? = nil, validity: String? = nil) {
        self.messages = messages
        self.next = next
        self.validity = validity
    }
}

/// What a server says about saved copies of a folder's mail (see `MailProvider.checkSaved`).
public struct SavedMailCheck: Sendable, Equatable {
    /// Flags as they are now, by message id: the changed ones, or all of them.
    public var flags: [String: MessageFlags] = [:]
    /// Messages now in another folder, by id, with that folder (JMAP keeps an id across moves).
    public var moved: [String: String] = [:]
    /// Messages no longer in the folder.
    public var gone: [String] = []
    /// To hand back next time, so only changes since are reported; nil when the server keeps
    /// no count of changes (then a check looks at every message, so it's done rarely).
    public var token: String?

    public init(flags: [String: MessageFlags] = [:], moved: [String: String] = [:], gone: [String] = [], token: String? = nil) {
        self.flags = flags
        self.moved = moved
        self.gone = gone
        self.token = token
    }
}

extension MailProvider {
    public func openedBody(of message: MailMessage) async throws -> (body: MessageBody, isComplete: Bool) {
        (try await body(of: message), true)
    }

    public func bodies(of messages: [MailMessage]) async throws -> [String: MessageBody] {
        var found: [String: MessageBody] = [:]
        for message in messages {
            if let body = try? await body(of: message) { found[message.id] = body }
        }
        return found
    }

    public func readableBodies(of messages: [MailMessage]) async throws -> [String: MessageBody] {
        try await bodies(of: messages)
    }

    public func rawSource(of message: MailMessage) async throws -> Data {
        throw MailError.notSupported(String(localized: "This account can't show a message's source."))
    }
    public func waitForInboxChange(timeout: Duration) async throws -> Bool {
        throw MailError.notSupported(String(localized: "This account can't push new mail."))
    }
    public func search(_ text: String, limit: Int) async throws -> [MailThread] { [] }
    /// Providers that can't page through older mail aren't asked again (never shown).
    public func olderMessages(in mailbox: Mailbox, after position: String?, limit: Int) async throws -> OlderMailPage {
        throw MailError.notSupported("older mail")
    }
    public func checkSaved(_ ids: [String], in mailbox: Mailbox, since token: String?) async throws -> SavedMailCheck {
        SavedMailCheck()
    }
    public func createMailbox(named name: String) async throws { throw MailError.notSupported(String(localized: "This account can't create folders.")) }
    public func renameMailbox(_ mailbox: Mailbox, to name: String) async throws { throw MailError.notSupported(String(localized: "This account can't rename folders.")) }
    public func deleteMailbox(_ mailbox: Mailbox) async throws { throw MailError.notSupported(String(localized: "This account can't delete folders.")) }
    public func saveDraft(_ draft: Draft) async throws { throw MailError.notSupported(String(localized: "This account can't save drafts.")) }

    public func attachmentData(_ attachment: AttachmentInfo, of message: MailMessage) async throws -> Data {
        guard let data = attachment.data else { throw MailError.notSupported(String(localized: "This attachment wasn't downloaded.")) }
        return data
    }
}

public enum MailError: LocalizedError, Equatable, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case timedOut
    case insecureConnection
    case authenticationFailed(String)
    case serverRejected(String)
    case protocolViolation(String)
    case missingCredentials
    case notSupported(String)
    case invalidAddress(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail): String(localized: "Couldn't connect to the server. \(detail)")
        case .connectionClosed: String(localized: "The server closed the connection.")
        case .timedOut: String(localized: "The server took too long to answer.")
        case .insecureConnection: String(localized: "Unencrypted connections are only allowed to this device.")
        case .authenticationFailed(let detail): String(localized: "Sign-in was refused. \(detail)")
        case .serverRejected(let detail): String(localized: "The server said no: \(detail)")
        case .protocolViolation(let detail): String(localized: "The server sent something unexpected. \(detail)")
        case .missingCredentials: String(localized: "This account has no saved password or token.")
        case .notSupported(let detail): detail
        case .invalidAddress(let address): String(localized: "“\(address)” isn't an email address.")
        }
    }
}
