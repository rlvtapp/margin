import Foundation
import MailCore
import Observation

/// Rules kept by the mail server, so they run while every device is off: Microsoft's inbox
/// rules and Gmail's filters through their APIs (asked for the first time they're used), and
/// other IMAP servers through ManageSieve. Margin keeps no copy: the server's list is the list.
/// They're made in the same editor as Margin's own rules (`RuleForm`), and a rule is in one place
/// or the other, so nothing runs twice.
extension MailModel {
    public enum ServerRulesSupport: Equatable {
        /// Ready to read and change.
        case ready
        /// Microsoft or Google: needs the account to allow it first.
        case needsAccess
        /// ManageSieve, if the server offers it (found out on first use).
        case sieve
        /// The server keeps no rules: rules for this mailbox run only while Margin is open.
        case localOnly
    }

    public func serverRulesSupport(_ account: MailAccount) -> ServerRulesSupport {
        // Another person's mailbox: the API only reaches the signed-in person's own rules.
        if case .graph(let shared?) = account.connection, !shared.isEmpty { return .localOnly }
        if oauthProvider(of: account) != nil {
            return apiAccess[account.id]?.contains(.rules) == true ? .ready : .needsAccess
        }
        switch account.connection {
        case .sample: return .ready
        case .imap: if case .password = account.auth { return .sieve } else { return .localOnly }
        case .jmap, .graph: return .localOnly
        }
    }

    /// Each sample mailbox's own "server"; the first one starts with two rules.
    static var sampleServerRules: [UUID: SampleServerRules] = [:]

    func serverRulesAdapter(for account: MailAccount) async throws -> any ServerRulesAdapter {
        if case .sample = account.connection {
            if let kept = Self.sampleServerRules[account.id] { return kept }
            let made = SampleServerRules(seeded: account.id == accounts.first?.id)
            Self.sampleServerRules[account.id] = made
            return made
        }
        guard serverRulesSupport(account) != .localOnly else { throw MailError.notSupported(Self.localOnlyText) }
        switch oauthProvider(of: account) {
        case .microsoft:
            return MicrosoftServerRules(accessToken: try await credentials.apiToken(for: account))
        case .google:
            return GmailServerRules(accessToken: try await credentials.apiToken(for: account),
                                    labelsToken: try await credentials.secret(for: account))
        case nil:
            guard case .imap(let incoming, _) = account.connection, case .password(let username) = account.auth else {
                throw MailError.notSupported(Self.localOnlyText)
            }
            let boxes = mailboxes[account.id] ?? []
            let trash = boxes.first { $0.role == .trash }?.id ?? "Trash"
            let archive = boxes.first { $0.role == .archive }?.id
            let targets = boxes.filter { ![.inbox, .trash, .drafts, .sent, .junk, .all, .flagged, .archive].contains($0.role) }
                .map { ServerFolder(id: $0.id, name: $0.name) }
            return ManageSieveRules(endpoint: ManageSieveRules.endpoint(for: incoming), username: username,
                                    password: try await credentials.secret(for: account), mailboxes: targets,
                                    trashFolder: trash, archiveFolder: archive)
        }
    }

    static var localOnlyText: String {
        String(localized: "This mailbox's server doesn't keep rules, so rules for it run only while Margin is open.")
    }

    /// Everything the editor needs at once: what the server can do, its rules and its folders.
    public func serverRules(for account: MailAccount) async throws -> (features: ServerRuleFeatures, rules: [ServerRule], folders: [ServerFolder]) {
        let adapter = try await serverRulesAdapter(for: account)
        do {
            return (try await adapter.features(), try await adapter.rules(), try await adapter.folders())
        } catch let error as MailError where serverRulesSupport(account) == .sieve {
            // No ManageSieve on this server: say plainly where rules run instead.
            switch error {
            case .connectionFailed, .connectionClosed, .timedOut, .insecureConnection:
                throw MailError.notSupported(Self.localOnlyText)
            default: throw error
            }
        }
    }

