import Foundation

/// One newsletter and how much of it you actually read.
public struct NewsletterSender: Identifiable, Hashable, Sendable {
    /// The list's List-Id, or the sender's address when there is none.
    public var id: String
    public var name: String
    public var address: String
    /// Issues seen in the inbox and the archive.
    public var received: Int
    /// Issues that were opened: read on the server, or opened in Margin.
    public var opened: Int
    public var lastReceived: Date
    /// The newest conversation, used to unsubscribe the way the list asks for.
    public var latest: MailThread

    public var openRate: Double { received == 0 ? 0 : Double(opened) / Double(received) }

    /// Worth suggesting: enough issues to judge, and at most one in five opened.
    public var isRarelyRead: Bool { received >= NewsletterReport.minimumIssues && openRate <= 0.2 }
}

public enum NewsletterReport {
    /// Fewer issues than this say too little about whether someone reads a list.
    public static let minimumIssues = 4

    /// Groups newsletter messages by list and counts how many were opened. A message counts as
    /// opened when it's read on the server or its id is in `openedIDs` (opened in Margin).
    public static func senders(from threads: [MailThread], openedIDs: Set<String> = []) -> [NewsletterSender] {
        senders(from: lists(in: threads), openedIDs: openedIDs)
    }

    /// One mailing list's mail, as found in the conversations given.
    public struct MailingList: Sendable {
        public var key: String
        public var messages: [MailMessage]
        public var latest: MailThread
        public var newest: MailMessage
    }

    /// The first half of `senders`: going through every conversation and grouping what's from
    /// mailing lists. It depends only on the mail, so it can be kept while newsletters are being
    /// opened one after another (which changes only the counts below).
    public static func lists(in threads: [MailThread]) -> [MailingList] {
        var groups: [String: (messages: [MailMessage], threads: [MailThread])] = [:]
        var seen = Set<String>()
        for thread in threads {
            for message in thread.messages where InboxSplit.classify(message) == .newsletters {
                // The same issue can be in the inbox list and the archive list.
                guard seen.insert(identity(message)).inserted else { continue }
                let key = listKey(message)
                groups[key, default: ([], [])].messages.append(message)
                groups[key, default: ([], [])].threads.append(thread)
            }
        }
        return groups.compactMap { key, group in
            guard let newest = group.messages.max(by: { $0.date < $1.date }),
                  let latest = group.threads.max(by: { $0.date < $1.date }) else { return nil }
            // A list that people write to (a team's or club's group, a discussion list) carries
            // one List-Id for everyone's mail: that's not a newsletter to unsubscribe from.
            if Set(group.messages.map { $0.from.address.lowercased() }).count >= 3 { return nil }
            return MailingList(key: key, messages: group.messages, latest: latest, newest: newest)
        }
    }

    /// The second half: how much of each list was opened.
    public static func senders(from lists: [MailingList], openedIDs: Set<String>) -> [NewsletterSender] {
        lists.map { list in
            let opened = list.messages.filter { !$0.isUnread || openedIDs.contains(identity($0)) }.count
            return NewsletterSender(
                id: list.key, name: listName(list.newest) ?? list.newest.from.displayName, address: list.newest.from.address,
                received: list.messages.count, opened: opened, lastReceived: list.newest.date, latest: list.latest
            )
        }
        .sorted { $0.openRate == $1.openRate ? $0.received > $1.received : $0.openRate < $1.openRate }
    }

    /// The rarely read ones, most issues first: the clean-up list.
    public static func suggestions(from senders: [NewsletterSender], keeping kept: Set<String> = []) -> [NewsletterSender] {
        senders.filter { $0.isRarelyRead && !kept.contains($0.id) }.sorted { $0.received > $1.received }
    }

    /// How a message is remembered across folders and launches.
    public static func identity(_ message: MailMessage) -> String {
        message.messageID ?? message.id
    }

    /// `List-Id: "Weekly" <weekly.example>` → `Weekly`: the list's own name, when it gives one.
    static func listName(_ message: MailMessage) -> String? {
        guard let listID = message.listHeaders["list-id"], let open = listID.lastIndex(of: "<") else { return nil }
        let name = listID[..<open].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
        return name.isEmpty ? nil : name
    }

    /// `List-Id: Weekly <weekly.example>` → `weekly.example`; otherwise the sender's address.
    public static func listKey(_ message: MailMessage) -> String {
        if let listID = message.listHeaders["list-id"], !listID.isEmpty {
            if let open = listID.lastIndex(of: "<"), let close = listID.lastIndex(of: ">"), open < close {
                return String(listID[listID.index(after: open)..<close]).lowercased()
            }
            return listID.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return message.from.address.lowercased()
    }
}
