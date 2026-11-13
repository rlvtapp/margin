import AppIntents
import CoreSpotlight
import Foundation
import MailCore

/// Lets Siri and Apple Intelligence reach Margin's mail: which message is on screen, what can
/// be found in Spotlight, and the standard mail actions (archive, delete, reply, forward, mark).
/// Everything is answered from mail already on the device. The app sets `model` at launch.
@MainActor
public enum SiriBridge {
    public static weak var model: MailModel?

    /// The newest message of a conversation, as Siri sees it.
    @available(iOS 18.0, macOS 15.0, *)
    static func entity(for thread: MailThread, in model: MailModel) -> MailMessageEntity? {
        guard let account = model.account(thread.accountID) else { return nil }
        let latest = thread.latest
        let body = model.body(of: latest, in: thread)?.text ?? latest.snippet
        let accountEntity = MailAccountAppEntity(account)
        var entity = MailMessageEntity(id: thread.id)
        entity.subject = thread.subject
        entity.body = AttributedString(body)
        entity.sender = IntentPerson(latest.from)
        entity.to = latest.to.map(IntentPerson.init)
        entity.cc = latest.cc.map(IntentPerson.init)
        entity.bcc = []
        entity.dateSent = latest.date
        entity.dateReceived = latest.date
        entity.isRead = !thread.isUnread
        entity.isFlagged = thread.isStarred
        entity.isJunk = false
        entity.attachments = []
        entity.account = accountEntity
        entity.mailbox = MailboxAppEntity(id: latest.mailboxID, name: latest.mailboxID == "INBOX" ? String(localized: "Inbox") : latest.mailboxID,
                                          account: accountEntity)
        entity.category = thread.split == .people ? .primary : nil
        return entity
    }

    /// Conversations for entity ids, from the inbox and any folder that's loaded.
    static func threads(_ ids: [String], in model: MailModel) -> [MailThread] {
        let known = model.inboxThreads(nil) + model.folder + model.newsletterHistory
        return ids.compactMap { id in known.first { $0.id == id } }
    }

    /// Adds the inbox to Spotlight and Siri's index, so mail can be found by asking.
    @available(iOS 18.0, macOS 15.0, *)
    static func index(_ model: MailModel) async {
        guard !model.environment.isPreview else { return }
        let entities = model.newestInInboxes(300).compactMap { entity(for: $0, in: model) }
        try? await CSSearchableIndex.default().indexAppEntities(Array(entities))
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppEnum(schema: .mail.category)
public enum MailCategoryEnum: String, AppEnum {
    case primary
    public static let caseDisplayRepresentations: [MailCategoryEnum: DisplayRepresentation] = [.primary: "People"]
}

@available(iOS 18.0, macOS 15.0, *)
@AppEntity(schema: .mail.account)
public struct MailAccountAppEntity {
    public static let defaultQuery = MailAccountQuery()
    public var id: String
    public var name: String
    public var emailAddress: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(emailAddress)") }

    init(_ account: MailAccount) {
        id = account.id.uuidString
        name = account.label
        emailAddress = account.address.address
    }
}

@available(iOS 18.0, macOS 15.0, *)
public struct MailAccountQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [MailAccountAppEntity] {
        (SiriBridge.model?.accounts ?? []).filter { identifiers.contains($0.id.uuidString) }.map(MailAccountAppEntity.init)
    }
    @MainActor public func suggestedEntities() async throws -> [MailAccountAppEntity] {
        (SiriBridge.model?.accounts ?? []).map(MailAccountAppEntity.init)
    }
    @MainActor public func entities(matching string: String) async throws -> [MailAccountAppEntity] {
        (SiriBridge.model?.accounts ?? []).filter {
            $0.label.localizedCaseInsensitiveContains(string) || $0.address.address.localizedCaseInsensitiveContains(string)
        }.map(MailAccountAppEntity.init)
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppEntity(schema: .mail.mailbox)
public struct MailboxAppEntity {
    public static let defaultQuery = MailboxQuery()
    public var id: String
    public var name: String
    public var account: MailAccountAppEntity
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String, account: MailAccountAppEntity) {
        self.id = id
        self.name = name
        self.account = account
    }
}

@available(iOS 18.0, macOS 15.0, *)
public struct MailboxQuery: EntityStringQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [MailboxAppEntity] {
        guard let model = SiriBridge.model else { return [] }
        return model.accounts.flatMap { account in
            (model.mailboxes[account.id] ?? []).filter { identifiers.contains($0.id) }
                .map { MailboxAppEntity(id: $0.id, name: $0.name, account: MailAccountAppEntity(account)) }
        }
    }
    @MainActor public func entities(matching string: String) async throws -> [MailboxAppEntity] {
        guard let model = SiriBridge.model else { return [] }
        return model.accounts.flatMap { account in
            (model.mailboxes[account.id] ?? []).filter { $0.name.localizedCaseInsensitiveContains(string) }
                .map { MailboxAppEntity(id: $0.id, name: $0.name, account: MailAccountAppEntity(account)) }
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
@AppEntity(schema: .mail.message)
public struct MailMessageEntity: IndexedEntity {
    public static let defaultQuery = MailMessageQuery()
    public var id: String
    public var subject: String?
    public var body: AttributedString?
    public var sender: IntentPerson
    public var to: [IntentPerson]
    public var cc: [IntentPerson]
    public var bcc: [IntentPerson]
    public var dateSent: Date
    public var dateReceived: Date
    public var isRead: Bool
    public var isFlagged: Bool
    public var isJunk: Bool
    public var attachments: [IntentFile]
    public var account: MailAccountAppEntity
    public var mailbox: MailboxAppEntity
    public var category: MailCategoryEnum?
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject ?? "")", subtitle: "\(sender.shownName)")
    }

    init(id: String) {
        self.id = id
    }
}

@available(iOS 18.0, macOS 15.0, *)
public struct MailMessageQuery: EntityQuery {
    public init() {}
    @MainActor public func entities(for identifiers: [String]) async throws -> [MailMessageEntity] {
        guard let model = SiriBridge.model else { return [] }
        return SiriBridge.threads(identifiers, in: model).compactMap { SiriBridge.entity(for: $0, in: model) }
    }
    @MainActor public func suggestedEntities() async throws -> [MailMessageEntity] {
        guard let model = SiriBridge.model else { return [] }
        return model.newestInInboxes(20).compactMap { SiriBridge.entity(for: $0, in: model) }
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension IntentPerson {
    init(_ address: EmailAddress) {
        self.init(
            identifier: .applicationDefined(address.address.lowercased()),
            name: .displayName(address.displayName),
            handle: IntentPerson.Handle(emailAddress: address.address)
        )
    }

    var shownName: String {
        switch name {
        case .displayName(let text): text
        case .components(let parts): PersonNameComponentsFormatter().string(from: parts)
        default: ""
        }
    }
}

import SwiftUI

extension View {
    /// Tells Siri which conversation is on screen, so "summarize this" or "archive this" knows
    /// what "this" is.
    func onScreenForSiri(_ thread: MailThread?) -> some View {
        userActivity("app.relevate.margin.conversation", isActive: thread != nil) { activity in
            activity.title = thread?.subject
            if #available(iOS 18.2, macOS 15.2, *), let thread {
                activity.appEntityIdentifier = EntityIdentifier(for: MailMessageEntity.self, identifier: thread.id)
            }
        }
    }
}