    /// Saves a filled-in rule where it runs. A rule that moves from Margin to the server (or
    /// back) is saved in its new place first, then taken out of the old one.
    public func saveRule(_ form: RuleForm, book: ServerRuleBook) async throws {
        switch form.place {
        case .margin:
            guard addRule(form) else { return }
            if case .server(let old, let accountID) = form.editing, let account = account(accountID) {
                try await serverRulesAdapter(for: account).delete(old)
                await book.load(account, model: self)
            }
        case .server:
            guard let rule = form.serverRule, let accountID = form.accountID, let account = account(accountID) else { return }
            let adapter = try await serverRulesAdapter(for: account)
            if case .server(let old, let oldAccountID) = form.editing, oldAccountID != accountID, let oldAccount = self.account(oldAccountID) {
                var fresh = rule
                fresh.id = ""
                try await adapter.save(fresh)
                try await serverRulesAdapter(for: oldAccount).delete(old)
                await book.load(oldAccount, model: self)
            } else {
                try await adapter.save(rule)
            }
            if case .margin(let id) = form.editing { mailRules.removeAll { $0.id == id } }
            if let key = form.suggestionKey { dismissedRuleSuggestions.insert(key) }
            notice = Notice(text: String(localized: "Rule saved on the server"))
            await book.load(account, model: self)
        }
    }

    public func deleteServerRule(_ rule: ServerRule, for account: MailAccount, book: ServerRuleBook) async throws {
        try await serverRulesAdapter(for: account).delete(rule)
        notice = Notice(text: String(localized: "Rule removed from the server"))
        await book.load(account, model: self)
    }

    /// One line on what a server rule does, for its row.
    public static func summary(of rule: ServerRule, folders: [ServerFolder]) -> String {
        var parts: [String] = []
        if !rule.from.isEmpty { parts.append(String(localized: "From contains “\(rule.from)”")) }
        if !rule.to.isEmpty { parts.append(String(localized: "To contains “\(rule.to)”")) }
        if !rule.subject.isEmpty { parts.append(String(localized: "Subject contains “\(rule.subject)”")) }
        if rule.hasAttachment { parts.append(String(localized: "Has an attachment")) }
        var actions: [String] = []
        if rule.delete {
            actions.append(String(localized: "Move to Trash"))
        } else if rule.archive {
            actions.append(String(localized: "Archive"))
        } else if let folder = rule.moveTo {
            let name = folders.first { $0.id == folder }?.name ?? folder
            actions.append(String(localized: "Move to “\(name)”"))
        }
        if rule.markRead { actions.append(String(localized: "Mark as read")) }
        if rule.flag { actions.append(String(localized: "Star")) }
        if !rule.forwardTo.isEmpty { actions.append(String(localized: "Forward to \(rule.forwardTo)")) }
        let when = parts.joined(separator: ", ")
        return actions.isEmpty ? when : when + " → " + actions.joined(separator: ", ")
    }
}

/// The rules each mailbox's server keeps, as Settings → Rules and Create Rule… last read them.
@MainActor @Observable
public final class ServerRuleBook {
    public enum State: Equatable {
        case loading
        case loaded
        /// The server keeps no rules after all (no ManageSieve).
        case localOnly
        case failed(String)
    }

    public private(set) var states: [UUID: State] = [:]
    public private(set) var rules: [UUID: [ServerRule]] = [:]
    public private(set) var folders: [UUID: [ServerFolder]] = [:]
    public private(set) var features: [UUID: ServerRuleFeatures] = [:]

    public init() {}

    /// Reads the rules of every mailbox whose server keeps them.
    public func loadAll(_ model: MailModel) async {
        await withTaskGroup(of: Void.self) { group in
            for account in model.accounts where [.ready, .sieve].contains(model.serverRulesSupport(account)) {
                group.addTask { await self.load(account, model: model) }
            }
        }
    }

    public func load(_ account: MailAccount, model: MailModel) async {
        guard [.ready, .sieve].contains(model.serverRulesSupport(account)) else { return }
        if states[account.id] == nil { states[account.id] = .loading }
        do {
            let found = try await model.serverRules(for: account)
            features[account.id] = found.features
            rules[account.id] = found.rules
            folders[account.id] = found.folders
            states[account.id] = .loaded
        } catch MailError.notSupported {
            rules[account.id] = []
            states[account.id] = .localOnly
        } catch {
            states[account.id] = .failed(error.localizedDescription)
        }
    }

    /// Whether this mailbox's server may still turn out to keep rules: they're being read, or not
    /// read yet.
    public func mightKeep(_ accountID: UUID?, model: MailModel) -> Bool {
        guard let accountID, let account = model.account(accountID),
              [.ready, .sieve].contains(model.serverRulesSupport(account)) else { return false }
        return states[accountID] == nil || states[accountID] == .loading || states[accountID] == .loaded
    }

    /// Whether a rule for this mailbox can be kept on its server now.
    public func canKeep(_ accountID: UUID?) -> Bool {
        guard let accountID else { return false }
        return states[accountID] == .loaded
    }
}
