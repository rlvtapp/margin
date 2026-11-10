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
        let saved = await environment.cache.threads(account: account.id, mailbox: sent.id).flatMap(\.messages)
        if !saved.isEmpty { sentMail[account.id] = saved }
    }

    func loadSentMail(for account: MailAccount) async {
        guard !environment.isPreview, let sent = mailboxes[account.id]?.first(where: { $0.role == .sent }) else { return }
        await loadSavedSentMail(for: account)
        if let loaded = sentMailLoaded[account.id], Date().timeIntervalSince(loaded) < 120 { return }
        sentMailLoaded[account.id] = Date()
        guard let provider = try? provider(for: account), let threads = try? await provider.threads(in: sent, limit: 200) else { return }
        sentMail[account.id] = threads.flatMap(\.messages)
        await environment.cache.saveThreads(threads, account: account.id, mailbox: sent.id)
    }
}
