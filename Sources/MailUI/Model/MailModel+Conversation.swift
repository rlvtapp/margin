import Foundation
import MailCore

/// Both sides of a conversation. IMAP keeps your replies in Sent, not the inbox, so an inbox
/// conversation only has the other side; the reader adds the sent messages that belong to it.
/// Only for showing: archiving, deleting and marking read still act on the inbox messages.
extension MailModel {
    /// The conversation with your sent replies (and what you sent that started it) added, in
    /// order. Joined by reply headers only, never by subject, so nothing unrelated comes in.
    public func conversation(_ thread: MailThread) -> MailThread {
        guard let accountID = thread.accountID, let sent = sentMail[accountID], !sent.isEmpty else { return thread }
        let ids = Set(thread.messages.compactMap(\.messageID))
        let referenced = Set(thread.messages.flatMap { $0.references + [$0.inReplyTo].compactMap { $0 } })
        var known = ids
        var added: [MailMessage] = []
        for message in sent.sorted(by: { $0.date < $1.date }) {
            guard let id = message.messageID, !known.contains(id) else { continue }
            let replies = message.inReplyTo.map(known.contains) == true || message.references.contains(where: known.contains)
            guard replies || referenced.contains(id) else { continue }
            known.insert(id)
            added.append(message)
        }
        guard !added.isEmpty else { return thread }
        return MailThread(id: thread.id, messages: (thread.messages + added).sorted { $0.date < $1.date }, accountID: accountID)
    }

    /// Loads an account's recent Sent mail: the saved copy at once, then the server's, at most
    /// every two minutes.
    /// Sent mail saved on this device, for stitching your replies into conversations.
    func loadSavedSentMail(for account: MailAccount) async {
        guard !environment.isPreview, sentMail[account.id] == nil,
              let sent = mailboxes[account.id]?.first(where: { $0.role == .sent }) else { return }
        // Without the saved texts: a reply's text is read when its conversation is opened.
        let saved = await environment.cache.threads(account: account.id, mailbox: sent.id, bodies: false).flatMap(\.messages)
        if !saved.isEmpty { sentMail[account.id] = saved }
        learnSenderName(from: saved, account: account)
    }

    func loadSentMail(for account: MailAccount) async {
        guard !environment.isPreview, let sent = mailboxes[account.id]?.first(where: { $0.role == .sent }) else { return }
        await loadSavedSentMail(for: account)
        if let loaded = sentMailLoaded[account.id], Date().timeIntervalSince(loaded) < 120 { return }
        sentMailLoaded[account.id] = Date()
        guard let provider = try? provider(for: account), let threads = try? await provider.threads(in: sent, limit: 200) else { return }
        let fresh = threads.flatMap(\.messages)
        // Keep what was just sent from here until the server's Sent has its own copy.
        let pending = (sentMail[account.id] ?? []).filter { local in
            local.messageID?.hasPrefix(Self.localSentPrefix) == true && Date().timeIntervalSince(local.date) < 600
                && !fresh.contains { $0.subject == local.subject && abs($0.date.timeIntervalSince(local.date)) < 300 }
        }
        sentMail[account.id] = fresh + pending
        // The newest 200 only: older Sent mail saved here (scrolled to, or downloaded in the
        // background) stays.
        await environment.cache.saveThreads(threads, account: account.id, mailbox: sent.id, limit: 200)
        learnSenderName(from: fresh, account: account)
    }

