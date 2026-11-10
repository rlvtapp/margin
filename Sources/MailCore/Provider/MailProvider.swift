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
    /// Applies an action to every message of the given threads.
    func perform(_ action: MailAction, on threads: [MailThread]) async throws
    /// Sends a message, and files a copy in Sent where the protocol doesn't.
    func send(_ draft: Draft) async throws
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
}

extension MailProvider {
    public func waitForInboxChange(timeout: Duration) async throws -> Bool {
        throw MailError.notSupported(String(localized: "This account can't push new mail."))
    }
    public func search(_ text: String, limit: Int) async throws -> [MailThread] { [] }
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
