import Foundation

/// A typed search (`SearchQuery`) as an `Email/query` filter (RFC 8621 §4.4.1).
enum JMAPSearch {
    /// The filter: one condition per term, joined with `AND`, or the one condition alone. `to:`
    /// looks in To and Cc, as on the device. `mailboxID` is the folder `in:` names, found
    /// among the account's folders by the caller. Nil when there's nothing to ask for.
    static func filter(_ query: SearchQuery, mailboxID: String? = nil) -> [String: Any]? {
        var conditions: [[String: Any]] = []
        conditions += query.from.map { ["from": $0] }
        conditions += query.to.map { ["operator": "OR", "conditions": [["to": $0], ["cc": $0]]] }
        conditions += query.subject.map { ["subject": $0] }
        if query.hasAttachment { conditions.append(["hasAttachment": true]) }
        if let isUnread = query.isUnread { conditions.append([isUnread ? "notKeyword" : "hasKeyword": "$seen"]) }
        if let isStarred = query.isStarred { conditions.append([isStarred ? "hasKeyword" : "notKeyword": "$flagged"]) }
        if let after = query.after { conditions.append(["after": utc(after)]) }
        if let before = query.before { conditions.append(["before": utc(before)]) }
        if let mailboxID { conditions.append(["inMailbox": mailboxID]) }
        if !query.words.isEmpty { conditions.append(["text": query.words.joined(separator: " ")]) }
        switch conditions.count {
        case 0: return nil
        case 1: return conditions[0]
        default: return ["operator": "AND", "conditions": conditions]
        }
    }

    /// RFC 3339 in UTC, as `UTCDate` asks.
    static func utc(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