    /// A mailbox without a sender name takes the one its own Sent mail goes out under (the most
    /// common). A name you typed is never changed.
    func learnSenderName(from sent: [MailMessage], account: MailAccount) {
        guard !environment.isPreview, let index = accounts.firstIndex(where: { $0.id == account.id }),
              Self.isPlaceholderName(accounts[index].address.name, for: accounts[index].address.address) else { return }
        let own = account.address.address.lowercased()
        var counts: [String: Int] = [:]
        for message in sent where message.from.address.lowercased() == own {
            guard let name = message.from.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") else { continue }
            counts[name, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return }
        accounts[index].address.name = best
        try? environment.accounts.save(accounts)
    }

    /// Mailboxes still without a real name (none from sign-in or Sent mail) take your full name
    /// from your other mailboxes: one with two or more words first.
    func fillPlaceholderNames() {
        guard !environment.isPreview else { return }
        let real = accounts.compactMap { account -> String? in
            guard let name = account.address.name, !Self.isPlaceholderName(name, for: account.address.address) else { return nil }
            return name
        }
        guard let best = real.first(where: { $0.split(separator: " ").count >= 2 }) ?? real.first else { return }
        var changed = false
        for index in accounts.indices where Self.isPlaceholderName(accounts[index].address.name, for: accounts[index].address.address) {
            accounts[index].address.name = best
            changed = true
        }
        if changed { try? environment.accounts.save(accounts) }
    }

    /// Mail always goes out with a name: an alias or a reply without one gets the mailbox's
    /// sender name (unless that's only a placeholder such as "iCloud").
    func withSenderName(_ draft: Draft, account: MailAccount) -> Draft {
        guard (draft.from.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return draft }
        let name = (self.account(account.id) ?? account).address.name
        guard !Self.isPlaceholderName(name, for: account.address.address) else { return draft }
        var named = draft
        named.from.name = name
        return named
    }

    /// No name, or one that names the provider or company rather than a person ("Gmail",
    /// "iCloud", "Relevate" for kaan@relevate.app): free to fill from Sent mail.
    static func isPlaceholderName(_ name: String?, for address: String) -> Bool {
        let value = (name ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty || value.contains("@") { return true }
        let providers: Set<String> = ["gmail", "google", "icloud", "apple", "outlook", "hotmail", "microsoft", "microsoft 365",
                                      "office 365", "live", "yahoo", "aol", "fastmail", "proton", "proton mail", "zoho", "gmx",
                                      "mail", "work", "personal", "inbox", "email"]
        if providers.contains(value) { return true }
        let domain = address.lowercased().split(separator: "@").last.map(String.init) ?? ""
        let company = domain.split(separator: ".").first.map(String.init) ?? ""
        return value == company || value == domain
    }

    /// Addresses no person sends from: no-reply, notifications, calendars, postmaster, bounces.
    static func isAutomated(_ address: String) -> Bool {
        let lower = address.lowercased()
        guard let at = lower.lastIndex(of: "@") else { return true }
        let local = lower[..<at], domain = lower[lower.index(after: at)...]
        let robots = ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "calendar", "drive-shares",
                      "mailer-daemon", "postmaster", "bounce", "automated", "alerts", "daemon"]
        if robots.contains(where: { local.contains($0) }) { return true }
        let services = ["google.com", "calendar.google.com", "group.calendar.google.com", "microsoft.com", "apple.com",
                        "facebookmail.com", "github.com"]
        return services.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Aliases come from the provider only now. Ones that were guessed from Sent mail before
    /// (every address added automatically until then) are taken out once; ones you added stay.
    func pruneLearnedAliases() {
        guard !environment.isPreview, !environment.defaults.bool(forKey: "aliasesFromProvidersOnly") else { return }
        for index in accounts.indices {
            let key = "aliasesOffered.\(accounts[index].id.uuidString)"
            let offered = Set(environment.defaults.stringArray(forKey: key) ?? [])
            if let aliases = accounts[index].aliases {
                accounts[index].aliases = aliases.filter { !offered.contains($0.address.lowercased()) }
            }
            environment.defaults.removeObject(forKey: key)
        }
        try? environment.accounts.save(accounts)
        environment.defaults.set(true, forKey: "aliasesFromProvidersOnly")
    }

    /// Addresses that look like this mailbox's own, for providers that don't list aliases
    /// (outlook.com, iCloud): personal mail that arrived here addressed to them and not to the
    /// mailbox's own address, at least twice. Only suggested; nothing is added without a tap.
    public func aliasSuggestions(for account: MailAccount) async -> [EmailAddress] {
        guard let inbox = mailboxes[account.id]?.first(where: { $0.role == .inbox }) else { return [] }
        let messages = await environment.cache.threads(account: account.id, mailbox: inbox.id, limit: 600, bodies: false).flatMap(\.messages)
        let mine = Set(([account.address] + (account.aliases ?? [])).map { $0.address.lowercased() })
        let otherMailboxes = Set(accounts.map { $0.address.address.lowercased() })
        let dismissed = Set(environment.defaults.stringArray(forKey: "aliasSuggestionsDismissed.\(account.id.uuidString)") ?? [])
        var counts: [String: (EmailAddress, Int)] = [:]
        for message in messages {
            // Lists and newsletters are addressed to themselves or to lists, not to you.
            guard !message.listHeaders.keys.contains(where: { $0.lowercased().hasPrefix("list-") }),
                  !Self.isAutomated(message.from.address) else { continue }
            let recipients = message.to + message.cc
            guard !recipients.contains(where: { mine.contains($0.address.lowercased()) }) else { continue }
            let senderDomain = message.from.address.lowercased().split(separator: "@").last
            for recipient in recipients {
                let key = recipient.address.lowercased()
                guard !Self.isAutomated(key), !otherMailboxes.contains(key), !dismissed.contains(key),
                      key.split(separator: "@").last != senderDomain else { continue }
                counts[key] = (recipient, (counts[key]?.1 ?? 0) + 1)
            }
        }
        return counts.values.filter { $0.1 >= 2 }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
    }

    public func dismissAliasSuggestion(_ address: EmailAddress, for account: MailAccount) {
        let key = "aliasSuggestionsDismissed.\(account.id.uuidString)"
        let list = (environment.defaults.stringArray(forKey: key) ?? []) + [address.address.lowercased()]
        environment.defaults.set(list, forKey: key)
    }

    func addAliases(_ found: [EmailAddress], to account: MailAccount) {
        guard !environment.isPreview, let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let others = Set(accounts.map { $0.address.address.lowercased() })
        let key = "aliasesOffered.\(account.id.uuidString)"
        var offered = Set(environment.defaults.stringArray(forKey: key) ?? [])
        var aliases = accounts[index].aliases ?? []
        var known = Set(aliases.map { $0.address.lowercased() })
        for address in found {
            let lower = address.address.lowercased()
            guard EmailAddress.isValid(lower), !others.contains(lower), !known.contains(lower), !offered.contains(lower) else { continue }
            aliases.append(EmailAddress(name: address.name ?? accounts[index].address.name, address: address.address))
            known.insert(lower)
            offered.insert(lower)
        }
        guard aliases.count != (accounts[index].aliases ?? []).count else { return }
        accounts[index].aliases = aliases
        environment.defaults.set(Array(offered), forKey: key)
        try? environment.accounts.save(accounts)
    }

    /// Each mailbox's aliases as its provider lists them: Microsoft 365's addresses for the
    /// mailbox, and Gmail's "Send mail as". outlook.com, iCloud and plain IMAP don't share theirs;
    /// those are added by hand.
    func learnProviderAliases() async {
        for account in accounts {
            let found: [EmailAddress]
            switch oauthProvider(of: account) {
            case .microsoft:
                found = await credentials.microsoftAliases(for: account).map { EmailAddress(address: $0) }
            case .google:
                found = await gmailSendAs(account)
            case nil:
                continue
            }
            addAliases(found.filter { !Self.isAutomated($0.address) }, to: account)
        }
    }

    /// Gmail's "Send mail as" addresses that Gmail has verified, through the mail sign-in.
    private func gmailSendAs(_ account: MailAccount) async -> [EmailAddress] {
        guard let token = try? await credentials.secret(for: account) else { return [] }
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/sendAs")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        struct Page: Decodable {
            var sendAs: [Entry]?
            struct Entry: Decodable { var sendAsEmail: String; var displayName: String?; var isPrimary: Bool?; var verificationStatus: String? }
        }
        let entries = (try? JSONDecoder().decode(Page.self, from: data))?.sendAs ?? []
        return entries.filter { $0.isPrimary != true && ($0.verificationStatus ?? "accepted") == "accepted" }
            .map { EmailAddress(name: $0.displayName?.isEmpty == false ? $0.displayName : nil, address: $0.sendAsEmail) }
    }

    static let localSentPrefix = "margin-sent-"

    /// A message just sent from here joins its conversation at once, instead of after the next
    /// Sent refresh (up to two minutes, and only on reopening): a copy with what was written and
    /// its reply headers, replaced by the server's own copy when Sent is read again shortly after.
    func noteSent(_ draft: Draft, account: MailAccount) {
        var message = MailMessage(id: Self.localSentPrefix + UUID().uuidString, mailboxID: "",
                                  messageID: Self.localSentPrefix + UUID().uuidString, from: draft.from,
                                  subject: draft.subject, date: Date(), snippet: String(draft.text.prefix(200)),
                                  body: MessageBody(text: draft.text, html: draft.html))
        message.to = draft.to
        message.cc = draft.cc
        message.inReplyTo = draft.inReplyTo
        message.references = draft.references
        message.flags.insert(.seen)
        sentMail[account.id, default: []].append(message)
        sentMailLoaded[account.id] = nil
        Task {
            // Give the server a moment to file it in Sent, then read Sent again.
            try? await Task.sleep(for: .seconds(4))
            await loadSentMail(for: account)
        }
    }
}
