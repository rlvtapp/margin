import Foundation
import MailCore

/// Reactions (👍 ❤️ 🎉 😆 😮 😢) on messages. Outlook's own reactions stay inside Microsoft's
/// servers with no public way to read or add them, so Margin works with what arrives as mail:
/// Outlook's "Jane reacted to your message" emails and replies that are only an emoji show as a
/// reaction on the message they answer, and reacting sends a short reply in Outlook's shape.
extension MailModel {
    /// The reaction a message is, if it is one.
    public func reaction(in message: MailMessage, of thread: MailThread) -> MailReaction? {
        let content = body(of: message, in: thread)
        return MailReaction.detect(message, text: content?.text ?? message.snippet, html: content?.html, gmail: content?.reaction)
    }

    /// A conversation with its reactions taken out and put on the messages they answer, and
    /// Outlook's own reactions added when they're turned on.
    public func reactionLayout(_ conversation: MailThread) -> MailReaction.Layout {
        var layout = MailReaction.layout(conversation.messages) { reaction(in: $0, of: conversation) }
        guard !outlookReactions.isEmpty, let account = account(conversation.accountID), showsOutlookReactions(account) else { return layout }
        for message in layout.messages {
            guard let found = outlookReactions[Self.bodyKey(conversation.accountID, message.id)], !found.isEmpty else { continue }
            // One per person: Outlook's, unless an email says something newer.
            var list = layout.reactions[message.id] ?? []
            for reaction in found {
                let address = reaction.from.address.lowercased()
                if let index = list.firstIndex(where: { $0.from.address.lowercased() == address }) {
                    if list[index].date < reaction.date { list[index] = reaction }
                } else {
                    list.append(reaction)
                }
            }
            layout.reactions[message.id] = list.sorted { $0.date < $1.date }
        }
        return layout
    }

    // MARK: Outlook's own reactions (opt-in, unofficial)

    /// Whether Outlook's own reactions are read for this account: a Microsoft account where
    /// someone turned it on.
    public func showsOutlookReactions(_ account: MailAccount) -> Bool {
        oauthProvider(of: account) == .microsoft && apiAccess[account.id]?.contains(.reactions) == true
    }

