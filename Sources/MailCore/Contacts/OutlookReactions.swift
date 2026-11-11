import Foundation

/// Outlook's own reactions on a Microsoft 365 message, read from the mailbox through Graph.
///
/// Unofficial: Microsoft offers no API for mail reactions. Outlook keeps them in undocumented
/// mailbox properties (named in a Microsoft blog post, not in the Exchange specifications), which
/// Graph returns like any other extended property. `ReactionsSummary` is a small binary list
/// decoded the way MSGReader (`Reaction.cs`, MIT) and Glen Scales' `Reactions.ps1` do. Microsoft
/// can change any of this without notice; when it does, reading returns nothing.
/// Needs `Mail.Read`, asked for only when someone turns it on.
public enum OutlookReactions {
    /// One person's reaction.
    public struct Entry: Hashable, Sendable {
        public var emoji: String
        public var name: String
        public var address: String
        public var date: Date
        /// They were a hidden recipient: only they and the sender see it.
        public var isBcc: Bool

        public init(emoji: String, name: String, address: String, date: Date, isBcc: Bool = false) {
            self.emoji = emoji
            self.name = name
            self.address = address
            self.date = date
            self.isBcc = isBcc
        }
    }

    static let propertySet = "{41F28F13-83F4-4114-A584-EEDB5A6B0BFF}"
    static let summaryID = "Binary \(propertySet) name ReactionsSummary"
    static let countID = "Integer \(propertySet) name ReactionsCount"

    /// Minutes are counted from the start of 1601, as Windows file times are.
    static let epoch = Date(timeIntervalSince1970: -11_644_473_600)

    /// Reads `ReactionsSummary`: "v" and a version byte; counts ("=" and a 16-bit count each) up
    /// to a zero byte; then per person a flag byte (1 = Bcc), the time as 32-bit minutes since
    /// 1601, and "emoji,name,address," up to a zero byte. Nil when it isn't in that shape.
    public static func decodeSummary(_ data: Data) -> [Entry]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == UInt8(ascii: "v"), bytes[1] >= 1 else { return nil }
        var index = 2
        // The counts: skip them; each person is listed below.
        while index < bytes.count, bytes[index] != 0 {
            if bytes[index] == UInt8(ascii: "=") { index += 2 }
            index += 1
        }
        guard index < bytes.count else { return [] }
        index += 1
        var entries: [Entry] = []
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let minutes = Int32(bitPattern: UInt32(bytes[index + 1]) | UInt32(bytes[index + 2]) << 8
                                | UInt32(bytes[index + 3]) << 16 | UInt32(bytes[index + 4]) << 24)
            index += 5
            func field() -> String? {
                guard let end = bytes[index...].firstIndex(of: UInt8(ascii: ",")) else { return nil }
                defer { index = end + 1 }
                return String(decoding: bytes[index..<end], as: UTF8.self)
            }
            guard let emoji = field(), let name = field(), let address = field() else { return entries }
            // Whatever else the record holds, up to its end.
            index = (bytes[index...].firstIndex(of: 0) ?? bytes.count) + 1
            // "0" is a reaction taken back.
            guard !emoji.isEmpty, emoji != "0", emoji.first.map(MailReaction.isEmoji) == true else { continue }
            let date = minutes >= 0 ? epoch.addingTimeInterval(Double(minutes) * 60) : Date()
            entries.append(Entry(emoji: emoji, name: name, address: address, date: date, isBcc: flags & 1 != 0))
        }
        return entries
    }

    /// The reverse, for tests: the same layout `decodeSummary` reads.
    static func encodeSummary(_ entries: [Entry]) -> Data {
        var bytes: [UInt8] = [UInt8(ascii: "v"), 1]
        let counts = Dictionary(grouping: entries, by: \.emoji)
        for (emoji, list) in counts.sorted(by: { $0.key < $1.key }) {
            bytes += Array(emoji.utf8) + [UInt8(ascii: "=")]
            bytes += [UInt8(list.count & 0xFF), UInt8(list.count >> 8)]
        }
        bytes.append(0)
        for entry in entries {
            bytes.append(entry.isBcc ? 1 : 0)
            let minutes = UInt32(bitPattern: Int32(entry.date.timeIntervalSince(epoch) / 60))
            bytes += [UInt8(minutes & 0xFF), UInt8(minutes >> 8 & 0xFF), UInt8(minutes >> 16 & 0xFF), UInt8(minutes >> 24)]
            bytes += Array("\(entry.emoji),\(entry.name),\(entry.address),".utf8)
            bytes.append(0)
        }
        return Data(bytes)
    }

    /// The reactions in a Graph message's extended properties; nil when it has none.
    static func entries(in properties: [GraphExtendedProperty]) -> [Entry]? {
        // Graph may return the name with other capitals than were asked for.
        guard let summary = properties.first(where: { $0.id.lowercased().hasSuffix("name reactionssummary") }),
              let data = Data(base64Encoded: summary.value) else { return nil }
        return decodeSummary(data)
    }
}

struct GraphExtendedProperty: Decodable {
    var id: String
    var value: String
}

struct GraphReactionMessage: Decodable {
    var id: String
    var internetMessageId: String?
    var singleValueExtendedProperties: [GraphExtendedProperty]?
}

extension MicrosoftGraphClient {
    /// Outlook's reactions on the message with this Message-ID (in any folder, Sent included);
    /// empty when it has none or isn't in this mailbox.
    public func outlookReactions(messageID: String) async throws -> [OutlookReactions.Entry] {
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !bare.isEmpty else { return [] }
        // OData strings double their quotes.
        let quoted = "<\(bare)>".replacingOccurrences(of: "'", with: "''")
        let expand = "singleValueExtendedProperties($filter=id eq '\(OutlookReactions.summaryID)' or id eq '\(OutlookReactions.countID)')"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
        let query = [
            ("$filter", "internetMessageId eq '\(quoted)'"),
            ("$select", "id,internetMessageId"),
            ("$expand", expand),
            ("$top", "5"),
        ].map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        guard let url = URL(string: "\(Self.base)/me/messages?\(query)") else { return [] }
        let (data, response) = try await http.response(for: http.request(url))
        // No such message here, or the permission was taken back: nothing to show.
        if [400, 403, 404].contains(response.statusCode) { return [] }
        try http.check(data, response)
        let page = try BearerHTTP.decode(GraphPage<GraphReactionMessage>.self, from: data)
        // The same message can sit in two folders (a copy you moved); take whichever has reactions.
        return page.value.lazy.compactMap { OutlookReactions.entries(in: $0.singleValueExtendedProperties ?? []) }
            .first { !$0.isEmpty } ?? []
    }
}
