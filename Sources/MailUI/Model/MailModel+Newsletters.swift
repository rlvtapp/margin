import Foundation
import MailCore

/// What Margin remembers about newsletters, on this device only.
struct NewsletterState: Codable, Sendable {
    /// Issues opened in Margin, by message id.
    var opened: Set<String> = []
    /// Lists that were kept or left, so they aren't suggested again.
    var settled: Set<String> = []
}

extension MailModel {
    /// Every newsletter in the inbox and the archive, least read first.
    public var newsletterSenders: [NewsletterSender] {
        NewsletterReport.senders(from: inboxThreads(nil) + newsletterHistory, openedIDs: newsletterState.opened)
    }

    /// "You opened 1 of 22": lists worth leaving, most issues first.
    public var newsletterSuggestions: [NewsletterSender] {
        NewsletterReport.suggestions(from: newsletterSenders, keeping: newsletterState.settled)
    }

    /// Every issue of one newsletter in the inbox and the archive, newest first.
    public func issues(of listID: String) -> [MailThread] {
        var seen = Set<String>()
        return (inboxThreads(nil) + newsletterHistory)
            .filter { thread in thread.messages.contains { NewsletterReport.listKey($0) == listID } }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date > $1.date }
    }

    /// Loads older issues from each mailbox's archive, to count how much of each list was read.
    public func refreshNewsletterHistory() async {
        loadNewsletterStateIfNeeded()
        var history: [MailThread] = []
        for account in accounts {
            guard let archive = mailboxes[account.id]?.first(where: { $0.role == .archive }) ?? mailboxes[account.id]?.first(where: { $0.role == .all }),
                  let provider = try? provider(for: account),
                  let threads = try? await provider.threads(in: archive, limit: 300) else { continue }
            history += threads.map { Self.tag($0, account: account.id) }
        }
        newsletterHistory = history.filter { thread in thread.messages.contains { InboxSplit.classify($0) == .newsletters } }
    }

    /// Leaves the list the way it asks, clears its issues from the inbox, and stops suggesting it.
    public func unsubscribe(from sender: NewsletterSender) {
        unsubscribe(sender.latest)
        settle(sender)
        let fromList = inboxThreads(nil).filter { thread in
            thread.messages.contains { $0.from.address.caseInsensitiveCompare(sender.address) == .orderedSame }
        }
        if !fromList.isEmpty { Task { await apply(.done, to: fromList, announce: false) } }
    }

    /// Keeps the list and stops suggesting it.
    public func keep(_ sender: NewsletterSender) {
        settle(sender)
        notice = Notice(text: String(localized: "You'll keep getting \(sender.name)"))
    }

    func noteNewsletterOpened(_ thread: MailThread) {
        let issues = thread.messages.filter { InboxSplit.classify($0) == .newsletters }
        guard !issues.isEmpty else { return }
        loadNewsletterStateIfNeeded()
        let before = newsletterState.opened.count
        newsletterState.opened.formUnion(issues.map(NewsletterReport.identity))
        if newsletterState.opened.count != before { saveNewsletterState() }
    }

    private func settle(_ sender: NewsletterSender) {
        loadNewsletterStateIfNeeded()
        newsletterState.settled.insert(sender.id)
        saveNewsletterState()
    }

    private var newsletterFile: JSONFile<NewsletterState> {
        JSONFile(url: environment.folder.appending(path: "newsletters.json"))
    }

    func loadNewsletterStateIfNeeded() {
        guard !newsletterStateLoaded else { return }
        newsletterStateLoaded = true
        if let saved = newsletterFile.load() { newsletterState = saved }
    }

    private func saveNewsletterState() {
        newsletterFile.save(newsletterState)
    }
}
