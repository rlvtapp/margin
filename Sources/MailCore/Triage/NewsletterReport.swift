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
            let opened = group.messages.filter { !$0.isUnread || openedIDs.contains(identity($0)) }.count
            return NewsletterSender(
                id: key, name: newest.from.displayName, address: newest.from.address,
                received: group.messages.count, opened: opened, lastReceived: newest.date, latest: latest
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
