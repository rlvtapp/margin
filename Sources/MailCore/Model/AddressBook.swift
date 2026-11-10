import Foundation

/// The people in someone's mail, ranked for suggestions while addressing a message: people
/// written to count most, then people who wrote, then everyone else from their address books.
/// Address books also fill in names the mail didn't have.
public struct AddressBook: Sendable {
    public private(set) var entries: [EmailAddress] = []

    public init(threads: [MailThread], me: Set<String>, contacts: [EmailAddress] = []) {
        var score: [String: Int] = [:]
        var names: [String: EmailAddress] = [:]
        func note(_ address: EmailAddress, weight: Int) {
            let key = address.address.lowercased()
            guard !me.contains(key), !key.hasPrefix("noreply"), !key.hasPrefix("no-reply"), !key.contains("donotreply") else { return }
            score[key, default: 0] += weight
            if names[key]?.name == nil { names[key] = address }
        }
        for message in threads.flatMap(\.messages) {
            if me.contains(message.from.address.lowercased()) {
                for person in message.to + message.cc { note(person, weight: 3) }
            } else if InboxSplit.classify(message) == .people {
                note(message.from, weight: 1)
            }
        }
        var known: [String: String] = [:]
        for contact in contacts {
            if let name = contact.name, known[contact.address.lowercased()] == nil { known[contact.address.lowercased()] = name }
        }
        entries = score.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.compactMap { pair in
            guard var entry = names[pair.key] else { return nil }
            if entry.name == nil { entry.name = known[pair.key] }
            return entry
        }
        var listed = Set(entries.map { $0.address.lowercased() })
        let rest = contacts
            .filter { !me.contains($0.address.lowercased()) && listed.insert($0.address.lowercased()).inserted }
            .sorted { ($0.name ?? $0.address).localizedCaseInsensitiveCompare($1.name ?? $1.address) == .orderedAscending }
        entries += rest
    }

    /// The best matches for what's being typed: names and addresses starting with it, or
    /// any word of the name starting with it.
    public func suggestions(for query: String, excluding: Set<String> = [], limit: Int = 4) -> [EmailAddress] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return entries.filter { entry in
            guard !excluding.contains(entry.address.lowercased()) else { return false }
            let words = (entry.name ?? "").lowercased().split(separator: " ").map(String.init)
            return entry.address.lowercased().hasPrefix(query) || words.contains { $0.hasPrefix(query) }
                || (entry.name ?? "").lowercased().hasPrefix(query)
        }
        .prefix(limit)
        .map { $0 }
    }

    /// "Maya <maya@…>, no" → the last part being typed: "no".
    public static func lastToken(of field: String) -> String {
        field.split(separator: ",", omittingEmptySubsequences: false).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Replaces the part being typed with the chosen address and leaves room for the next.
    public static func completing(_ field: String, with address: EmailAddress) -> String {
        var parts = field.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = address.headerValue
        return parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }
}
