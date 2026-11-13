import Foundation
import MailCore

/// A rule being made, in Settings → Rules or from a conversation's Create Rule…: the same parts
/// as `MailRule`, kept loose while it's filled in so anything missing can be pointed out.
public struct RuleForm: Identifiable, Hashable, Sendable {
    public enum Choice: String, CaseIterable, Identifiable, Sendable {
        case archive, trash, markRead, star, label, move, forward, answer, quiet
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .archive: String(localized: "Archive")
            case .trash: String(localized: "Move to Trash")
            case .markRead: String(localized: "Mark as read")
            case .star: String(localized: "Star")
            case .label: String(localized: "Label…")
            case .move: String(localized: "Move to folder…")
            case .forward: String(localized: "Forward to…")
            case .answer: String(localized: "Answer with…")
            case .quiet: String(localized: "Keep quiet (no alert)")
            }
        }
        public var needsName: Bool { [.label, .move, .forward, .answer].contains(self) }
        /// Sends mail by itself.
        public var sendsMail: Bool { self == .forward || self == .answer }
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

    public var id = UUID()
    public var field = MailRule.Field.from
    public var contains = ""
    public var choice = Choice.archive
    /// The label or folder, for those choices.
    public var name = ""
    public var accountID: UUID?
    /// The conversation it was made from, for Create Rule….
    public var threadID: MailThread.ID?
    /// The saved rule being changed; nil for a new one.
    public var editing: UUID?
    /// The suggestion it came from, so adding it stops the suggestion.
    var suggestionKey: String?

    public init(field: MailRule.Field = .from, contains: String = "", choice: Choice = .archive, name: String = "", accountID: UUID? = nil) {
        self.field = field
        self.contains = contains
        self.choice = choice
        self.name = name
        self.accountID = accountID
    }

    /// A saved rule, to change.
    public init(rule: MailRule) {
        field = rule.field
        contains = rule.contains
        accountID = rule.accountID
        editing = rule.id
        switch rule.action {
        case .archive: choice = .archive
        case .trash: choice = .trash
        case .markRead: choice = .markRead
        case .star: choice = .star
        case .label(let name): choice = .label; self.name = name
        case .move(let folder): choice = .move; name = folder
        case .forward(let address): choice = .forward; name = address
        case .answer(let text): choice = .answer; name = text
        case .quiet: choice = .quiet
        }
    }

    var trimmedContains: String { contains.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The rule, once everything it needs is filled in.
    public var rule: MailRule? {
        guard !trimmedContains.isEmpty, !choice.needsName || !trimmedName.isEmpty else { return nil }
        if choice == .forward, !EmailAddress.isValid(trimmedName) { return nil }
        let action: MailRule.Action = switch choice {
        case .archive: .archive
        case .trash: .trash
        case .markRead: .markRead
        case .star: .star
        case .label: .label(trimmedName)
        case .move: .move(trimmedName)
        case .forward: .forward(trimmedName)
        case .answer: .answer(trimmedName)
        case .quiet: .quiet
        }
        var rule = MailRule(field: field, contains: trimmedContains, action: action, accountID: accountID)
        if let editing { rule.id = editing }
        return rule
    }

    /// For the matches shown while it's filled in: the condition alone, whatever the action.
    var condition: MailRule? {
        trimmedContains.isEmpty ? nil : MailRule(field: field, contains: trimmedContains, action: .archive, accountID: accountID)
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
            form.field = .from
            form.contains = sender.address.lowercased()
        case .domain:
            form.field = .from
            form.contains = sender.address.split(separator: "@").last.map { "@" + $0.lowercased() } ?? sender.address
        case .subject:
            form.field = .subject
            form.contains = Self.plainSubject(thread.subject)
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
        guard form.choice == .move, !form.trimmedName.isEmpty else { return false }
        let scope = form.accountID.map { [$0] } ?? accounts.map(\.id)
        return !scope.contains { id in
            folders(of: id).contains { $0.role != .junk && $0.role != .trash && $0.name.caseInsensitiveCompare(form.trimmedName) == .orderedSame }
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
        if let editing = form.editing, let index = mailRules.firstIndex(where: { $0.id == editing }) {
            mailRules[index] = rule
        } else if !mailRules.contains(where: { Self.sameRule($0, rule) }) {
            mailRules.append(rule)
        }
        return true
    }

    /// Rules to start from, filled in for the common cases; anything left blank is marked.
    public static var starterRules: [(title: String, form: RuleForm)] {
        [(String(localized: "Mark newsletters as read"), RuleForm(field: .from, contains: "newsletter", choice: .markRead)),
         (String(localized: "Archive receipts"), RuleForm(field: .subject, contains: String(localized: "receipt"), choice: .archive)),
         (String(localized: "Label invoices"), RuleForm(field: .subject, contains: String(localized: "invoice"), choice: .label, name: String(localized: "Invoices"))),
         (String(localized: "Star mail from someone"), RuleForm(field: .from, contains: "", choice: .star)),
         (String(localized: "No alerts for notifications"), RuleForm(field: .from, contains: "notifications@", choice: .quiet)),
         (String(localized: "Answer while you're away"), RuleForm(field: .to, contains: "", choice: .answer))]
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
        form.field = MailRule.Field(rawValue: parts.field.lowercased()) ?? .from
        form.contains = parts.contains.trimmingCharacters(in: .whitespacesAndNewlines)
        let mailbox = parts.mailbox.trimmingCharacters(in: .whitespaces).lowercased()
        form.accountID = accounts.first { $0.label.lowercased() == mailbox || $0.address.address.lowercased() == mailbox }?.id
        let target = parts.target.trimmingCharacters(in: .whitespacesAndNewlines)
        switch parts.action.lowercased() {
        case "trash": form.choice = .trash
        case "mark_read", "markread", "read": form.choice = .markRead
        case "star", "important": form.choice = .star
        case "label", "group":
            form.choice = .label
            form.name = ruleLabelNames.first { $0.caseInsensitiveCompare(target) == .orderedSame } ?? target
        case "move":
            form.choice = .move
            form.name = ruleFolderNames(for: form.accountID).first { $0.caseInsensitiveCompare(target) == .orderedSame } ?? target
        case "forward":
            form.choice = .forward
            form.name = target
        case "answer":
            form.choice = .answer
            form.name = target
        case "quiet":
            form.choice = .quiet
        default: form.choice = .archive
        }
        return form
    }
}
