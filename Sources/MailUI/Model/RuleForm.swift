import Foundation
import MailCore

/// A rule being made or changed, in Settings → Rules or from a conversation's Create Rule…: one
/// form for every rule, kept loose while it's filled in so anything missing can be pointed out.
/// It's saved where it runs: on the mailbox's server when that server keeps rules (it then runs
/// while every device is off), otherwise in Margin.
public struct RuleForm: Identifiable, Hashable, Sendable {
    /// Where the rule runs.
    public enum Place: String, CaseIterable, Identifiable, Sendable {
        case server, margin
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .server: String(localized: "On the server")
            case .margin: String(localized: "In Margin")
            }
        }
    }

    /// Where matching mail goes; a rule moves it at most once.
    public enum Move: String, CaseIterable, Identifiable, Sendable {
        case none, archive, folder, trash
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .none: String(localized: "Leave in Inbox")
            case .archive: String(localized: "Archive")
            case .folder: String(localized: "Move to folder…")
            case .trash: String(localized: "Move to Trash")
            }
        }
    }

    /// What Create Rule… catches from a conversation.
    public enum Basis: String, CaseIterable, Identifiable, Sendable {
        case sender, domain, subject
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .sender: String(localized: "This sender")
            case .domain: String(localized: "Their domain")
            case .subject: String(localized: "This subject")
            }
        }
    }

    /// The saved rule being changed.
    public enum Editing: Hashable, Sendable {
        case margin(UUID)
        /// As the server had it, with its id, name and whether it's on.
        case server(ServerRule, accountID: UUID)
    }

    public var id = UUID()
    // When…
    public var from = ""
    public var to = ""
    public var subject = ""
    public var hasAttachment = false
    // Then…
    public var move = Move.none
    /// The folder: its name for a rule in Margin, the server's id for it on the server.
    public var folder = ""
    public var markRead = false
    public var star = false
    public var forwardTo = ""
    /// Only in Margin: a label, an answer to the sender, no alert.
    public var label = ""
    public var answer = ""
    public var quiet = false

    public var accountID: UUID?
    public var place = Place.margin
    /// The conversation it was made from, for Create Rule….
    public var threadID: MailThread.ID?
    public var editing: Editing?
    /// The suggestion it came from, so adding it stops the suggestion.
    var suggestionKey: String?

    public init(accountID: UUID? = nil) {
        self.accountID = accountID
    }

    /// A form with one condition filled in.
    public init(field: MailRule.Field, contains: String, accountID: UUID? = nil) {
        self.accountID = accountID
        set(field, contains)
    }

    /// A rule kept in Margin, to change.
    public init(rule: MailRule) {
        accountID = rule.accountID
        editing = .margin(rule.id)
        for condition in rule.conditions {
            if text(condition.field).isEmpty { set(condition.field, condition.contains) }
        }
        hasAttachment = rule.hasAttachment
        for action in rule.actions {
            switch action {
            case .archive: move = .archive
            case .trash: move = .trash
            case .move(let name): move = .folder; folder = name
            case .markRead: markRead = true
            case .star: star = true
            case .label(let name): label = name
            case .forward(let address): forwardTo = address
            case .answer(let text): answer = text
            case .quiet: quiet = true
            }
        }
    }

    /// A rule kept on a mailbox's server, to change.
    public init(server rule: ServerRule, accountID: UUID) {
        self.accountID = accountID
        place = .server
        editing = .server(rule, accountID: accountID)
        from = rule.from
        to = rule.to
        subject = rule.subject
        hasAttachment = rule.hasAttachment
        if rule.delete { move = .trash } else if rule.archive { move = .archive } else if let id = rule.moveTo { move = .folder; folder = id }
        markRead = rule.markRead
        star = rule.flag
        forwardTo = rule.forwardTo
    }

    func text(_ field: MailRule.Field) -> String {
        switch field {
        case .from: from
        case .to: to
        case .subject: subject
        }
    }

    /// Fills in one condition, clearing the others (Create Rule…'s "Catch").
    mutating func catchOnly(_ field: MailRule.Field, _ contains: String) {
        from = ""; to = ""; subject = ""
        set(field, contains)
    }

    mutating func set(_ field: MailRule.Field, _ contains: String) {
        switch field {
        case .from: from = contains
        case .to: to = contains
        case .subject: subject = contains
        }
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var conditions: [MailRule.Condition] {
        MailRule.Field.allCases.compactMap { field in
            let value = Self.trimmed(text(field))
            return value.isEmpty ? nil : MailRule.Condition(field: field, contains: value)
        }
    }

    var hasCondition: Bool { !conditions.isEmpty || hasAttachment }

    /// Actions only Margin can do (a label, an answer, no alert).
    public var needsMargin: Bool { !Self.trimmed(label).isEmpty || !Self.trimmed(answer).isEmpty || quiet }

    /// Sends mail by itself.
    public var sendsMail: Bool { !Self.trimmed(forwardTo).isEmpty || (!Self.trimmed(answer).isEmpty && place == .margin) }

    var hasAction: Bool {
        move != .none || markRead || star || !Self.trimmed(forwardTo).isEmpty
            || (place == .margin && needsMargin)
    }

    /// Ready to save where it runs.
    public var isComplete: Bool {
        hasCondition && hasAction && (move != .folder || !Self.trimmed(folder).isEmpty)
            && (Self.trimmed(forwardTo).isEmpty || EmailAddress.isValid(Self.trimmed(forwardTo)))
            && (place == .margin || (!needsMargin && accountID != nil))
    }

    /// The rule for Margin, once everything it needs is filled in.
    public var rule: MailRule? {
        guard place == .margin, isComplete else { return nil }
        var actions: [MailRule.Action] = []
        switch move {
        case .none: break
        case .archive: actions.append(.archive)
        case .trash: actions.append(.trash)
        case .folder: actions.append(.move(Self.trimmed(folder)))
        }
        if markRead { actions.append(.markRead) }
        if star { actions.append(.star) }
        if !Self.trimmed(label).isEmpty { actions.append(.label(Self.trimmed(label))) }
        if !Self.trimmed(forwardTo).isEmpty { actions.append(.forward(Self.trimmed(forwardTo))) }
        if !Self.trimmed(answer).isEmpty { actions.append(.answer(Self.trimmed(answer))) }
        if quiet { actions.append(.quiet) }
        var rule = MailRule(conditions: conditions, hasAttachment: hasAttachment, actions: actions, accountID: accountID)
        if case .margin(let id) = editing { rule.id = id }
        return rule
    }

    /// The rule for the mailbox's server, once everything it needs is filled in.
    public var serverRule: ServerRule? {
        guard place == .server, isComplete else { return nil }
        var rule = ServerRule()
        if case .server(let old, _) = editing {
            rule.id = old.id
            rule.name = old.name
            rule.isEnabled = old.isEnabled
        }
        rule.from = Self.trimmed(from)
        rule.to = Self.trimmed(to)
        rule.subject = Self.trimmed(subject)
        rule.hasAttachment = hasAttachment
        rule.delete = move == .trash
        rule.archive = move == .archive
        rule.moveTo = move == .folder ? Self.trimmed(folder) : nil
        rule.markRead = markRead
        rule.flag = star
        rule.forwardTo = Self.trimmed(forwardTo)
        return rule
    }

    /// For the matches shown while it's filled in: the conditions alone, whatever the actions.
    var condition: MailRule? {
        hasCondition ? MailRule(conditions: conditions, hasAttachment: hasAttachment, actions: [.archive], accountID: accountID) : nil
    }
}