    /// Reads Outlook's reactions on a conversation's newest messages through Graph, each at most
    /// every two minutes. Failures leave what was read before.
    public func loadOutlookReactions(for thread: MailThread) async {
        guard !environment.isPreview, let account = account(thread.accountID), showsOutlookReactions(account) else { return }
        let conversation = conversation(thread)
        let now = Date()
        let due = conversation.messages.suffix(12).filter { message in
            guard message.messageID != nil, reaction(in: message, of: conversation) == nil else { return false }
            let read = outlookReactionsRead[Self.bodyKey(thread.accountID, message.id)]
            return read.map { now.timeIntervalSince($0) > 120 } ?? true
        }
        guard !due.isEmpty, let token = try? await credentials.apiToken(for: account) else { return }
        let graph = MicrosoftGraphClient(accessToken: token)
        let jobs = due.map { (key: Self.bodyKey(thread.accountID, $0.id), messageID: $0.messageID ?? "") }
        for job in jobs { outlookReactionsRead[job.key] = now }
        let found = await withTaskGroup(of: (String, String, [OutlookReactions.Entry]?).self) { group in
            for job in jobs {
                group.addTask { (job.key, job.messageID, try? await graph.outlookReactions(messageID: job.messageID)) }
            }
            var all: [(String, String, [OutlookReactions.Entry]?)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (key, messageID, entries) in found {
            guard let entries else { outlookReactionsRead[key] = nil; continue }
            outlookReactions[key] = entries.map {
                MailReaction(emoji: $0.emoji, from: EmailAddress(name: $0.name.isEmpty ? nil : $0.name, address: $0.address),
                             date: $0.date, messageID: "outlook:\($0.address)", inReplyTo: messageID)
            }
        }
    }

    /// Turns reading Outlook's reactions on: asks the account for reading mail in the sign-in sheet.
    public func turnOnOutlookReactions(for account: MailAccount, authenticate: (URL, String) async throws -> URL) async throws {
        try await requestAccess([.reactions], for: account, authenticate: authenticate)
    }

    /// Turns it off: the account's tokens stop being used for reading mail, and what was read is
    /// forgotten. (The permission itself stays granted in the Microsoft account until removed there.)
    public func turnOffOutlookReactions(for account: MailAccount) async {
        let access = (apiAccess[account.id] ?? []).subtracting([.reactions])
        try? await credentials.setAPIAccess(access, for: account)
        apiAccess[account.id] = access.isEmpty ? nil : access
        let prefix = Self.bodyKey(account.id, "")
        outlookReactions = outlookReactions.filter { !$0.key.hasPrefix(prefix) }
        outlookReactionsRead = outlookReactionsRead.filter { !$0.key.hasPrefix(prefix) }
    }

    /// The conversation without its reactions, so a reply answers the last person who wrote,
    /// not the last who reacted.
    func withoutReactions(_ thread: MailThread) -> MailThread {
        let kept = thread.messages.filter { reaction(in: $0, of: thread) == nil }
        guard !kept.isEmpty, kept.count < thread.messages.count else { return thread }
        return MailThread(id: thread.id, messages: kept, accountID: thread.accountID)
    }

    /// Your addresses in the account a conversation belongs to.
    func myAddresses(for thread: MailThread) -> Set<String> {
        guard let account = account(thread.accountID) else { return [] }
        return Set(([account.address] + (account.aliases ?? [])).map { $0.address.lowercased() })
    }

    /// Whether you're the one who reacted.
    public func isMine(_ reaction: MailReaction, in thread: MailThread) -> Bool {
        myAddresses(for: thread).contains(reaction.from.address.lowercased())
    }

    /// Whether a message can get a reaction from you: a person wrote it, it isn't yours, and
    /// its sender hasn't turned reactions off.
    public func canReact(to message: MailMessage, in thread: MailThread) -> Bool {
        account(thread.accountID) != nil && MailReaction.canReact(to: message, me: myAddresses(for: thread))
    }

    /// Reacts to a message: a short reply to its sender only, in Outlook's shape ("👍 Kaan
    /// reacted to your message:" and the original), sent at once. It shows on the message as
    /// soon as it's sent.
    public func react(_ emoji: String, to message: MailMessage, in thread: MailThread) {
        guard let account = account(thread.accountID), canReact(to: message, in: thread) else { return }
        let me = account.replyAddress(for: thread)
        let original = body(of: message, in: thread)?.text ?? message.snippet
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let draft = MailReaction.reply(emoji, to: message, originalText: original, from: me, language: language)
        Task {
            do {
                try await provider(for: account).send(withSenderName(draft, account: account))
                noteSent(draft, account: account)
                notice = Notice(text: String(localized: "Reacted \(emoji) to \(message.from.displayName)"))
            } catch {
                show(error)
            }
        }
    }

    /// Snapshot mode: two Outlook reaction emails on the open conversation's latest message.
    public func addSampleReactions() {
        guard environment.isPreview, let thread = selectedThread, let accountID = thread.accountID,
              let index = inboxes[accountID]?.firstIndex(where: { $0.id == thread.id }) else { return }
        let target = thread.latest
        let people = [EmailAddress(name: "Sam Okafor", address: "sam@example.com"), EmailAddress(name: "Ines Duarte", address: "ines@example.com")]
        let added = zip(people, ["like", "celebrate"]).enumerated().map { offset, pair in
            MailMessage(id: "sample-reaction-\(offset)", mailboxID: target.mailboxID, messageID: "<sample-reaction-\(offset)@example.com>",
                        inReplyTo: target.messageID, from: pair.0, subject: "RE: \(target.subject)",
                        date: target.date.addingTimeInterval(Double(offset + 1) * 300),
                        snippet: "[\(pair.1)] \(pair.0.displayName) reacted to your message: ________________________________", flags: [.seen])
        }
        inboxes[accountID]?[index] = MailThread(id: thread.id, messages: thread.messages + added, accountID: accountID)
    }
}
