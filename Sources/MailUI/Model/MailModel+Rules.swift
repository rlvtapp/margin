import Foundation
import MailCore

/// A rule for new mail: when a field contains some text, do one thing with it.
public struct MailRule: Codable, Hashable, Identifiable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case from, to, subject

        public var title: String {
            switch self {
            case .from: String(localized: "From")
            case .to: String(localized: "To")
            case .subject: String(localized: "Subject")
            }
        }
    }

    public enum Action: Codable, Hashable, Sendable {
        case archive, trash, markRead, star
        case label(String)
        /// Into the folder with this name, in the mail's own mailbox.
        case move(String)

        public var title: String {
            switch self {
            case .archive: String(localized: "Archive")
            case .trash: String(localized: "Move to Trash")
            case .markRead: String(localized: "Mark as read")
            case .star: String(localized: "Star")
            case .label(let name): String(localized: "Label “\(name)”")
            case .move(let folder): String(localized: "Move to “\(folder)”")
            }
        }
    }

    public var id = UUID()
    public var field: Field
    public var contains: String
    public var action: Action
    /// Only for this mailbox; nil for all of them.
    public var accountID: UUID?

    public init(field: Field, contains: String, action: Action, accountID: UUID? = nil) {
        self.field = field
        self.contains = contains
        self.action = action
        self.accountID = accountID
    }

    public func matches(_ message: MailMessage) -> Bool {
        let needle = contains.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        switch field {
        case .from:
            return message.from.address.lowercased().contains(needle) || (message.from.name ?? "").lowercased().contains(needle)
        case .to:
            return (message.to + message.cc).contains { $0.address.lowercased().contains(needle) || ($0.name ?? "").lowercased().contains(needle) }
        case .subject:
            return message.subject.lowercased().contains(needle)
        }
    }
}

/// Blocked senders, muted conversations and rules, applied to new inbox mail as it arrives (while
/// Margin runs), before any alert.
extension MailModel {
    public var blockedSenders: Set<String> {
        get { _ = priorityRevision; return Set(environment.defaults.stringArray(forKey: "blockedSenders") ?? []) }
        set { environment.defaults.set(newValue.sorted(), forKey: "blockedSenders"); priorityRevision += 1 }
    }

    public var mutedThreads: Set<String> {
        get { _ = priorityRevision; return Set(environment.defaults.stringArray(forKey: "mutedThreads") ?? []) }
        set { environment.defaults.set(newValue.sorted(), forKey: "mutedThreads"); priorityRevision += 1 }
    }

    public var mailRules: [MailRule] {
        get {
            _ = priorityRevision
            return environment.defaults.data(forKey: "mailRules").flatMap { try? JSONDecoder().decode([MailRule].self, from: $0) } ?? []
        }
        set { environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "mailRules"); priorityRevision += 1 }
    }

    public func isBlocked(_ sender: EmailAddress) -> Bool { blockedSenders.contains(sender.address.lowercased()) }
    public func isMuted(_ thread: MailThread) -> Bool { mutedThreads.contains(thread.id) }

    /// Blocks the sender: what's in the inbox from them goes to Trash now, and so does new mail.
    public func block(_ sender: EmailAddress) {
        blockedSenders.insert(sender.address.lowercased())
        let theirs = inboxThreads(nil).filter { $0.latest.from.address.lowercased() == sender.address.lowercased() }
        Task { await apply(.trash, to: theirs, announce: false) }
        notice = Notice(text: String(localized: "Blocked \(sender.displayName). Their mail goes to Trash."))
    }

    public func unblock(_ address: String) { blockedSenders.remove(address.lowercased()) }

    /// Mutes a conversation: it leaves the inbox now, and replies to it skip the inbox.
    public func toggleMute(_ thread: MailThread) {
        if isMuted(thread) {
            mutedThreads.remove(thread.id)
            notice = Notice(text: String(localized: "Conversation unmuted"))
        } else {
            mutedThreads.insert(thread.id)
            Task { await apply(.done, to: [thread], announce: false) }
            notice = Notice(text: String(localized: "Muted. New replies won't reach your inbox."))
        }
    }

    /// Runs on every load, before alerts: new inbox mail from blocked senders goes to Trash,
    /// replies in muted conversations are archived and read, and rules do what they say. Each
    /// message is handled once; the first run only remembers what's already there.
    func applyInboxRules() {
        let threads = inboxThreads(nil)
        let seenKey = "rules.seen"
        var seen = Set(environment.defaults.stringArray(forKey: seenKey) ?? [])
        let firstRun = environment.defaults.object(forKey: seenKey) == nil
        let blocked = blockedSenders, muted = mutedThreads, rules = mailRules
        var actions: [MailAction: [MailThread]] = [:]
        var leaving = Set<String>()
        for thread in threads {
            let message = thread.latest
            guard seen.insert(message.id).inserted, !firstRun else { continue }
            if blocked.contains(message.from.address.lowercased()) {
                actions[.trash, default: []].append(thread); leaving.insert(thread.id); continue
            }
            if muted.contains(thread.id) {
                actions[.markRead, default: []].append(thread)
                actions[.done, default: []].append(thread); leaving.insert(thread.id); continue
            }
            for rule in rules where (rule.accountID == nil || rule.accountID == thread.accountID) && rule.matches(message) {
                switch rule.action {
                case .archive: actions[.done, default: []].append(thread); leaving.insert(thread.id)
                case .trash: actions[.trash, default: []].append(thread); leaving.insert(thread.id)
                case .markRead: actions[.markRead, default: []].append(thread)
                case .star: actions[.star, default: []].append(thread)
                case .label(let name): addLabel(name, to: thread)
                case .move(let folder):
                    if let accountID = thread.accountID,
                       let box = mailboxes[accountID]?.first(where: { $0.name.caseInsensitiveCompare(folder) == .orderedSame }) {
                        actions[.move(toMailboxID: box.id), default: []].append(thread); leaving.insert(thread.id)
                    }
                }
            }
        }
        // Kept to a few thousand, which covers any inbox view.
        environment.defaults.set(Array(seen.suffix(5000)), forKey: seenKey)
        guard !actions.isEmpty else { return }
        // Gone from the inbox at once, so no alert goes out for them.
        for key in inboxes.keys { inboxes[key]?.removeAll { leaving.contains($0.id) } }
        Task {
            for (action, list) in actions { await apply(action, to: list, announce: false) }
        }
    }
}

extension MailModel {
    /// Colours picked for labels and groups, by lowercased name (palette index).
    public var labelColors: [String: Int] {
        get {
            _ = priorityRevision
            return environment.defaults.data(forKey: "labelColors").flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        }
        set { environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "labelColors"); priorityRevision += 1 }
    }

    /// Picks a label's colour; nil goes back to its automatic one.
    public func setColor(_ index: Int?, forLabel name: String) {
        labelColors[name.lowercased()] = index
    }
}
