import Foundation

/// A rule kept by the mail server, so it runs on new mail even when no device is on: when an
/// email matches every condition that's filled in, the server does each action.
public struct ServerRule: Identifiable, Hashable, Sendable {
    /// The server's id for it; empty for one not saved yet.
    public var id: String
    public var name: String
    /// Conditions: text the sender, recipients or subject contain (empty: not used).
    public var from: String
    public var to: String
    public var subject: String
    public var hasAttachment: Bool
    /// Actions. The folder or label to move it to, by the server's id for it.
    public var moveTo: String?
    /// Out of the inbox into the mailbox's archive.
    public var archive: Bool
    public var markRead: Bool
    public var flag: Bool
    /// An address to send it on to (empty: none).
    public var forwardTo: String
    /// To Trash, never deleted for good.
    public var delete: Bool
    public var isEnabled: Bool
    /// False for a rule made elsewhere with parts Margin can't show: it can be removed here,
    /// but changing it would lose those parts.
    public var isEditable: Bool

    public init(id: String = "", name: String = "", from: String = "", to: String = "", subject: String = "",
                hasAttachment: Bool = false, moveTo: String? = nil, archive: Bool = false, markRead: Bool = false, flag: Bool = false,
                forwardTo: String = "", delete: Bool = false, isEnabled: Bool = true, isEditable: Bool = true) {
        self.id = id
        self.name = name
        self.from = from
        self.to = to
        self.subject = subject
        self.hasAttachment = hasAttachment
        self.moveTo = moveTo
        self.archive = archive
        self.markRead = markRead
        self.flag = flag
        self.forwardTo = forwardTo
        self.delete = delete
        self.isEnabled = isEnabled
        self.isEditable = isEditable
    }

