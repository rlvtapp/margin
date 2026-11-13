import Foundation
import MailCore

/// A rule Margin offers because of what the person keeps doing by hand: filing one sender's
/// mail into the same folder.
public struct RuleSuggestion: Sendable {
    public var text: String
    public var form: RuleForm
}

extension MailModel {
    /// After this many moves of one sender's mail into one folder, a rule is offered.
    static let filingsBeforeSuggesting = 3

    /// How often each sender's mail was filed into each folder: "account|sender|folder".
    var filingCounts: [String: Int] {
        get { _ = priorityRevision; return (environment.defaults.dictionary(forKey: "rules.filing") as? [String: Int]) ?? [:] }
        set { environment.defaults.set(newValue, forKey: "rules.filing"); priorityRevision += 1 }
    }

    /// Suggestions turned down, by the same key; they aren't offered again.
    var dismissedRuleSuggestions: Set<String> {
        get { _ = priorityRevision; return Set(environment.defaults.stringArray(forKey: "rules.suggestionsDismissed") ?? []) }
        set { environment.defaults.set(newValue.sorted(), forKey: "rules.suggestionsDismissed"); priorityRevision += 1 }
    }

    /// The person moved these conversations into a folder themselves.
    func noteFiling(_ threads: [MailThread], into mailboxID: String) {
        var counts = filingCounts
        for thread in threads {
            guard let accountID = thread.accountID,
                  let folder = mailboxes[accountID]?.first(where: { $0.id == mailboxID }), folder.role == .other else { continue }
            let sender = (thread.messages.last { !isMine($0) } ?? thread.latest).from.address.lowercased()
            counts["\(accountID.uuidString)|\(sender)|\(folder.name)", default: 0] += 1
        }
        // Only the busiest few hundred are kept.
        if counts.count > 300 { counts = Dictionary(uniqueKeysWithValues: counts.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) }) }
        filingCounts = counts
    }

    /// The rule to offer now, if any: a sender filed into one folder again and again, with no
    /// rule doing it yet and not turned down before.
    public var ruleSuggestion: RuleSuggestion? {
        let dismissed = dismissedRuleSuggestions, rules = mailRules
        for (key, count) in filingCounts.sorted(by: { $0.value > $1.value }) where count >= Self.filingsBeforeSuggesting && !dismissed.contains(key) {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, let accountID = UUID(uuidString: parts[0]), account(accountID) != nil else { continue }
            let (sender, folder) = (parts[1], parts[2])
            let covered = rules.contains { rule in
                if case .move(let name) = rule.action, name.caseInsensitiveCompare(folder) == .orderedSame,
                   rule.field == .from, sender.contains(rule.contains.lowercased()) { return true }
                return false
            }
            guard !covered else { continue }
            var form = RuleForm(field: .from, contains: sender, choice: .move, name: folder, accountID: accountID)
            form.suggestionKey = key
            return RuleSuggestion(text: String(localized: "You keep filing mail from \(sender) into “\(folder)”"), form: form)
        }
        return nil
    }

    public func dismissRuleSuggestion() {
        guard let key = ruleSuggestion?.form.suggestionKey else { return }
        dismissedRuleSuggestions.insert(key)
    }
}
