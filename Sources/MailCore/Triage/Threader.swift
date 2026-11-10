import Foundation

/// Groups messages into conversations: by reply headers first (In-Reply-To, References); then
/// replies whose headers point outside the fetched window join by subject, preferring the
/// conversation their people were in.
public enum Threader {
    public static func threads(from messages: [MailMessage]) -> [MailThread] {
        var parent = Array(0..<messages.count)
        func root(_ index: Int) -> Int {
            var node = index
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }
        func join(_ a: Int, _ b: Int) {
            let rootA = root(a), rootB = root(b)
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }

        var byMessageID: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            if let id = message.messageID { byMessageID[id] = byMessageID[id] ?? index }
        }
        // Earlier messages by subject: a reply with no known parent joins the conversation its
        // people were part of. Messages that aren't replies never join by subject alone, so
        // repeated notices (three failed payments) stay separate.
        var bySubject: [String: [Int]] = [:]
        func people(_ message: MailMessage) -> Set<String> {
            Set(([message.from] + message.to + message.cc).map { $0.address.lowercased() })
        }
        for (index, message) in messages.enumerated() {
            var linked = false
            for reference in [message.inReplyTo].compactMap({ $0 }) + message.references {
                if let other = byMessageID[reference] {
                    join(index, other)
                    linked = true
                }
            }
            let subject = Subject.normalized(message.subject)
            guard !subject.isEmpty else { continue }
            let isReply = message.inReplyTo != nil || !message.references.isEmpty || Subject.isReply(message.subject)
            let earlier = bySubject[subject] ?? []
            if !linked, !earlier.isEmpty {
                if isReply {
                    let mine = people(message)
                    let match = earlier.first { !people(messages[$0]).isDisjoint(with: mine) } ?? earlier[0]
                    join(index, match)
                }
            }
            bySubject[subject, default: []].append(index)
        }

        var groups: [Int: [MailMessage]] = [:]
        for index in messages.indices { groups[root(index), default: []].append(messages[index]) }
        return groups.values.map { group in
            let sorted = group.sorted { $0.date < $1.date }
            return MailThread(id: sorted[0].id, messages: sorted)
        }
    }
}