    var trimmedFrom: String { from.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedTo: String { to.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedSubject: String { subject.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedForward: String { forwardTo.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var hasCondition: Bool {
        !trimmedFrom.isEmpty || !trimmedTo.isEmpty || !trimmedSubject.isEmpty || hasAttachment
    }

    public var hasAction: Bool {
        moveTo != nil || archive || markRead || flag || !trimmedForward.isEmpty || delete
    }

    /// Ready to save: something to match, something to do, and a real address to forward to.
    public var isComplete: Bool {
        hasCondition && hasAction && (trimmedForward.isEmpty || EmailAddress.isValid(trimmedForward))
    }

    /// The name to show, made from its conditions when it has none of its own.
    public var title: String {
        let own = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return [trimmedFrom, trimmedTo, trimmedSubject].first { !$0.isEmpty } ?? String(localized: "Rule")
    }
}

/// A folder or label a server rule can move mail to.
public struct ServerFolder: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What a server's rules can do, so the editor offers only that.
public struct ServerRuleFeatures: Hashable, Sendable {
    public var archive: Bool
    public var hasAttachment: Bool
    public var flag: Bool
    /// The server has no flag action; "Flag" marks the email important instead.
    public var flagMarksImportant: Bool
    public var forward: Bool
    /// Rules can be turned off without removing them.
    public var canDisable: Bool
    /// Forwarding only goes to addresses the provider has already verified.
    public var forwardNeedsVerifiedAddress: Bool

    public init(archive: Bool = true, hasAttachment: Bool = true, flag: Bool = true, flagMarksImportant: Bool = false, forward: Bool = true,
                canDisable: Bool = false, forwardNeedsVerifiedAddress: Bool = false) {
        self.archive = archive
        self.hasAttachment = hasAttachment
        self.flag = flag
        self.flagMarksImportant = flagMarksImportant
        self.forward = forward
        self.canDisable = canDisable
        self.forwardNeedsVerifiedAddress = forwardNeedsVerifiedAddress
    }
}

/// Reading and changing the rules a mail server keeps.
public protocol ServerRulesAdapter: Sendable {
    func features() async throws -> ServerRuleFeatures
    func rules() async throws -> [ServerRule]
    func folders() async throws -> [ServerFolder]
    /// Saves a new rule (empty id) or changes one; gives it back as the server keeps it.
    @discardableResult func save(_ rule: ServerRule) async throws -> ServerRule
    func delete(_ rule: ServerRule) async throws
}

// MARK: Microsoft 365 and Outlook.com

/// Graph's inbox rules (`messageRule`). Graph has no flag action, so Flag marks the email
/// important, which is how Outlook's rules show it too.
public struct MicrosoftServerRules: ServerRulesAdapter {
    let http: BearerHTTP
    static let rulesURL = URL(string: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messageRules")!
    static let foldersURL = URL(string: "https://graph.microsoft.com/v1.0/me/mailFolders")!
    static let knownConditions: Set<String> = ["senderContains", "recipientContains", "subjectContains", "hasAttachments"]
    static let knownActions: Set<String> = ["moveToFolder", "markAsRead", "markImportance", "forwardTo", "delete", "stopProcessingRules"]

    public init(accessToken: String, send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) {
        http = BearerHTTP(token: accessToken, send: send)
    }

    public func features() async throws -> ServerRuleFeatures {
        ServerRuleFeatures(flagMarksImportant: true, canDisable: true)
    }

    public func rules() async throws -> [ServerRule] {
        try await rawRules().sorted { ($0["sequence"] as? Int ?? 0) < ($1["sequence"] as? Int ?? 0) }.map(Self.rule(from:))
    }

    private func rawRules() async throws -> [[String: Any]] {
        let data = try await http.data(for: try http.request(Self.rulesURL), forbidden: Self.forbidden)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["value"] as? [[String: Any]] ?? []
    }

    /// One rule from Graph's JSON; anything Margin can't show makes it read-only.
    static func rule(from json: [String: Any]) -> ServerRule {
        let conditions = json["conditions"] as? [String: Any] ?? [:]
        let actions = json["actions"] as? [String: Any] ?? [:]
        func single(_ key: String) -> (text: String, fits: Bool) {
            let values = conditions[key] as? [String] ?? []
            return (values.first ?? "", values.count <= 1)
        }
        let from = single("senderContains"), to = single("recipientContains"), subject = single("subjectContains")
        let forwards = (actions["forwardTo"] as? [[String: Any]] ?? []).compactMap { ($0["emailAddress"] as? [String: Any])?["address"] as? String }
        let importance = actions["markImportance"] as? String
        var editable = from.fits && to.fits && subject.fits && forwards.count <= 1
            && Set(conditions.keys).isSubset(of: knownConditions) && Set(actions.keys).isSubset(of: knownActions)
            && (json["exceptions"] as? [String: Any] ?? [:]).isEmpty
            && (json["isReadOnly"] as? Bool ?? false) == false
        if let importance, importance != "high" { editable = false }
        return ServerRule(id: json["id"] as? String ?? "", name: json["displayName"] as? String ?? "",
                          from: from.text, to: to.text, subject: subject.text,
                          hasAttachment: conditions["hasAttachments"] as? Bool ?? false,
                          moveTo: actions["moveToFolder"] as? String,
                          markRead: actions["markAsRead"] as? Bool ?? false,
                          flag: importance == "high",
                          forwardTo: forwards.first ?? "",
                          delete: actions["delete"] as? Bool ?? false,
                          isEnabled: json["isEnabled"] as? Bool ?? true,
                          isEditable: editable)
    }

    /// The request body for a rule, at `sequence` in the list.
    /// `archiveFolder`: the Archive folder's id, for a rule that archives.
    static func body(for rule: ServerRule, sequence: Int, archiveFolder: String? = nil) -> [String: Any] {
        var conditions: [String: Any] = [:]
        if !rule.trimmedFrom.isEmpty { conditions["senderContains"] = [rule.trimmedFrom] }
        if !rule.trimmedTo.isEmpty { conditions["recipientContains"] = [rule.trimmedTo] }
        if !rule.trimmedSubject.isEmpty { conditions["subjectContains"] = [rule.trimmedSubject] }
        if rule.hasAttachment { conditions["hasAttachments"] = true }
        var actions: [String: Any] = [:]
        if rule.delete {
            actions["delete"] = true
        } else if let folder = rule.archive ? archiveFolder : rule.moveTo {
            actions["moveToFolder"] = folder
        }
        if rule.markRead { actions["markAsRead"] = true }
        if rule.flag { actions["markImportance"] = "high" }
        if !rule.trimmedForward.isEmpty { actions["forwardTo"] = [["emailAddress": ["address": rule.trimmedForward]]] }
        return ["displayName": rule.title, "sequence": sequence, "isEnabled": rule.isEnabled, "conditions": conditions, "actions": actions]
    }

    public func save(_ rule: ServerRule) async throws -> ServerRule {
        // A change is a new rule in the old one's place, then the old one removed: an update
        // could leave behind a condition or action that was cleared.
        let list = try await rawRules()
        let sequence = list.first { $0["id"] as? String == rule.id }?["sequence"] as? Int
            ?? (list.compactMap { $0["sequence"] as? Int }.max() ?? 0) + 1
        let archive = rule.archive ? try await archiveFolderID() : nil
        let data = try await http.data(for: try http.request(Self.rulesURL, method: "POST",
                                                             json: Self.body(for: rule, sequence: sequence, archiveFolder: archive)),
                                       forbidden: Self.forbidden)
        if !rule.id.isEmpty { try await delete(rule) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return rule }
        return Self.rule(from: json)
    }

    public func delete(_ rule: ServerRule) async throws {
        _ = try await http.data(for: try http.request(Self.rulesURL.appending(path: rule.id), method: "DELETE"), forbidden: Self.forbidden)
    }

    /// The Archive folder, by its well-known name.
    func archiveFolderID() async throws -> String {
        let data = try await http.data(for: try http.request(Self.foldersURL.appending(path: "archive")), forbidden: Self.forbidden)
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw MailError.protocolViolation(String(localized: "The answer couldn't be read."))
        }
        return id
    }

    /// Top-level folders and the ones inside them.
    public func folders() async throws -> [ServerFolder] {
        var components = URLComponents(url: Self.foldersURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "$top", value: "250"), URLQueryItem(name: "$expand", value: "childFolders")]
        let data = try await http.data(for: try http.request(components.url!), forbidden: Self.forbidden)
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["value"] as? [[String: Any]] ?? []
        return list.flatMap { folder -> [ServerFolder] in
            guard let id = folder["id"] as? String, let name = folder["displayName"] as? String else { return [] }
            let children = (folder["childFolders"] as? [[String: Any]] ?? []).compactMap { child -> ServerFolder? in
                guard let childID = child["id"] as? String, let childName = child["displayName"] as? String else { return nil }
                return ServerFolder(id: childID, name: name + " / " + childName)
            }
            return [ServerFolder(id: id, name: name)] + children
        }
    }

    static var forbidden: String { String(localized: "This account didn't allow Margin to change its rules. Set up server rules again.") }
}

// MARK: Gmail

/// The Gmail API's filters. Moving is adding the label and taking the email out of the inbox;
/// Gmail can't change a filter, so a change is a new one in place of the old.
public struct GmailServerRules: ServerRulesAdapter {
    let http: BearerHTTP
    /// The mail sign-in, which may list labels (the settings token may not).
    let labelsHTTP: BearerHTTP
    static let filtersURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/filters")!
    static let labelsURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels")!
    static let knownCriteria: Set<String> = ["from", "to", "subject", "hasAttachment"]
    static let knownActions: Set<String> = ["addLabelIds", "removeLabelIds", "forward"]

    public init(accessToken: String, labelsToken: String,
                send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession) {
        http = BearerHTTP(token: accessToken, send: send)
        labelsHTTP = BearerHTTP(token: labelsToken, send: send)
    }

    public func features() async throws -> ServerRuleFeatures {
        ServerRuleFeatures(forwardNeedsVerifiedAddress: true)
    }

    public func rules() async throws -> [ServerRule] {
        let data = try await http.data(for: try http.request(Self.filtersURL))
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["filter"] as? [[String: Any]] ?? []
        return list.map(Self.rule(from:))
    }

    static func rule(from json: [String: Any]) -> ServerRule {
        let criteria = json["criteria"] as? [String: Any] ?? [:]
        let action = json["action"] as? [String: Any] ?? [:]
        var add = Set(action["addLabelIds"] as? [String] ?? [])
        var remove = Set(action["removeLabelIds"] as? [String] ?? [])
        var rule = ServerRule(id: json["id"] as? String ?? "",
                              from: criteria["from"] as? String ?? "", to: criteria["to"] as? String ?? "",
                              subject: criteria["subject"] as? String ?? "",
                              hasAttachment: criteria["hasAttachment"] as? Bool ?? false,
                              forwardTo: action["forward"] as? String ?? "")
        rule.markRead = remove.remove("UNREAD") != nil
        rule.flag = add.remove("STARRED") != nil
        rule.delete = add.remove("TRASH") != nil
        // A user label added while leaving the inbox is a move; leaving it alone is archiving.
        if remove.remove("INBOX") != nil {
            if add.count == 1 { rule.moveTo = add.removeFirst() } else if add.isEmpty { rule.archive = true } else { remove.insert("INBOX") }
        }
        rule.isEditable = add.isEmpty && remove.isEmpty && Set(criteria.keys).isSubset(of: knownCriteria)
            && Set(action.keys).isSubset(of: knownActions)
        return rule
    }

    static func body(for rule: ServerRule) -> [String: Any] {
        var criteria: [String: Any] = [:]
        if !rule.trimmedFrom.isEmpty { criteria["from"] = rule.trimmedFrom }
        if !rule.trimmedTo.isEmpty { criteria["to"] = rule.trimmedTo }
        if !rule.trimmedSubject.isEmpty { criteria["subject"] = rule.trimmedSubject }
        if rule.hasAttachment { criteria["hasAttachment"] = true }
        var add: [String] = [], remove: [String] = []
        if rule.delete {
            add.append("TRASH")
        } else if let label = rule.moveTo {
            add.append(label)
            remove.append("INBOX")
        } else if rule.archive {
            remove.append("INBOX")
        }
        if rule.flag { add.append("STARRED") }
        if rule.markRead { remove.append("UNREAD") }
        var action: [String: Any] = [:]
        if !add.isEmpty { action["addLabelIds"] = add }
        if !remove.isEmpty { action["removeLabelIds"] = remove }
        if !rule.trimmedForward.isEmpty { action["forward"] = rule.trimmedForward }
        return ["criteria": criteria, "action": action]
    }

    public func save(_ rule: ServerRule) async throws -> ServerRule {
        // The new one first, so a refusal leaves the old one working.
        let data = try await http.data(for: try http.request(Self.filtersURL, method: "POST", json: Self.body(for: rule)))
        if !rule.id.isEmpty { try await delete(rule) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return rule }
        return Self.rule(from: json)
    }

    public func delete(_ rule: ServerRule) async throws {
        _ = try await http.data(for: try http.request(Self.filtersURL.appending(path: rule.id), method: "DELETE"))
    }

    /// The person's own labels.
    public func folders() async throws -> [ServerFolder] {
        let data = try await labelsHTTP.data(for: try labelsHTTP.request(Self.labelsURL))
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["labels"] as? [[String: Any]] ?? []
        return list.compactMap { label -> ServerFolder? in
            guard label["type"] as? String == "user", let id = label["id"] as? String, let name = label["name"] as? String else { return nil }
            return ServerFolder(id: id, name: name.replacingOccurrences(of: "/", with: " / "))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: Sample

/// Rules for the sample mailbox, kept in memory, so the editor can be tried without an account.
public actor SampleServerRules: ServerRulesAdapter {
    private var kept: [ServerRule]
    private var next = 3

    /// `seeded`: starts with two rules, to show what they look like.
    public init(seeded: Bool = true) {
        kept = seeded ? [
            ServerRule(id: "1", name: String(localized: "Receipts"), subject: String(localized: "receipt"), moveTo: "receipts", markRead: true),
            ServerRule(id: "2", name: String(localized: "From the team"), from: "@northwind.example", flag: true),
        ] : []
    }

    public func features() async throws -> ServerRuleFeatures { ServerRuleFeatures(canDisable: true) }
    public func rules() async throws -> [ServerRule] { kept }
    public func folders() async throws -> [ServerFolder] {
        [ServerFolder(id: "receipts", name: String(localized: "Receipts")), ServerFolder(id: "travel", name: String(localized: "Travel"))]
    }

    public func save(_ rule: ServerRule) async throws -> ServerRule {
        var rule = rule
        if let index = kept.firstIndex(where: { $0.id == rule.id }) {
            kept[index] = rule
        } else {
            rule.id = String(next)
            next += 1
            kept.append(rule)
        }
        return rule
    }

    public func delete(_ rule: ServerRule) async throws { kept.removeAll { $0.id == rule.id } }
}
