import Foundation
import MailCore

/// A rule for new mail: when a field contains some text, do one thing with it.
public struct MailRule: Codable, Hashable, Identifiable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case from, to, subject

        public var title: String {
            switch self {
            case .from: String(localized: "From")
            case .to: String(localized: "To")
            case .subject: String(localized: "Subject")
            }
        }
    }

    public enum Action: Codable, Hashable, Sendable {
        case archive, trash, markRead, star
        case label(String)
        /// Into the folder with this name, in the mail's own mailbox.
        case move(String)
        /// Sends it on to this address, with its formatting.
        case forward(String)
        /// Answers the sender with this text (once every few days per sender, never lists).
        case answer(String)
        /// No alert or sound for it; it still arrives in the inbox.
        case quiet

        public var title: String {
            switch self {
            case .archive: String(localized: "Archive")
            case .trash: String(localized: "Move to Trash")
            case .markRead: String(localized: "Mark as read")
            case .star: String(localized: "Star")
            case .label(let name): String(localized: "Label “\(name)”")
            case .move(let folder): String(localized: "Move to “\(folder)”")
            case .forward(let address): String(localized: "Forward to \(address)")
            case .answer(let text): String(localized: "Answer “\(String(text.prefix(40)))”")
            case .quiet: String(localized: "Keep quiet (no alert)")
            }
        }
    }

    public var id = UUID()
    public var field: Field
    public var contains: String
    public var action: Action
    /// Only for this mailbox; nil for all of them.
    public var accountID: UUID?

    public init(field: Field, contains: String, action: Action, accountID: UUID? = nil) {
        self.field = field
        self.contains = contains
        self.action = action
        self.accountID = accountID
    }

    public func matches(_ message: MailMessage) -> Bool {
        let needle = contains.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        switch field {
        case .from:
            return message.from.address.lowercased().contains(needle) || (message.from.name ?? "").lowercased().contains(needle)
        case .to:
            return (message.to + message.cc).contains { $0.address.lowercased().contains(needle) || ($0.name ?? "").lowercased().contains(needle) }
        case .subject:
            return message.subject.lowercased().contains(needle)
        }
    }
}

/// Blocked senders, muted conversations and rules, applied to new inbox mail as it arrives (while
/// Margin runs), before any alert.
extension MailModel {
    public var blockedSenders: Set<String> {
        get { _ = priorityRevision; return Set(environment.defaults.stringArray(forKey: "blockedSenders") ?? []) }
        set { environment.defaults.set(newValue.sorted(), forKey: "blockedSenders"); priorityRevision += 1 }
    }

    public var mutedThreads: Set<String> {
        get { _ = priorityRevision; return Set(environment.defaults.stringArray(forKey: "mutedThreads") ?? []) }
        set { environment.defaults.set(newValue.sorted(), forKey: "mutedThreads"); priorityRevision += 1 }
    }

