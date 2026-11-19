import Foundation
import MailCore

/// Labels kept on the server, for accounts that have labels instead of folders: a message
/// carries several and shows in each label's folder. They show as chips like Margin's own
/// labels; adding or removing one changes it on the server.
extension MailModel {
    /// Whether the account keeps labels on its server: an IMAP server whose folders are labels,
    /// or a Graph account, whose categories are labels without folders of their own.
    public func keepsLabels(_ accountID: UUID?) -> Bool {
        if case .graph = account(accountID)?.connection { return true }
        return foldersAreLabels(accountID)
    }

    /// Whether the account's folders are views of its labels, so the sidebar calls them labels.
    public func foldersAreLabels(_ accountID: UUID?) -> Bool {
        guard let accountID else { return false }
        return mailboxes[accountID]?.contains { $0.label != nil } ?? false
    }

    /// The person's own server labels on any message of the conversation, system ones left out.
    public func serverLabels(for thread: MailThread) -> [String] {
        let all = thread.messages.flatMap { $0.labels ?? [] }
        return all.isEmpty ? [] : IMAPLabels.userLabels(all)
    }

    /// The label of the folder on screen, so rows there don't repeat it.
    var placeLabel: String? {
        if case .mailbox(_, let mailbox) = place { return mailbox.label }
        return nil
    }

    /// The chips on a row: none on Home, which already sorts by what matters, and never the
    /// label of the folder on screen, which every row there has.
    public func rowLabels(for thread: MailThread) -> [String] {
        guard !place.isHome else { return [] }
        let labels = labels(for: thread)
        guard let current = placeLabel else { return labels }
        return labels.filter { $0.caseInsensitiveCompare(current) != .orderedSame }
    }

    /// Server label colours as the app's own (the nearest palette colour, so text on them stays
    /// readable), by lowercased label name.
    var serverLabelColorIndexes: [String: Int] {
        var indexes: [String: Int] = [:]
        for folders in mailboxes.values {
            for folder in folders {
                guard let label = folder.label, let hex = folder.labelColor, hex.hasPrefix("#"),
                      let rgb = UInt32(hex.dropFirst(), radix: 16) else { continue }
                indexes[label.lowercased()] = Palette.nearestAccountIndex(to: rgb)
            }
        }
        return indexes
    }

    /// Puts a server label on a conversation or takes it off: shown at once, then sent.
    func changeServerLabel(_ label: String, adding: Bool, on thread: MailThread) {
        let change: (MailThread) -> MailThread = { thread in
            var copy = thread
            for index in copy.messages.indices where copy.messages[index].labels != nil {
                var labels = copy.messages[index].labels ?? []
                labels.removeAll { $0.caseInsensitiveCompare(label) == .orderedSame }
                if adding { labels.append(label) }
                copy.messages[index].labels = labels
            }
            return copy
        }
        mutationRevision += 1
        changeInInboxes([thread], change)
        // Taking off the label of the folder on screen takes the conversation out of it.
        if !adding, placeLabel?.caseInsensitiveCompare(label) == .orderedSame {
            folder.removeAll { $0.id == thread.id }
        } else if folder.contains(where: { $0.id == thread.id }) {
            folder = folder.map { $0.id == thread.id ? change($0) : $0 }
        }
        guard let account = account(thread.accountID) else { return }
        Task {
            committingChanges[account.id, default: 0] += 1
            var failure: Error?
            do {
                try await provider(for: account).changeLabel(label, adding: adding, on: [thread])
            } catch {
                failure = error
            }
            committingChanges[account.id, default: 1] -= 1
            if committingChanges[account.id] == 0 { committingChanges[account.id] = nil }
            mutationRevision += 1
            if let failure {
                show(failure)
                await reload(only: account)
            } else {
                await saveInbox(of: account.id)
            }
        }
    }

    /// For pictures of the app: the first mailbox keeps labels, with nested and coloured ones,
    /// and its inbox mail carries some.
    public func addSampleLabels() {
        guard environment.isPreview, let accountID = accounts.first?.id, var folders = mailboxes[accountID] else { return }
        let roles: [MailboxRole: String] = [.inbox: IMAPLabels.inbox, .sent: IMAPLabels.sent, .drafts: IMAPLabels.drafts]
        for index in folders.indices {
            folders[index].label = folders[index].role == .other ? folders[index].id : roles[folders[index].role]
        }
        folders += [
            Mailbox(id: "Projects", name: "Projects", role: .other, label: "Projects", labelColor: "#4a86e8"),
            Mailbox(id: "Projects/Launch", name: "Launch", role: .other, parentID: "Projects", label: "Projects/Launch", labelColor: "#16a766"),
            Mailbox(id: "Projects/Hiring", name: "Hiring", role: .other, parentID: "Projects", label: "Projects/Hiring", labelColor: "#a479e2"),
            Mailbox(id: "Travel", name: "Travel", role: .other, label: "Travel", labelColor: "#ffad47"),
        ]
        mailboxes[accountID] = folders
        let sets: [[String]] = [["Projects/Launch"], ["Clients", "Projects/Hiring"], ["Receipts"], [], ["Travel"], ["Clients"], ["Projects/Launch", "Travel"]]
        guard let threads = inboxes[accountID] else { return }
        inboxes[accountID] = threads.enumerated().map { offset, thread in
            var copy = thread
            for index in copy.messages.indices {
                copy.messages[index].labels = [IMAPLabels.inbox] + sets[offset % sets.count]
            }
            return copy
        }
    }
}
