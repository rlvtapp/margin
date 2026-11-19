import Foundation

/// What the assistant read in a message: whether a system sent it, whether it waits on an
/// answer from you, and whether it asks you to pay. Margin has no word lists for this; without
/// an assistant there is no verdict, and what needs one (the Other tab for automated mail
/// without list headers, "reply owed", "bill") simply isn't offered.
public struct MailVerdict: Codable, Hashable, Sendable {
    /// Sent by a system or a company's automation, not written by a person to you.
    public var automated: Bool
    /// A person waits on an answer from you.
    public var needsReply: Bool
    /// Asks you to pay: a bill or payment request still open (not a receipt or a paid invoice).
    public var asksToPay: Bool

    public init(automated: Bool, needsReply: Bool, asksToPay: Bool) {
        self.automated = automated
        self.needsReply = needsReply
        self.asksToPay = asksToPay
    }
}

/// Verdicts by message, kept on disk by the app and read wherever mail is sorted, so the inbox
/// split stays a quick, synchronous lookup.
public final class MailVerdicts: @unchecked Sendable {
    public static let shared = MailVerdicts()

    private let lock = NSLock()
    private var byKey: [String: MailVerdict] = [:]

    public init() {}

    /// The key a message is remembered by: its Message-ID, the same on every device.
    public static func key(_ message: MailMessage) -> String { message.messageID ?? message.id }

    public subscript(message: MailMessage) -> MailVerdict? {
        lock.withLock { byKey[Self.key(message)] }
    }

    public func set(_ verdicts: [String: MailVerdict]) {
        lock.withLock { byKey.merge(verdicts) { _, new in new } }
    }

    public var all: [String: MailVerdict] { lock.withLock { byKey } }

    public func replaceAll(_ verdicts: [String: MailVerdict]) { lock.withLock { byKey = verdicts } }
}