extension MailModel {
    /// A rule for mail like this conversation's: from its sender, anyone at their domain, or
    /// with its subject, in its mailbox.
    public func ruleForm(for thread: MailThread, basis: RuleForm.Basis) -> RuleForm {
        // The person on the other side, not the person's own reply.
        let sender = (thread.messages.last { !isMine($0) } ?? thread.latest).from
        var form = RuleForm(accountID: thread.accountID)
        form.threadID = thread.id
        switch basis {
        case .sender:
            form.catchOnly(.from, sender.address.lowercased())
        case .domain:
            form.catchOnly(.from, sender.address.split(separator: "@").last.map { "@" + $0.lowercased() } ?? sender.address)
        case .subject:
            form.catchOnly(.subject, Self.plainSubject(thread.subject))
        }
        return form
    }

    /// "Re: Fwd: Weekly report" → "Weekly report", so a rule catches the next one too.
    static func plainSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while let range = text.range(of: #"^(re|fwd?|aw|wg|sv|vs|tr|rv)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return text
    }

    /// Starts Create Rule… for a conversation.
    public func startRule(for thread: MailThread) {
        creatingRule = ruleForm(for: thread, basis: .sender)
    }

    /// The folder a move rule names isn't in any mailbox it covers, so it would do nothing.
    public func ruleFolderMissing(_ form: RuleForm) -> Bool {
        let name = RuleForm.trimmed(form.folder)
        guard form.place == .margin, form.move == .folder, !name.isEmpty else { return false }
        let scope = form.accountID.map { [$0] } ?? accounts.map(\.id)
        return !scope.contains { id in
            folders(of: id).contains { $0.role != .junk && $0.role != .trash && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Folder names a move rule can use, in the mailboxes it covers.
    public func ruleFolderNames(for accountID: UUID?) -> [String] {
        let scope = accountID.map { [$0] } ?? accounts.map(\.id)
        var seen = Set<String>()
        return scope.flatMap { folders(of: $0) }
            .filter { $0.role != .junk && $0.role != .trash && $0.role != .drafts }
            .map(\.name)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Labels and Home's groups, for a label rule.
    public var ruleLabelNames: [String] {
        var seen = Set<String>()
        return (emailGroups.map(\.name) + allLabels).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Saves a filled-in rule, in place of the one being changed; the same rule twice is kept once.
    @discardableResult
    public func addRule(_ form: RuleForm) -> Bool {
        guard let rule = form.rule else { return false }
        if let key = form.suggestionKey { dismissedRuleSuggestions.insert(key) }
        if case .margin(let editing) = form.editing, let index = mailRules.firstIndex(where: { $0.id == editing }) {
            mailRules[index] = rule
        } else if !mailRules.contains(where: { Self.sameRule($0, rule) }) {
            mailRules.append(rule)
        }
        return true
    }

    /// Rules to start from, filled in for the common cases; anything left blank is marked.
    public static var starterRules: [(title: String, form: RuleForm)] {
        func form(_ field: MailRule.Field, _ contains: String, _ fill: (inout RuleForm) -> Void) -> RuleForm {
            var form = RuleForm(field: field, contains: contains)
            fill(&form)
            return form
        }
        return [(String(localized: "Mark newsletters as read"), form(.from, "newsletter") { $0.markRead = true }),
                (String(localized: "Archive receipts"), form(.subject, String(localized: "receipt")) { $0.move = .archive }),
                (String(localized: "Label invoices"), form(.subject, String(localized: "invoice")) { $0.label = String(localized: "Invoices") }),
                (String(localized: "Star mail from someone"), form(.from, "") { $0.star = true }),
                (String(localized: "No alerts for notifications"), form(.from, "notifications@") { $0.quiet = true }),
                (String(localized: "Answer while you're away"), form(.to, "") { $0.answer = String(localized: "Thanks for your email. I'll get back to you next week.") })]
    }

    // MARK: Writing a rule from words

    /// What the assistant may name: the person's real mailboxes, folders, labels, groups and people.
    func ruleContext() -> RuleContext {
        RuleContext(
            mailboxes: accounts.map(\.label),
            folders: Dictionary(accounts.map { account in (account.label, ruleFolderNames(for: account.id)) }, uniquingKeysWith: { $0 + $1 }),
            labels: allLabels,
            groups: emailGroups.map(\.name),
            people: addressBook.entries.prefix(40).map(\.headerValue)
        )
    }

    /// "Always star mail from my bank" → a filled-in form to check and add.
    public func writeRule(_ words: String) async throws -> RuleForm {
        guard let intelligence else { throw NoRuleWritten() }
        let parts = try await intelligence.writeRule(words, context: ruleContext())
        return ruleForm(from: parts)
    }

    /// The assistant's parts as a form, matched loosely to real names; anything that doesn't
    /// fit stays as written, for the form to point out.
    func ruleForm(from parts: RuleParts) -> RuleForm {
        var form = RuleForm()
        form.set(MailRule.Field(rawValue: parts.field.lowercased()) ?? .from, parts.contains.trimmingCharacters(in: .whitespacesAndNewlines))
        let mailbox = parts.mailbox.trimmingCharacters(in: .whitespaces).lowercased()
        form.accountID = accounts.first { $0.label.lowercased() == mailbox || $0.address.address.lowercased() == mailbox }?.id
        let target = parts.target.trimmingCharacters(in: .whitespacesAndNewlines)
        switch parts.action.lowercased() {
        case "trash": form.move = .trash
        case "mark_read", "markread", "read": form.markRead = true
        case "star", "important": form.star = true
        case "label", "group":
            form.label = ruleLabelNames.first { $0.caseInsensitiveCompare(target) == .orderedSame } ?? target
        case "move":
            form.move = .folder
            form.folder = ruleFolderNames(for: form.accountID).first { $0.caseInsensitiveCompare(target) == .orderedSame } ?? target
        case "forward":
            form.forwardTo = target
        case "answer":
            form.answer = target
        case "quiet":
            form.quiet = true
        default: form.move = .archive
        }
        return form
    }
}
