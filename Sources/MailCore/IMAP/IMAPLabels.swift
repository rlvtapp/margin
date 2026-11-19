import Foundation

/// Labels over IMAP, for servers that keep labels instead of folders (the `X-GM-EXT-1`
/// extension). A message carries any number of labels and shows in the folder of each one:
/// the inbox is the `\Inbox` label, archiving takes that label off, and "moving" swaps one
/// label for another. The folders a server lists are views of its labels.
///
/// - Reading: `X-GM-LABELS` in a FETCH lists the labels, `X-GM-THRID` the conversation and
///   `X-GM-MSGID` the message, which is the same in every folder it shows in.
/// - Changing: `UID STORE … +X-GM-LABELS.SILENT (…)` and `-X-GM-LABELS.SILENT (…)`.
public enum IMAPLabels {
    /// The capability that says a server keeps labels.
    static let capability = "X-GM-EXT-1"

    /// What a FETCH asks for besides the usual, on a server that keeps labels.
    static let fetchItems = "X-GM-LABELS X-GM-THRID X-GM-MSGID"

    // MARK: Names

    public static let inbox = "\\Inbox"
    public static let sent = "\\Sent"
    public static let drafts = "\\Draft"
    public static let starred = "\\Starred"
    public static let important = "\\Important"

    /// System labels start with a backslash (`\Inbox`, `\Important`); the person's own don't.
    public static func isSystem(_ label: String) -> Bool { label.hasPrefix("\\") }

    /// The person's own labels, in the order given, without system ones or repeats.
    public static func userLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.filter { !isSystem($0) && seen.insert($0.lowercased()).inserted }
    }

    /// The labels of an `X-GM-LABELS (…)` list, folder names decoded. System labels stay as
    /// they come (`\Inbox`), with the case the server uses for the common ones.
    static func parse(_ value: IMAPValue) -> [String] {
        (value.list ?? []).compactMap { item in
            guard let text = item.string, !text.isEmpty else { return nil }
            if isSystem(text) { return canonical(text) }
            return ModifiedUTF7.decode(text)
        }
    }

    private static func canonical(_ system: String) -> String {
        let known = [inbox, sent, drafts, starred, important, "\\Trash", "\\Spam"]
        return known.first { $0.caseInsensitiveCompare(system) == .orderedSame } ?? system
    }

    /// The label a listed folder stands for: the inbox is `\Inbox`, Sent `\Sent`, the
    /// person's folders their own name. Nil for folders that aren't one label: All Mail, Trash,
    /// Spam (mail goes there by moving, not labelling). Only the server's special-use marks
    /// count, never the name: a label of the person's own called "Work/Sent" is just that.
    static func label(for item: IMAPListItem) -> String? {
        if item.name.uppercased() == "INBOX" { return inbox }
        let marks: [String: String?] = [
            "\\sent": sent, "\\drafts": drafts, "\\flagged": starred, "\\important": important,
            "\\all": nil, "\\trash": nil, "\\junk": nil, "\\archive": nil,
        ]
        for attribute in item.attributes { if let label = marks[attribute] { return label } }
        return ModifiedUTF7.decode(item.name)
    }

    /// Labels a move may take off the folder it leaves: the inbox and the person's own. Sent,
    /// Starred and Important say something about the mail itself, so they stay.
    static func leavesWithMove(_ label: String) -> Bool { label == inbox || !isSystem(label) }

    /// A folder's messages don't list the folder's own label; it's put back here, so a message
    /// read in a label's folder still carries that label. Nil stays nil (no labels read).
    static func adding(_ folderLabel: String?, to labels: [String]?) -> [String]? {
        guard var labels else { return nil }
        if let folderLabel, !labels.contains(where: { $0.caseInsensitiveCompare(folderLabel) == .orderedSame }) {
            labels.insert(folderLabel, at: 0)
        }
        return labels
    }

    // MARK: Commands

    /// One label as a command names it: system labels bare, the person's own quoted and
    /// encoded like a folder name. Nil for a name a command can't carry (a line break).
    static func argument(_ label: String) -> String? {
        if isSystem(label) {
            return label.allSatisfy({ $0.isLetter || $0 == "\\" }) ? label : nil
        }
        return IMAPParser.quoted(ModifiedUTF7.encode(label))
    }

    /// The change part of `UID STORE`: `+X-GM-LABELS.SILENT (\Inbox "Projects/2026")`.
    static func store(_ labels: [String], adding: Bool) -> String? {
        let arguments = labels.compactMap(argument)
        guard !arguments.isEmpty, arguments.count == labels.count else { return nil }
        return "\(adding ? "+" : "-")X-GM-LABELS.SILENT (\(arguments.joined(separator: " ")))"
    }

    /// `UID SEARCH` criteria for the messages with these server ids, in any folder:
    /// `OR X-GM-MSGID 1 OR X-GM-MSGID 2 X-GM-MSGID 3`. Nil for no ids or one that isn't a number.
    static func search(serverIDs ids: [String]) -> String? {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty, unique.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let keys = unique.map { "X-GM-MSGID \($0)" }
        return keys.dropLast().reversed().reduce(keys[keys.count - 1]) { rest, key in "OR \(key) \(rest)" }
    }

    // MARK: Colours

    /// Label colours by name, from the account's label list over HTTPS (IMAP has none).
    /// `#rrggbb` backgrounds; labels without a colour are left out.
    static func colors(fromLabelList data: Data) -> [String: String] {
        struct List: Decodable {
            struct Label: Decodable {
                struct Color: Decodable { var backgroundColor: String? }
                var name: String
                var type: String?
                var color: Color?
            }
            var labels: [Label]?
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [:] }
        var colors: [String: String] = [:]
        for label in list.labels ?? [] where label.type != "system" {
            guard let hex = label.color?.backgroundColor?.lowercased(), hex.count == 7, hex.hasPrefix("#") else { continue }
            colors[label.name] = hex
        }
        return colors
    }

    static let labelListURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels")!
}

extension ModifiedUTF7 {
    /// The other way: printable ASCII stays, `&` becomes `&-`, everything else goes in
    /// `&…-` runs of UTF-16 in base64 with `,` for `/` and no padding.
    static func encode(_ text: String) -> String {
        var result = ""
        var pending: [Character] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let data = String(pending).data(using: .utf16BigEndian) ?? Data()
            let base64 = data.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "")
            result += "&" + base64 + "-"
            pending = []
        }
        for char in text {
            if let ascii = char.asciiValue, ascii >= 0x20, ascii <= 0x7E {
                flush()
                result += char == "&" ? "&-" : String(char)
            } else {
                pending.append(char)
            }
        }
        flush()
        return result
    }
}
