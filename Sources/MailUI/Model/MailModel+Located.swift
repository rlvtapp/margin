import Foundation
import MailCore

/// Small sets of inbox conversations that the sidebar, Home and the top bar ask about on every
/// redraw: the snoozed ones, the ones from VIPs, the ones with a label. Each is found by one
/// look through the mail when conversations arrive or leave, and kept as places in the shelves
/// until then, so a read mark or opening a mail never sends anything through the mailbox again.
extension MailModel {
    /// Where a conversation is in its mailbox's shelf, good until the shelves' order changes.
    struct Located: Sendable {
        var account: UUID
        var row: Int
    }

    private func locate(_ passes: (MailThread) -> Bool) -> [Located] {
        var found: [Located] = []
        for account in accounts {
            guard let shelf = shelves[account.id] else { continue }
            for row in shelf.threads.indices where passes(shelf.threads[row]) {
                found.append(Located(account: account.id, row: row))
            }
        }
        return found
    }

    private func thread(at place: Located) -> MailThread? {
        guard let shelf = shelves[place.account], place.row < shelf.count else { return nil }
        return shelf.threads[place.row]
    }

    // MARK: Snoozed

    /// Inbox conversations with a snooze on them, in one mailbox or (nil) in every one, each
    /// with when it comes back.
    func snoozedInInboxes(_ scope: UUID?) -> [(thread: MailThread, until: Date)] {
        let located = derived.snoozed.value {
            _ = inboxOrder
            let keys = KeyLookup(snoozes.keys)
            return keys.isEmpty ? [] : locate { keys.contains($0) }
        }
        guard !located.isEmpty else { return [] }
        _ = inboxRevision
        let now = Date()
        return located.compactMap { place in
            guard scope == nil || place.account == scope, let thread = thread(at: place),
                  let until = snoozes[LabelStore.key(for: thread)], until > now else { return nil }
            return (thread, until)
        }
    }

    // MARK: VIPs

    /// Conversations in the inbox from a VIP, newest first.
    func vipThreads(_ accountID: UUID?) -> [MailThread] {
        let vips = vipAddresses
        guard !vips.isEmpty else { return [] }
        let located = derived.vips.value {
            _ = inboxOrder
            let vips = vipAddresses
            return locate { thread in thread.messages.contains { vips.contains($0.from.address.lowercased()) } }
        }
        _ = inboxRevision
        let shown: Set<UUID> = accountID.map { [$0] } ?? Set(allInboxesAccounts)
        return located.filter { shown.contains($0.account) }.compactMap { thread(at: $0) }.sorted { $0.date > $1.date }
    }

    // MARK: Labels

    /// Every inbox conversation that carries a label, with its labels.
    private var labelledInInboxes: [(place: Located, labels: [String])] {
        derived.labelled.value {
            _ = inboxOrder
            var byAccount: [UUID?: [String: [String]]] = [:]
            for (key, labels) in labelStore.labelsByThread where !labels.isEmpty {
                guard let bar = key.firstIndex(of: "|") else { continue }
                byAccount[UUID(uuidString: String(key[..<bar])), default: [:]][String(key[key.index(after: bar)...])] = labels
            }
            guard !byAccount.isEmpty else { return [] }
            var found: [(place: Located, labels: [String])] = []
            for account in accounts {
                guard let shelf = shelves[account.id], let labelled = byAccount[account.id] else { continue }
                for row in shelf.threads.indices {
                    let thread = shelf.threads[row]
                    if let labels = labelled[thread.messages.first?.messageID ?? thread.id] {
                        found.append((Located(account: account.id, row: row), labels))
                    }
                }
            }
            return found
        }
    }

    /// The labelled conversations in All Inboxes with one of their labels matching, ignoring case.
    func inboxThreads(labelled name: String) -> [MailThread] {
        let shown = Set(allInboxesAccounts)
        let found = labelledInInboxes.filter { entry in
            shown.contains(entry.place.account) && entry.labels.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        _ = inboxRevision
        return found.compactMap { thread(at: $0.place) }
    }

    /// How many unread conversations carry each label (exact name), across every mailbox.
    var unreadByLabel: [String: Int] {
        derived.unreadByLabel.value {
            _ = inboxRevision
            var counts: [String: Int] = [:]
            for entry in labelledInInboxes {
                guard let shelf = shelves[entry.place.account], entry.place.row < shelf.count,
                      shelf.facts[entry.place.row] & InboxShelf.Facts.unread != 0 else { continue }
                for label in entry.labels { counts[label, default: 0] += 1 }
            }
            return counts
        }
    }

    /// Groups with something in the inbox, with how many.
    public var homeGroups: [(group: EmailGroup, count: Int)] {
        derived.homeGroups.value {
            let shown = Set(allInboxesAccounts)
            let now = Date()
            let snoozed = KeyLookup(snoozes.lazy.filter { $0.value > now }.map(\.key))
            var counts: [String: Int] = [:]
            for entry in labelledInInboxes where shown.contains(entry.place.account) {
                if !snoozed.isEmpty, let thread = thread(at: entry.place), snoozed.contains(thread) { continue }
                for label in Set(entry.labels.map { $0.lowercased() }) { counts[label, default: 0] += 1 }
            }
            return emailGroups.compactMap { group in
                let count = counts[group.name.lowercased()] ?? 0
                return count > 0 ? (group, count) : nil
            }
        }
    }

    // MARK: Senders

    /// How many conversations in a mailbox's inbox each sender started (by lowercased address).
    func senderCounts(in account: UUID) -> [String: Int] {
        derived.senderCounts.value(for: account) {
            _ = inboxOrder
            var counts: [String: Int] = [:]
            for thread in shelves[account]?.threads ?? [] {
                if let address = thread.messages.first?.from.address { counts[address.lowercased(), default: 0] += 1 }
            }
            return counts
        }
    }

    // MARK: Recent

    /// Inbox conversations newer than a moment, across every mailbox: read from the top of each
    /// shelf, not by going through all of it.
    func inboxThreads(since date: Date) -> [MailThread] {
        _ = inboxRevision
        let all = accounts.map { shelves[$0.id] ?? InboxShelf() }
        return ShelfReader(shelves: all, rows: all.map { $0.countNewer(than: date) }).merged()
    }

    /// Unread inbox conversations across every mailbox, newest first, at most `limit`.
    func unreadInInboxes(limit: Int = .max, passes: ((MailThread) -> Bool)? = nil) -> [MailThread] {
        _ = inboxRevision
        var filter = InboxShelf.Filter()
        filter.require(InboxShelf.Facts.unread)
        return ShelfReader(shelves: accounts.map { shelves[$0.id] ?? InboxShelf() }).newest(limit, filter: filter, passes: passes)
    }
}
