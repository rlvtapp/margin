import Foundation
import MailCore

/// Rules from AI apps: the same rules as Settings → Rules (when From, To or Subject contains some
/// text, do one thing with new inbox mail), so a request like "always move mail from my bank to
/// Bills" becomes a rule the person sees and can remove in Settings. Looking at rules and
/// checking what one would match is reading; adding, changing and removing them needs the
/// connection's permission to change things, and `undo_last` puts them back.
enum RuleTools {
    static let maxRules = 200

    private static let condition = #"""
    "field":{"type":"string","enum":["from","to","subject"],"description":"What to look in: from (sender name or address), to (To and Cc), subject."},
    "contains":{"type":"string","description":"Text it must contain, ignoring case: an address, a domain (\"@example.com\"), a name or a word."},
    "mailbox":{"type":"string","description":"A mailbox name or address from list_mailboxes for one mailbox only; \"all\" (or left out) for every mailbox."}
    """#

    private static let action = #"""
    "action":{"type":"string","enum":["archive","trash","mark_read","star","label","group","move","forward","answer","quiet"],"description":"What to do with matching new mail: archive, trash, mark_read, star (Margin's way to mark mail important), label (adds a label), group (puts it in one of Home's groups from list_groups), move (to a folder from list_folders), forward (to an address), answer (replies to the sender with a text, at most every 4 days per sender, never to lists), quiet (no alert). forward and answer send mail by themselves and need the person's permission to send."},
    "target":{"type":"string","description":"The label, group or folder name for label, group and move; the address for forward; the reply text for answer."}
    """#

    static func tools(allowChanges: Bool) -> [MCPTool] {
        var tools = [
            MCPTool(name: "list_rules",
                    description: "Lists the person's rules for new mail (Settings → Rules), each with its id, condition, action and mailbox.",
                    inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
            MCPTool(name: "preview_rule",
                    description: "Shows which inbox conversations a rule would match: an existing one by id, or a condition (field, contains, mailbox) before create_rule. Rules only act on new mail, so act on these with the usual tools (archive, move_to_folder, sort_into_group…) if the person wants existing mail handled too.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string","description":"A rule id from list_rules."},\#(condition),"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Defaults to 50."}},"additionalProperties":false}"#),
        ]
        if allowChanges {
            tools += [
                MCPTool(name: "create_rule",
                        description: "Adds a rule for new inbox mail, shown in Settings → Rules: when field contains the text, do the action. One action per rule; add several rules for several actions. Check names with list_groups, list_folders or list_labels, and preview_rule first. Rules run while Margin is open, before alerts.",
                        inputSchema: #"{"type":"object","properties":{\#(condition),\#(action)},"required":["field","contains","action"],"additionalProperties":false}"#),
                MCPTool(name: "update_rule",
                        description: "Changes a rule from list_rules. Pass only what changes; target alone changes the label, group or folder of the same action.",
                        inputSchema: #"{"type":"object","properties":{"id":{"type":"string","description":"A rule id from list_rules."},\#(condition),\#(action)},"required":["id"],"additionalProperties":false}"#),
                MCPTool(name: "delete_rule",
                        description: "Removes a rule. Mail it already handled stays where it is.",
                        inputSchema: #"{"type":"object","properties":{"id":{"type":"string","description":"A rule id from list_rules."}},"required":["id"],"additionalProperties":false}"#),
            ]
        }
        return tools
    }
}

extension MailModel {
    /// Answers the rule tools; nil for any other tool.
    func runRuleTool(_ name: String, _ arguments: [String: MCPValue]) async throws -> String? {
        switch name {
        case "list_rules":
            return json(agentRules.map(ruleJSON))
        case "preview_rule":
            let rule: MailRule
            if arguments["id"] != nil {
                rule = try agentRule(arguments["id"]?.string)
            } else {
                // Only the condition matters here; any action will do.
                rule = try makeRule(arguments, from: nil, needsAction: false)
            }
            let limit = min(max(arguments["limit"]?.int ?? 50, 1), 200)
            let matched = ruleMatches(rule)
            return json(["rule": ruleJSON(rule), "total": matched.count, "conversations": matched.prefix(limit).map(summaryJSON)] as [String: Any])
        case "create_rule":
            let rule = try makeRule(arguments, from: nil, needsAction: true)
            if let same = mailRules.first(where: { Self.sameRule($0, rule) }) {
                return json(["rule": ruleJSON(same), "note": "This rule already exists; nothing changed."] as [String: Any])
            }
            guard mailRules.count < RuleTools.maxRules else { throw MCPToolError("There are already \(RuleTools.maxRules) rules. Remove some with delete_rule first.") }
            record(.rules(mailRules))
            mailRules.append(rule)
            notice = Notice(text: String(localized: "Rule added by an AI app"))
            return json(["rule": ruleJSON(rule), "note": ruleNote(rule)] as [String: Any])
        case "update_rule":
            let old = try agentRule(arguments["id"]?.string)
            var rule = try makeRule(arguments, from: old, needsAction: true)
            rule.id = old.id
            if let same = mailRules.first(where: { $0.id != old.id && Self.sameRule($0, rule) }) {
                throw MCPToolError("Another rule already does this (id \(same.id.uuidString)). Delete one of them instead.")
            }
            guard let index = mailRules.firstIndex(where: { $0.id == old.id }) else { throw MCPToolError("No rule with that id. Use list_rules.") }
            record(.rules(mailRules))
            mailRules[index] = rule
            notice = Notice(text: String(localized: "Rule changed by an AI app"))
            return json(["rule": ruleJSON(rule), "note": ruleNote(rule)] as [String: Any])
        case "delete_rule":
            let rule = try agentRule(arguments["id"]?.string)
            record(.rules(mailRules))
            mailRules.removeAll { $0.id == rule.id }
            notice = Notice(text: String(localized: "Rule removed by an AI app"))
            return "Removed the rule: \(Self.ruleSummary(rule, mailbox: ruleMailboxName(rule)))."
        default:
            return nil
        }
    }

    /// Rules AI apps may see: every one, except those for mailboxes hidden from them.
    var agentRules: [MailRule] {
        mailRules.filter { rule in rule.accountID.map { !connectionSettings.hiddenAccounts.contains($0) } ?? true }
    }

    private func agentRule(_ id: String?) throws -> MailRule {
        guard let id, !id.isEmpty else { throw MCPToolError("A rule id is needed. Use list_rules.") }
        guard let rule = agentRules.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw MCPToolError("No rule with that id. Use list_rules.")
        }
        return rule
    }

    /// Inbox conversations whose newest message the rule matches, as it would on arrival.
    func ruleMatches(_ rule: MailRule) -> [MailThread] {
        inboxMatches(rule).filter(isVisible)
    }

    /// A rule from tool arguments, checked: a known field, some text, a known mailbox, and a
    /// label, group or folder that exists. With `base`, what isn't passed stays as it was.
    func makeRule(_ arguments: [String: MCPValue], from base: MailRule?, needsAction: Bool) throws -> MailRule {
        let field: MailRule.Field
        if let text = arguments["field"]?.string {
            guard let value = MailRule.Field(rawValue: text.lowercased()) else { throw MCPToolError("“field” must be from, to or subject.") }
            field = value
        } else if let base {
            field = base.field
        } else {
            throw MCPToolError("“field” is needed: from, to or subject.")
        }

        let contains = (arguments["contains"]?.string ?? base?.contains ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contains.isEmpty else {
            throw MCPToolError("“contains” can't be empty: give the text to look for, like an address, a domain or a word in the subject.")
        }
        guard contains.count <= 200 else { throw MCPToolError("“contains” can be 200 characters at most.") }

        var accountID = base?.accountID
        if let mailbox = arguments["mailbox"]?.string?.trimmingCharacters(in: .whitespaces) {
            if mailbox.isEmpty || mailbox.lowercased() == "all" {
                accountID = nil
            } else if let account = matchAccount(mailbox) {
                accountID = account.id
            } else {
                throw MCPToolError("No mailbox “\(mailbox)”. Use list_mailboxes, or leave mailbox out for all of them.")
            }
        }

        let action: MailRule.Action
        let target = arguments["target"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let kind = arguments["action"]?.string?.lowercased() {
            action = try ruleAction(kind, target: target, accountID: accountID)
        } else if let base {
            // A new target alone keeps the kind of action; a new mailbox re-checks a folder.
            let kind = ruleActionKind(base.action)
            action = try ruleAction(kind, target: target ?? ruleTarget(base.action), accountID: accountID)
        } else if needsAction {
            throw MCPToolError("“action” is needed: archive, trash, mark_read, star, label, group, move, forward, answer or quiet.")
        } else {
            action = .archive
        }

        var rule = MailRule(field: field, contains: contains, action: action, accountID: accountID)
        if let base { rule.id = base.id }
        return rule
    }

    private func ruleAction(_ kind: String, target: String?, accountID: UUID?) throws -> MailRule.Action {
        switch kind {
        case "archive": return .archive
        case "trash": return .trash
        case "mark_read", "markread", "read": return .markRead
        case "star", "important": return .star
        case "label":
            let label = try Self.labelName(target)
            // Reuse the existing spelling, so "invoices" lands on "Invoices".
            return .label(allLabels.first { $0.caseInsensitiveCompare(label) == .orderedSame } ?? label)
        case "group":
            guard let target, !target.isEmpty else { throw MCPToolError("A group is needed in “target”. Use list_groups.") }
            guard let group = emailGroups.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
                throw MCPToolError("No group “\(target)”. Use list_groups, or create_group when none fits.")
            }
            return .label(group.name)
        case "move":
            guard let target, !target.isEmpty else { throw MCPToolError("A folder is needed in “target”. Use list_folders.") }
            let scope = accountID.flatMap { id in visibleAccounts.first { $0.id == id } }.map { [$0] } ?? visibleAccounts
            var found: Mailbox?
            for account in scope where found == nil {
                found = folders(of: account.id).first {
                    $0.role != .junk && $0.role != .trash && $0.name.caseInsensitiveCompare(target) == .orderedSame
                }
            }
            guard let found else {
                let place = scope.count == 1 ? scope[0].label : "any mailbox"
                throw MCPToolError("No folder “\(target)” in \(place). Use list_folders, or create_folder first.")
            }
            return .move(found.name)
        case "forward", "answer":
            // These send mail with nobody looking, so they need the permission to send.
            guard connectionSettings.allowSending else {
                throw MCPToolError("Rules that forward or answer send mail by themselves, so they need “Allow sending” in Margin's settings.")
            }
            let text = (target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == "forward" {
                guard EmailAddress.isValid(text) else { throw MCPToolError("“target” must be the address to forward to.") }
                return .forward(text)
            }
            guard !text.isEmpty, text.count <= 2_000 else { throw MCPToolError("“target” must be the answer's text, up to 2000 characters.") }
            return .answer(text)
        case "quiet", "mute", "silence":
            return .quiet
        default:
            throw MCPToolError("“action” must be archive, trash, mark_read, star, label, group, move, forward, answer or quiet.")
        }
    }

    private func ruleActionKind(_ action: MailRule.Action) -> String {
        switch action {
        case .archive: "archive"
        case .trash: "trash"
        case .markRead: "mark_read"
        case .star: "star"
        case .label(let name): emailGroups.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } ? "group" : "label"
        case .move: "move"
        case .forward: "forward"
        case .answer: "answer"
        case .quiet: "quiet"
        }
    }

    private func ruleTarget(_ action: MailRule.Action) -> String? {
        switch action {
        case .label(let name), .move(let name), .forward(let name), .answer(let name): name
        default: nil
        }
    }

    static func sameRule(_ a: MailRule, _ b: MailRule) -> Bool {
        a.field == b.field && a.contains.lowercased() == b.contains.lowercased() && a.action == b.action && a.accountID == b.accountID
    }

    private func ruleMailboxName(_ rule: MailRule) -> String {
        account(rule.accountID)?.label ?? "all mailboxes"
    }

    func ruleJSON(_ rule: MailRule) -> [String: Any] {
        var item: [String: Any] = [
            "id": rule.id.uuidString,
            "field": rule.field.rawValue,
            "contains": rule.contains,
            "action": ruleActionKind(rule.action),
            "mailbox": account(rule.accountID)?.label ?? "all",
            "summary": Self.ruleSummary(rule, mailbox: ruleMailboxName(rule)),
        ]
        if let target = ruleTarget(rule.action) { item["target"] = target }
        return item
    }

    /// "When From contains “github”: label “Updates” (all mailboxes)", for AI apps.
    static func ruleSummary(_ rule: MailRule, mailbox: String) -> String {
        let action = switch rule.action {
        case .archive: "archive"
        case .trash: "move to Trash"
        case .markRead: "mark as read"
        case .star: "star"
        case .label(let name): "label “\(name)”"
        case .move(let folder): "move to “\(folder)”"
        case .forward(let address): "forward to \(address)"
        case .answer(let text): "answer “\(text.prefix(60))”"
        case .quiet: "no alert"
        }
        return "When \(rule.field.rawValue.capitalized) contains “\(rule.contains)”: \(action) (\(mailbox))"
    }

    /// What the AI app should know after saving: rules act on new mail only.
    private func ruleNote(_ rule: MailRule) -> String {
        let now = ruleMatches(rule).count
        let start = "Saved. It applies to new inbox mail while Margin is open and shows in Settings → Rules."
        guard now > 0 else { return start + " Nothing in the inbox matches it right now." }
        return start + " \(Self.count(now)) already in the inbox match it but are left as they are; preview_rule lists them if the person wants those handled too."
    }
}