    public var mailRules: [MailRule] {
        get {
            _ = priorityRevision
            return environment.defaults.data(forKey: "mailRules").flatMap { try? JSONDecoder().decode([MailRule].self, from: $0) } ?? []
        }
        set { environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "mailRules"); priorityRevision += 1 }
    }

    public func isBlocked(_ sender: EmailAddress) -> Bool { blockedSenders.contains(sender.address.lowercased()) }
    public func isMuted(_ thread: MailThread) -> Bool { mutedThreads.contains(thread.id) }

    /// Blocks the sender: what's in the inbox from them goes to Trash now, and so does new mail.
    public func block(_ sender: EmailAddress) {
        blockedSenders.insert(sender.address.lowercased())
        let theirs = inboxThreads(nil).filter { $0.latest.from.address.lowercased() == sender.address.lowercased() }
        Task { await apply(.trash, to: theirs, announce: false) }
        notice = Notice(text: String(localized: "Blocked \(sender.displayName). Their mail goes to Trash."))
    }

    public func unblock(_ address: String) { blockedSenders.remove(address.lowercased()) }

    /// Mutes a conversation: it leaves the inbox now, and replies to it skip the inbox.
    public func toggleMute(_ thread: MailThread) {
        if isMuted(thread) {
            mutedThreads.remove(thread.id)
            notice = Notice(text: String(localized: "Conversation unmuted"))
        } else {
            mutedThreads.insert(thread.id)
            Task { await apply(.done, to: [thread], announce: false) }
            notice = Notice(text: String(localized: "Muted. New replies won't reach your inbox."))
        }
    }

    /// Runs on every load, before alerts: new inbox mail from blocked senders goes to Trash,
    /// replies in muted conversations are archived and read, and rules do what they say. Each
    /// message is handled once; the first run only remembers what's already there.
    func applyInboxRules() {
        let threads = inboxThreads(nil)
        let seenKey = "rules.seen"
        var seen = Set(environment.defaults.stringArray(forKey: seenKey) ?? [])
        let firstRun = environment.defaults.object(forKey: seenKey) == nil
        let blocked = blockedSenders, muted = mutedThreads, rules = mailRules
        var actions: [MailAction: [MailThread]] = [:]
        /// What rules move, kept apart so it can be undone; blocked and muted mail isn't.
        var ruleMoves: [MailAction: [MailThread]] = [:]
        var done: [RuleActivity] = []
        let batch = UUID()
        var autoSends: [(rule: MailRule, thread: MailThread)] = []
        var leaving = Set<String>()
        for thread in threads {
            let message = thread.latest
            guard seen.insert(message.id).inserted, !firstRun else { continue }
            if blocked.contains(message.from.address.lowercased()) {
                actions[.trash, default: []].append(thread); leaving.insert(thread.id); continue
            }
            if muted.contains(thread.id) {
                actions[.markRead, default: []].append(thread)
                actions[.done, default: []].append(thread); leaving.insert(thread.id); continue
            }
            for rule in rules where (rule.accountID == nil || rule.accountID == thread.accountID) && rule.matches(message) {
                var did = true
                switch rule.action {
                case .archive, .trash, .move:
                    // One move per email: the first rule that moves it wins.
                    guard !leaving.contains(thread.id), let action = ruleMove(rule.action, for: thread) else { did = false; break }
                    ruleMoves[action, default: []].append(thread); leaving.insert(thread.id)
                case .markRead: actions[.markRead, default: []].append(thread)
                case .star: actions[.star, default: []].append(thread)
                case .label(let name): addLabel(name, to: thread)
                case .forward, .answer:
                    guard autoSends.count < Self.autoSendsPerRun, mayAutoSend(rule.action, to: message, ruleID: rule.id) else { did = false; break }
                    autoSends.append((rule, thread))
                case .quiet: break   // `isQuietByRule` keeps its alert away
                }
                if did {
                    done.append(RuleActivity(date: Date(), batch: batch, subject: message.subject,
                                             sender: message.from.displayName, action: rule.action.title))
                }
            }
        }
        // Kept to a few thousand, which covers any inbox view.
        environment.defaults.set(Array(seen.suffix(5000)), forKey: seenKey)
        if !done.isEmpty { ruleActivity = Array((done.reversed() + ruleActivity).prefix(Self.ruleActivityKept)) }
        if !autoSends.isEmpty { Task { await send(autoSends) } }
        guard !actions.isEmpty || !ruleMoves.isEmpty else { return }
        // Gone from the inbox at once, so no alert goes out for them.
        let moved = threads.filter { thread in ruleMoves.values.contains { $0.contains { $0.id == thread.id } } }
        if !moved.isEmpty { mutationRevision += 1 }
        removeFromInboxes(ids: leaving)
        Task {
            for (action, list) in actions { await apply(action, to: list, announce: false) }
            // What rules moved waits out the undo window, with one notice for all of it.
            if !moved.isEmpty {
                let text = moved.count == 1 ? String(localized: "A rule moved a new email")
                    : String(localized: "Rules moved \(moved.count) new emails")
                await holdForUndo(ruleMoves.map { ($0.key, $0.value) }, removed: moved, notice: text, ruleBatch: batch)
            }
        }
    }

    // MARK: Rules that send

    static let autoSendsPerRun = 20
    /// An automatic answer goes to the same sender once in this long, per rule.
    static let answerEvery: TimeInterval = 4 * 86_400

    /// Whether a rule may forward or answer this email: never the person's own mail, never
    /// mail from robots (no-reply, mailer-daemon), answers never to lists, and an answer only
    /// once every few days for each sender. Forwards never go back to the sender.
    func mayAutoSend(_ action: MailRule.Action, to message: MailMessage, ruleID: UUID, now: Date = Date()) -> Bool {
        let sender = message.from.address.lowercased()
        let mine = Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() })
        guard !mine.contains(sender), !Self.isRobot(sender) else { return false }
        switch action {
        case .forward(let address):
            let target = address.trimmingCharacters(in: .whitespaces).lowercased()
            return EmailAddress.isValid(target) && target != sender
        case .answer:
            guard message.listHeaders.isEmpty else { return false }
            let key = "\(ruleID.uuidString)|\(sender)"
            if let last = ruleAnswers[key], now.timeIntervalSince(last) < Self.answerEvery { return false }
            return true
        default:
            return false
        }
    }

    static func isRobot(_ address: String) -> Bool {
        let local = address.split(separator: "@").first.map(String.init) ?? address
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon", "postmaster", "bounce"]
            .contains { local.contains($0) }
    }

    /// When each sender last got each rule's answer.
    var ruleAnswers: [String: Date] {
        get { (environment.defaults.dictionary(forKey: "rules.answered") as? [String: Date]) ?? [:] }
        set {
            // A month's worth is plenty to keep answers apart.
            let recent = newValue.filter { Date().timeIntervalSince($0.value) < 30 * 86_400 }
            environment.defaults.set(recent, forKey: "rules.answered")
        }
    }

    /// Forwards and answers what rules asked for, each from the mailbox the mail came to.
    private func send(_ items: [(rule: MailRule, thread: MailThread)]) async {
        for (rule, thread) in items {
            guard let account = account(thread.accountID), let provider = try? provider(for: account) else { continue }
            let message = thread.latest
            var draft: Draft
            switch rule.action {
            case .forward(let address):
                let body = try? await provider.body(of: message)
                let subject = "Fwd: " + (Subject.isReply(message.subject) ? String(message.subject.dropFirst(4)) : message.subject)
                draft = Draft(from: account.address, to: EmailAddress.parseList(address) ?? [], subject: subject)
                let original = ForwardedOriginal(message: message, body: body)
                if original.html.isEmpty {
                    draft.text = String(original.quotedText.dropFirst(2))
                } else {
                    draft = original.appended(to: draft)
                }
            case .answer(let text):
                draft = Draft.reply(to: thread, from: account.address)
                draft.to = [message.from]
                draft.cc = []
                let signature = account.signatureText(forReply: true)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                draft.text = text + (signature.isEmpty ? "" : "\n\n" + signature)
                ruleAnswers["\(rule.id.uuidString)|\(message.from.address.lowercased())"] = Date()
            default:
                continue
            }
            do {
                try await provider.send(withSenderName(draft, account: account))
            } catch {
                show(error)
            }
        }
    }

    /// New mail a "keep quiet" rule covers: it arrives without an alert or sound.
    func isQuietByRule(_ thread: MailThread) -> Bool {
        mailRules.contains { rule in
            rule.action == .quiet && (rule.accountID == nil || rule.accountID == thread.accountID) && rule.matches(thread.latest)
        }
    }

    /// The server change for a rule that moves mail; nil when its folder isn't in that mailbox.
    private func ruleMove(_ action: MailRule.Action, for thread: MailThread) -> MailAction? {
        switch action {
        case .archive: return .done
        case .trash: return .trash
        case .move(let folder):
            guard let accountID = thread.accountID,
                  let box = mailboxes[accountID]?.first(where: { $0.name.caseInsensitiveCompare(folder) == .orderedSame }) else { return nil }
            return .move(toMailboxID: box.id)
        default: return nil
        }
    }

    // MARK: Recent activity

    static let ruleActivityKept = 100

    /// What rules did to new mail, newest first, for Settings → Rules.
    public var ruleActivity: [RuleActivity] {
        get {
            _ = priorityRevision
            return environment.defaults.data(forKey: "rules.activity").flatMap { try? JSONDecoder().decode([RuleActivity].self, from: $0) } ?? []
        }
        set { environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "rules.activity"); priorityRevision += 1 }
    }

    /// Undo took back what one run of the rules moved.
    func markRuleActivityUndone(_ batch: UUID) {
        ruleActivity = ruleActivity.map { entry in
            var entry = entry
            if entry.batch == batch { entry.undone = true }
            return entry
        }
    }

    /// Inbox conversations a rule would act on now, newest first: it looks at each one's latest
    /// email, as it does when mail arrives.
    public func inboxMatches(_ rule: MailRule) -> [MailThread] {
        inboxThreads(rule.accountID).filter { rule.matches($0.latest) }
    }
}

/// What a rule did to one new email, for Settings → Rules → Recent activity.
public struct RuleActivity: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    /// One run of the rules: Undo takes back a whole run.
    public var batch: UUID
    public var subject: String
    public var sender: String
    /// What was done, as the rule says it ("Move to “Updates”").
    public var action: String
    public var undone = false
}

extension MailModel {
    /// Colours picked for labels and groups, by lowercased name (palette index).
    public var labelColors: [String: Int] {
        get {
            _ = priorityRevision
            return environment.defaults.data(forKey: "labelColors").flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        }
        set { environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "labelColors"); priorityRevision += 1 }
    }

    /// Picks a label's colour; nil goes back to its automatic one.
    public func setColor(_ index: Int?, forLabel name: String) {
        labelColors[name.lowercased()] = index
    }
}
