import AppIntents
import Foundation
import MailCore

/// The standard mail actions, so Siri can act on what's on screen ("archive this", "reply
/// saying I'll be there"). Each one works on the conversation the message belongs to.
@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.archiveMail)
public struct ArchiveMailIntent: AppIntent {
    @Parameter public var entities: [MailMessageEntity]
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult {
        try act(.done, on: entities.map(\.id))
        return .result()
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.deleteMail)
public struct DeleteMailIntent: AppIntent {
    @Parameter public var entities: [MailMessageEntity]
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult {
        try act(.trash, on: entities.map(\.id))
        return .result()
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.updateMail)
public struct UpdateMailIntent: AppIntent {
    @Parameter public var target: [MailMessageEntity]
    @Parameter public var isRead: Bool?
    @Parameter public var isFlagged: Bool?
    @Parameter public var isJunk: Bool?
    @Parameter public var mailbox: MailboxAppEntity?
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult {
        let ids = target.map(\.id)
        if let isRead { try act(isRead ? .markRead : .markUnread, on: ids) }
        if let isFlagged { try act(isFlagged ? .star : .unstar, on: ids) }
        if let mailbox { try act(.move(toMailboxID: mailbox.id), on: ids) }
        return .result()
    }
}

/// Opens a reply (or a forward) with what Siri was asked to write, for the person to check
/// and send. Nothing is sent without them.
@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.replyMail)
public struct ReplyMailIntent: AppIntent {
    @Parameter public var target: MailMessageEntity
    @Parameter public var isReplyAll: Bool
    @Parameter public var account: MailAccountAppEntity?
    @Parameter public var subject: String?
    @Parameter public var body: AttributedString?
    @Parameter public var to: [IntentPerson]
    @Parameter public var cc: [IntentPerson]
    @Parameter public var bcc: [IntentPerson]
    @Parameter public var attachments: [IntentFile]
    public static let openAppWhenRun = true
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult {
        try openDraft(on: target.id, forward: false, all: isReplyAll, body: body)
        return .result()
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppIntent(schema: .mail.forwardMail)
public struct ForwardMailIntent: AppIntent {
    @Parameter public var target: MailMessageEntity
    @Parameter public var account: MailAccountAppEntity?
    @Parameter public var subject: String?
    @Parameter public var body: AttributedString?
    @Parameter public var to: [IntentPerson]
    @Parameter public var cc: [IntentPerson]
    @Parameter public var bcc: [IntentPerson]
    @Parameter public var attachments: [IntentFile]
    public static let openAppWhenRun = true
    public init() {}
    @MainActor public func perform() async throws -> some IntentResult {
        try openDraft(on: target.id, forward: true, all: false, body: body)
        return .result()
    }
}

@available(iOS 18.0, macOS 15.0, *)
@MainActor
private func act(_ action: MailAction, on ids: [String]) throws {
    guard let model = SiriBridge.model else { throw MailError.notSupported(String(localized: "Open Margin first.")) }
    let threads = SiriBridge.threads(ids, in: model)
    guard !threads.isEmpty else { throw MailError.notSupported(String(localized: "That email isn't on this device.")) }
    Task { await model.apply(action, to: threads, announce: true) }
}

@available(iOS 18.0, macOS 15.0, *)
@MainActor
private func openDraft(on id: String, forward: Bool, all: Bool, body: AttributedString?) throws {
    guard let model = SiriBridge.model else { throw MailError.notSupported(String(localized: "Open Margin first.")) }
    guard let thread = SiriBridge.threads([id], in: model).first else { throw MailError.notSupported(String(localized: "That email isn't on this device.")) }
    model.select(thread.id)
    if forward { model.startForward() } else { model.startReply(all: all) }
    let text = body.map { String($0.characters) } ?? ""
    if forward {
        if !text.isEmpty { model.compose?.draft.text = text + "\n\n" + (model.compose?.draft.text ?? "") }
    } else if !text.isEmpty {
        model.reply?.draft.text = text + (model.reply?.draft.text ?? "")
    }
}
