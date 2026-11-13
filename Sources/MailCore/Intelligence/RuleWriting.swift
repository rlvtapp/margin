import Foundation

/// A rule for new mail as the assistant wrote it from the person's words ("move everything from
/// my bank to Bills"): plain strings, checked and turned into a real rule by the app, which
/// shows anything that doesn't fit (a folder that isn't there) for the person to fix.
public struct RuleParts: Codable, Hashable, Sendable {
    /// from, to or subject.
    public var field: String
    public var contains: String
    /// archive, trash, mark_read, star, label, group, move, forward, answer or quiet.
    public var action: String
    /// The folder, label or group for move, label and group; the address for forward; the text for answer.
    public var target: String
    /// A mailbox name or address, or "all".
    public var mailbox: String

    public init(field: String, contains: String, action: String, target: String = "", mailbox: String = "all") {
        self.field = field
        self.contains = contains
        self.action = action
        self.target = target
        self.mailbox = mailbox
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        field = try values.decodeIfPresent(String.self, forKey: .field) ?? ""
        contains = try values.decodeIfPresent(String.self, forKey: .contains) ?? ""
        action = try values.decodeIfPresent(String.self, forKey: .action) ?? ""
        target = try values.decodeIfPresent(String.self, forKey: .target) ?? ""
        mailbox = try values.decodeIfPresent(String.self, forKey: .mailbox) ?? "all"
    }

    /// Reads the first JSON object in a model's answer, with or without a code fence around it.
    public static func parse(_ text: String) throws -> RuleParts {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let parts = try? JSONDecoder().decode(RuleParts.self, from: Data(text[start...end].utf8)) else {
            throw NoRuleWritten()
        }
        return parts
    }
}

/// The assistant's answer had no rule in it.
public struct NoRuleWritten: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { String(localized: "The assistant didn't write a rule. Try saying it another way.") }
}

/// What the assistant may use when writing a rule: the person's real folders, labels, groups,
/// mailboxes and the people they deal with, so a rule names things that exist.
public struct RuleContext: Sendable {
    public var mailboxes: [String]
    /// Folder names per mailbox.
    public var folders: [String: [String]]
    public var labels: [String]
    public var groups: [String]
    /// "Name <address>", most written to first.
    public var people: [String]

    public init(mailboxes: [String], folders: [String: [String]], labels: [String], groups: [String], people: [String]) {
        self.mailboxes = mailboxes
        self.folders = folders
        self.labels = labels
        self.groups = groups
        self.people = people
    }
}

extension MailIntelligence {
    /// Writes a rule for new mail from the person's own words.
    public func writeRule(_ words: String, context: RuleContext) async throws -> RuleParts {
        try await model.ruleParts(Self.ruleRequest(words, context: context))
    }

    static func ruleRequest(_ words: String, context: RuleContext) -> ModelRequest {
        let folders = context.folders.sorted { $0.key < $1.key }
            .map { "- \($0.key): \($0.value.prefix(60).joined(separator: ", "))" }.joined(separator: "\n")
        return ModelRequest(
            task: .reply,
            instructions: """
            You turn a person's request about their new email into one mail rule. A rule looks in one field \
            (from: the sender's name or address; to: the recipients; subject) for some text, ignoring case, \
            and does one thing with matching new mail: archive, trash, mark_read, star (also for "important"), \
            label (adds a label), group (puts it in one of their Home groups), move (to a folder), forward \
            (to an email address), answer (replies to the sender with a short text you write in their words) \
            or quiet (no alert for it). \
            Use only the folders, labels, groups and mailboxes listed below, spelled the same; prefer a group when \
            one fits a name they use. For a company or service, look for its domain in the sender's address \
            (like @example.com) when you know it, else its name. Answer with one JSON object and nothing else: \
            {"field":"from|to|subject","contains":"…","action":"…","target":"folder, label or group; the address to forward to; the answer's text; or empty",\
            "mailbox":"a mailbox, or all"}
            """,
            prompt: """
            Mailboxes: \(context.mailboxes.joined(separator: ", "))
            Folders:
            \(folders)
            Labels: \(context.labels.prefix(60).joined(separator: ", "))
            Groups: \(context.groups.joined(separator: ", "))
            People they deal with: \(context.people.prefix(40).joined(separator: "; "))

            Their request: \(words)
            """
        )
    }
}

extension MailIntelligence {
    /// Translates an email's text with the assistant, for languages the system's own translation
    /// doesn't offer. Paragraphs, names, addresses, links and numbers stay as they are.
    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let request = ModelRequest(
            task: .reply,
            instructions: """
            You translate an email from \(source) into \(target). Keep the paragraphs and line breaks, and \
            leave names, email addresses, links, numbers and codes exactly as they are. Write only the \
            translation, with no note before or after it.
            """,
            prompt: String(text.prefix(max(model.transcriptBudget, 2_000)))
        )
        let translated = try await model.reply(request).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw CancellationError() }
        return translated
    }
}
