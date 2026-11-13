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
        // The sidebar asks on every redraw (for the Subscriptions count); it's kept until the
        // mail or what's been opened changes.
        derived.newsletters.value {
            // Grouping every conversation by list is the expensive half and depends only on
            // which mail there is; opening a newsletter changes just the counts.
            NewsletterReport.senders(from: mailingListsNow, openedIDs: newsletterState.opened)
        }
    }

    /// Up to this many conversations, mailing lists are worked out on the spot; with more, in
    /// the background, and the lists from before stay until the new ones are ready.
    static let mailingListsInline = 5_000

    /// The mailing lists in the inboxes and the archive. They follow which mail there is, not
    /// read marks: an issue counts as opened once it's opened here, or when the next refresh
    /// brings its read mark. Going through every conversation is the one job here that can't
    /// be made small, so with a lot of mail it's done away from the main thread, a moment
    /// after the mail last changed.
    private var mailingListsNow: [NewsletterReport.MailingList] {
        let wanted = MailingListsKey(order: inboxOrder, history: newsletterHistory.count, newest: newsletterHistory.first?.id)
        if wanted == mailingListsKey { return mailingLists }
        let shelfList = accounts.map { shelves[$0.id] ?? InboxShelf() }
        let history = newsletterHistory
        if shelfList.reduce(0, { $0 + $1.count }) <= Self.mailingListsInline {
            let lists = NewsletterReport.lists(in: ShelfReader(shelves: shelfList).merged() + history)
            mailingListsWork?.cancel()
            mailingListsKey = wanted
            mailingListsStore = lists
            return lists
        }
        if mailingListsWanted != wanted {
            mailingListsWanted = wanted
            mailingListsWork?.cancel()
            mailingListsWork = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let lists = await Task.detached(priority: .utility) {
                    NewsletterReport.lists(in: shelfList.flatMap(\.threads) + history)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.mailingListsKey = wanted
                self.mailingListsStore = lists
                self.mailingListsRevision &+= 1
            }
        }
        return mailingLists
    }

    private var mailingLists: [NewsletterReport.MailingList] {
        _ = mailingListsRevision
        return mailingListsStore
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

    /// Written a moment after the last change, off the main thread: opening newsletters one
    /// after another used to write the file on every one, while the mail was being drawn.
    private func saveNewsletterState() {
        let file = newsletterFile
        derived.newsletterSave?.cancel()
        derived.newsletterSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let state = self?.newsletterState else { return }
            await Task.detached(priority: .utility) { file.save(state) }.value
        }
    }
}
