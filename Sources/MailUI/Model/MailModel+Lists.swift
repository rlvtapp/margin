import Foundation
import MailCore

/// The inbox lists: what the model keeps per mailbox (`InboxShelf`), the part of a list that's
/// on screen, and the counts. None of it walks every conversation when one of them changes.
extension MailModel {
    /// How many rows a list starts with, and how many more each time its end comes on screen.
    nonisolated public static let listPage = 200

    // MARK: The mail itself

    /// Every mailbox's inbox, newest first. Reading it follows every change to the mail;
    /// setting it replaces the mailboxes whose list is a different one.
    public internal(set) var inboxes: [UUID: [MailThread]] {
        get {
            _ = inboxRevision
            return shelves.mapValues(\.threads)
        }
        set {
            var changed = false
            for id in Set(shelves.keys).union(newValue.keys) {
                guard let new = newValue[id] else {
                    shelves[id] = nil
                    changed = true
                    continue
                }
                // The same array that was handed out: nothing to do for this mailbox.
                if let old = shelves[id], Self.isSameStorage(old.threads, new) { continue }
                shelves[id] = InboxShelf(new)
                changed = true
            }
            if changed { inboxesChanged(order: true) }
        }
    }

    private static func isSameStorage(_ one: [MailThread], _ other: [MailThread]) -> Bool {
        guard one.count == other.count else { return false }
        if one.isEmpty { return true }
        return one.withUnsafeBufferPointer { first in other.withUnsafeBufferPointer { first.baseAddress == $0.baseAddress } }
    }

    /// Tells everything that shows mail that it changed. `order`: conversations came, went or
    /// changed places; false when only read marks and stars did.
    func inboxesChanged(order: Bool) {
        if order { inboxOrder &+= 1 }
        inboxRevision &+= 1
    }

    /// Replaces one mailbox's inbox.
    func setInbox(_ shelf: InboxShelf, for account: UUID) {
        shelves[account] = shelf
        inboxesChanged(order: true)
    }

    func setInbox(_ threads: [MailThread], for account: UUID) {
        setInbox(InboxShelf(threads), for: account)
    }

    /// Changes these conversations where they are (a read mark, a star, a new message), without
    /// looking at any other conversation.
    func changeInInboxes(_ threads: [MailThread], _ change: (MailThread) -> MailThread) {
        var touched = false, moved = false
        for thread in threads {
            guard let account = thread.accountID ?? Self.accountID(inThreadID: thread.id),
                  let index = shelves[account]?.position(of: thread) else { continue }
            let current = shelves[account]!.threads[index]
            let next = change(current)
            guard next != current else { continue }
            if shelves[account]!.replace(at: index, with: next) { moved = true }
            touched = true
        }
        if touched { inboxesChanged(order: moved) }
    }

    /// Takes these conversations out of the inboxes, and says which of them were there.
    @discardableResult
    func removeFromInboxes(_ threads: [MailThread]) -> [MailThread] {
        var removed: [MailThread] = []
        for (account, group) in Dictionary(grouping: threads, by: { $0.accountID ?? Self.accountID(inThreadID: $0.id) }) {
            guard let account, let shelf = shelves[account] else { continue }
            let positions = group.compactMap { shelf.position(of: $0) }
            guard !positions.isEmpty else { continue }
            removed += positions.map { shelf.threads[$0] }
            shelves[account]!.remove(at: positions)
        }
        if !removed.isEmpty { inboxesChanged(order: true) }
        return removed
    }

    /// Puts conversations back into their mailboxes' inboxes, each where its date says (Undo).
    func restoreToInboxes(_ threads: [MailThread]) {
        var touched = false
        for (account, group) in Dictionary(grouping: threads, by: { $0.accountID ?? Self.accountID(inThreadID: $0.id) }) {
            guard let account else { continue }
            shelves[account, default: InboxShelf()].add(group)
            touched = true
        }
        if touched { inboxesChanged(order: true) }
    }

    /// Takes conversations out by id alone, from whichever mailbox holds them.
    func removeFromInboxes(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var touched = false
        for (account, shelf) in shelves {
            let positions = shelf.threads.indices.filter { ids.contains(shelf.threads[$0].id) }
            guard !positions.isEmpty else { continue }
            shelves[account]!.remove(at: positions)
            touched = true
        }
        if touched { inboxesChanged(order: true) }
    }

    /// The account a model-wide thread id belongs to (`MailModel.tag` puts it in front).
    nonisolated static func accountID(inThreadID id: String) -> UUID? {
        guard id.utf8.count > 37 else { return nil }
        let end = id.index(id.startIndex, offsetBy: 36)
        guard id[end] == "|" else { return nil }
        return UUID(uuidString: String(id[..<end]))
    }

    /// The conversation in an inbox with this id, if it's there.
    func inboxThread(_ id: String, date: Date? = nil) -> MailThread? {
        if let account = Self.accountID(inThreadID: id), let shelf = shelves[account] {
            if let date, let index = shelf.position(of: id, date: date) { return shelf.threads[index] }
            return shelf.position(of: id).map { shelf.threads[$0] }
        }
        for shelf in shelves.values {
            if let index = shelf.position(of: id) { return shelf.threads[index] }
        }
        return nil
    }

    public func inboxThreads(_ accountID: UUID?) -> [MailThread] {
        _ = inboxRevision
        if let accountID { return shelves[accountID]?.threads ?? [] }
        // Every mailbox merged, newest first: worked out once and kept until a mailbox changes
        // (see `Derived`). Nothing on screen asks for it on every step; the lists read the
        // newest few straight from the shelves.
        return derived.merged.value {
            _ = inboxRevision
            return ShelfReader(shelves: accounts.map { shelves[$0.id] ?? InboxShelf() }).merged()
        }
    }

    /// The newest few conversations across every mailbox, without merging them all.
    func newestInInboxes(_ count: Int) -> [MailThread] {
        _ = inboxRevision
        return ShelfReader(shelves: accounts.map { shelves[$0.id] ?? InboxShelf() }).newest(count)
    }

    /// One mailbox's inbox, or All Inboxes: every mailbox not left out of it.
    func allInboxesThreads(_ accountID: UUID?) -> [MailThread] {
        guard accountID == nil else { return inboxThreads(accountID) }
        _ = inboxRevision
        return derived.allInboxes.value {
            _ = inboxRevision
            return ShelfReader(shelves: allInboxesAccounts.map { shelves[$0] ?? InboxShelf() }).merged()
        }
    }

    /// The mailboxes All Inboxes shows: the workspace in view, without those left out of it.
    var allInboxesAccounts: [UUID] {
        workspaceAccounts.filter { $0.inAllInboxes != false }.map(\.id)
    }

    /// The shelves a place reads: one mailbox's, or those of All Inboxes.
    func inboxReader(_ accountID: UUID?) -> ShelfReader {
        _ = inboxRevision
        if let accountID { return ShelfReader(shelves: [shelves[accountID] ?? InboxShelf()]) }
        return ShelfReader(shelves: allInboxesAccounts.map { shelves[$0] ?? InboxShelf() })
    }

    public func unreadCount(account: UUID?, split: InboxSplit? = nil) -> Int {
        inboxReader(account).shelves.reduce(0) { $0 + $1.unreadCount(split: split) }
    }

    // MARK: The list on screen

    /// The rows of the list: the first `listWindow` conversations of the place. More are shown
    /// as the end of the list comes on screen (`listReachedEnd`).
    public var visibleThreads: [MailThread] { listNow.rows }

    /// How many conversations the place holds in all (of the mail that's loaded), and how many
    /// of them are unread: what the list's header says.
    public var listCount: Int { listNow.count }
    public var listUnreadCount: Int { listNow.unread }

    /// Whether the place holds more rows than the list shows.
    public var listHasMoreRows: Bool { listNow.rows.count < listNow.count }

    var listNow: ListWindow {
        derived.visible.value { computeList(limit: max(listWindow, 1)) }
    }

    /// Every conversation of the place, not only the rows shown so far: for Select All and for
    /// acting on a selection. Worked out when asked, which is when someone presses a key.
    var wholeList: [MailThread] { computeList(limit: .max).rows }

    /// What the list shows now, and how much there is.
    struct ListWindow {
        var rows: [MailThread] = []
        var count = 0
        var unread = 0
    }

    private func computeList(limit: Int) -> ListWindow {
        switch place {
        case .scheduled, .subscriptions, .calendar:
            return ListWindow()
        case .mailbox, .combined, .waiting, .search:
            var source = folder
            if quickFilters.contains(.unread) { source.removeAll { !$0.isUnread } }
            if quickFilters.contains(.starred) { source.removeAll { !$0.isStarred } }
            if quickFilters.contains(.attachments) { source.removeAll { !$0.hasAttachments } }
            // Search results were already matched, operators included; filtering again by the
            // words would drop server results whose bodies aren't downloaded yet.
            if case .search = place {} else {
                let query = SearchQuery(searchText)
                if !query.isEmpty { source = source.filter(query.matches) }
            }
            return ListWindow(rows: Array(source.prefix(limit)), count: source.count, unread: source.filter(\.isUnread).count)
        case .snoozed(let accountID):
            var source = snoozedConversations(accountID)
            if quickFilters.contains(.unread) { source.removeAll { !$0.isUnread } }
            if quickFilters.contains(.starred) { source.removeAll { !$0.isStarred } }
            if quickFilters.contains(.attachments) { source.removeAll { !$0.hasAttachments } }
            let query = SearchQuery(searchText)
            if !query.isEmpty { source = source.filter(query.matches) }
            return ListWindow(rows: Array(source.prefix(limit)), count: source.count, unread: source.filter(\.isUnread).count)
        case .inbox, .starred, .home, .vips:
            return inboxList(limit: limit)
        }
    }

    /// What's kept about the place between changes to which conversations are in the inboxes:
    /// read marks and stars don't touch it.
    struct PlaceIndex {
        var accounts: [UUID] = []
        /// How far down each mailbox is read (see `ShelfReader.rows`).
        var rows: [Int] = []
        /// Every conversation of the place, when deciding that takes a look at each one (a
        /// search, snoozes, a group); nil when the facts alone say it.
        var spots: [ThreadSpot]?
        /// The pinned ones among them.
        var pinned: [ThreadSpot] = []
    }

    private func computePlaceIndex() -> PlaceIndex {
        _ = inboxOrder
        let accountID: UUID? = if case .home = place { nil } else { place.accountID }
        let ids = accountID.map { [$0] } ?? allInboxesAccounts
        // Only a list that can fetch older mail stops where the first mailbox runs out; one
        // that picks conversations out shows everything that's loaded.
        let fetches = fetchesOlderMail
        let reader = ShelfReader(shelves: ids.map { shelves[$0] ?? InboxShelf() }, open: ids.map { fetches && !reachedOldest.contains($0) })
        var index = PlaceIndex(accounts: ids, rows: reader.rows)

        var split = InboxShelf.Filter()
        // The tabs are Important (people) and Other (updates and newsletters together).
        if case .inbox(_, let part?) = place { split.require(tabOf: part) }
        let now = Date()
        let snoozed = KeyLookup(snoozes.lazy.filter { $0.value > now }.map(\.key))
        var test: ((MailThread) -> Bool)?
        switch place {
        case .snoozed:
            test = { snoozed.contains($0) }
        case .vips:
            let vips = vipAddresses
            test = vips.isEmpty ? { _ in false } : { thread in
                !snoozed.contains(thread) && thread.messages.contains { vips.contains($0.from.address.lowercased()) }
            }
        case .home(let group?):
            let labelled = KeyLookup(labelStore.labelsByThread.lazy.filter { entry in
                entry.value.contains { $0.caseInsensitiveCompare(group) == .orderedSame }
            }.map(\.key))
            test = { labelled.contains($0) && !snoozed.contains($0) }
        default:
            if !snoozed.isEmpty { test = { !snoozed.contains($0) } }
        }
        let query = SearchQuery(searchText)
        if !query.isEmpty {
            // "is:unread" and "is:starred" follow read marks and stars, so this does too.
            if query.isUnread != nil || query.isStarred != nil { _ = inboxRevision }
            let before = test
            test = { (before?($0) ?? true) && query.matches($0) }
        }
        if let test { index.spots = reader.spots(filter: split, passes: test) }
        if place.isInbox {
            let pins = KeyLookup(pinnedKeys)
            if !pins.isEmpty {
                // Wherever they are: a pinned conversation leads the list even when it's
                // older than the point the mailboxes are read down to together.
                index.pinned = ShelfReader(shelves: reader.shelves).spots(filter: split) { pins.contains($0) && (test?($0) ?? true) }
            }
        }
        return index
    }

    private func inboxList(limit: Int) -> ListWindow {
        _ = inboxRevision
        let index = derived.placeIndex.value { computePlaceIndex() }
        let reader = ShelfReader(shelves: index.accounts.map { shelves[$0] ?? InboxShelf() }, rows: index.rows)
        var filter = InboxShelf.Filter()
        if case .inbox(_, let part?) = place { filter.require(tabOf: part) }
        if case .starred = place { filter.require(InboxShelf.Facts.starred) }
        if quickFilters.contains(.unread) { filter.require(InboxShelf.Facts.unread) }
        if quickFilters.contains(.starred) { filter.require(InboxShelf.Facts.starred) }
        if quickFilters.contains(.attachments) { filter.require(InboxShelf.Facts.attachment) }

        var list = ListWindow()
        // Pinned conversations first, each part keeping its order.
        let pinned = index.pinned.filter { filter.passes(reader.facts(at: $0)) }
        list.rows = pinned.prefix(limit).map { reader[$0] }
        let pinnedIDs = Set(list.rows.map(\.id))
        if let spots = index.spots {
            for spot in spots {
                let facts = reader.facts(at: spot)
                guard filter.passes(facts) else { continue }
                list.count += 1
                if facts & InboxShelf.Facts.unread != 0 { list.unread += 1 }
                guard list.rows.count < limit else { continue }
                let thread = reader[spot]
                if pinnedIDs.isEmpty || !pinnedIDs.contains(thread.id) { list.rows.append(thread) }
            }
        } else {
            (list.count, list.unread) = reader.tally(filter)
            let room = limit - list.rows.count
            if room > 0 {
                list.rows += reader.newest(room, filter: filter, passes: pinnedIDs.isEmpty ? nil : { !pinnedIDs.contains($0.id) })
            }
        }
        return list
    }

    /// The end of the list came on screen: shows the next rows of what's loaded, and when
    /// that's all of it, asks for older mail.
    public func listReachedEnd() {
        if listHasMoreRows {
            listWindow += Self.listPage
        } else {
            loadOlderMail()
        }
    }

    /// Whether the list can grow at its end: more rows of what's loaded, or older mail that can
    /// be fetched. The lists show a last row that asks for it while this holds.
    public var canShowMore: Bool {
        if listHasMoreRows { return true }
        _ = inboxOrder
        guard fetchesOlderMail else { return false }
        switch place {
        case .mailbox, .combined: return !folder.isEmpty && !reachedOldest.contains(nil)
        default: return !olderMailTargets.isEmpty
        }
    }

    /// Whether reaching the end of this list asks the servers for older mail: an inbox or a
    /// folder shown whole. A list that picks a few conversations out (starred, snoozed, a
    /// group, a filter, a search in the list) doesn't: its end is on screen straight away, and
    /// it would fetch page after page without showing anything new.
    private var fetchesOlderMail: Bool {
        guard quickFilters.isEmpty, searchText.isEmpty else { return false }
        switch place {
        case .inbox, .home(group: nil), .mailbox, .combined: return true
        default: return false
        }
    }

    /// The mailboxes of the place that the list is waiting on for older mail: the ones whose
    /// loaded mail ends first.
    private var olderMailTargets: [UUID] {
        let accountID: UUID? = if case .home = place { nil } else { place.accountID }
        let open = (accountID.map { [$0] } ?? allInboxesAccounts).filter { !reachedOldest.contains($0) }
        let floors = open.map { shelves[$0]?.dates.last ?? .infinity }
        guard let floor = floors.max(), let first = zip(open, floors).first(where: { $0.1 == floor })?.0 else { return [] }
        // The mailbox whose mail ends first, and with it every mailbox that would be the next
        // to end before that one's new page is used up: about as far down as its last page
        // reached. Mailboxes that get mail at the same pace are fetched together, in one go.
        var reach = floor
        if let dates = shelves[first]?.dates, let last = dates.last {
            reach = last - (dates[max(0, dates.count - Self.listPage)] - last)
        }
        return zip(open, floors).filter { $0.1 >= reach }.map(\.0)
    }

    /// Fetches the next page of older mail for the list: saved mail first, so it shows at once,
    /// then the server's own answer.
    func loadOlderMail() {
        guard !isLoadingOlder, fetchesOlderMail else { return }
        let place = place
        switch place {
        case .mailbox, .combined:
            guard !folder.isEmpty, !reachedOldest.contains(nil) else { return }
            isLoadingOlder = true
            folderLimit += Self.listPage
            Task {
                let before = folder.count
                await loadFolder(for: place)
                // Nothing more came: don't keep asking.
                if self.place == place, folder.count <= before { reachedOldest.insert(nil); inboxesChanged(order: true) }
                showOlderMail(in: place)
                isLoadingOlder = false
            }
        case .inbox, .home:
            let targets = olderMailTargets
            guard !targets.isEmpty else { return }
            isLoadingOlder = true
            Task {
                await loadOlderInboxes(targets)
                showOlderMail(in: place)
                isLoadingOlder = false
            }
        default:
            return
        }
    }

    /// Older mail that was asked for at the end of the list has come: its first rows are shown
    /// straight away, without waiting for the last row to come on screen a second time.
    private func showOlderMail(in place: Place) {
        if self.place == place, listHasMoreRows { listWindow += Self.listPage }
    }

    /// The next page of older inbox mail for these mailboxes. Each step takes in every
    /// mailbox's answer together, so the list is drawn again once per step, not once per mailbox.
    func loadOlderInboxes(_ ids: [UUID]) async {
        let cache = environment.cache
        var jobs: [(id: UUID, provider: (any MailProvider)?, limit: Int, inbox: Mailbox?, oldest: Date?, had: Int)] = []
        for id in ids {
            guard let account = account(id) else { continue }
            let limit = inboxLimit(id) + Self.listPage
            inboxLimits[id] = limit
            jobs.append((id, try? provider(for: account), limit, mailboxes[id]?.first { $0.role == .inbox },
                         shelves[id]?.threads.last?.date, shelves[id]?.count ?? 0))
        }
        let cachedRevision = mutationRevision
        // What this device has of it shows at once.
        let saved = await withTaskGroup(of: (UUID, [MailThread]).self) { group in
            for job in jobs {
                guard let inbox = job.inbox, let oldest = job.oldest else { continue }
                group.addTask {
                    let page = await cache.threads(account: job.id, mailbox: inbox.id, limit: MailModel.listPage, before: oldest, bodies: false)
                    return (job.id, page.map { Self.tag($0, account: job.id) })
                }
            }
            var all: [(UUID, [MailThread])] = []
            for await one in group where !one.1.isEmpty { all.append(one) }
            return all
        }
        // The list may have been left while this was read: then its older mail isn't wanted.
        func stillWanted(_ id: UUID) -> Bool { jobs.contains { $0.id == id && inboxLimits[id] == $0.limit } }
        let pages = saved.filter { entry in
            stillWanted(entry.0) && cachedRevision == mutationRevision && committingChanges[entry.0] == nil
                && pendingChange?.threads.contains(where: { $0.accountID == entry.0 }) != true
        }
        if !pages.isEmpty {
            for (id, page) in pages { shelves[id, default: InboxShelf()].add(page) }
            inboxesChanged(order: true)
        }
        // Then the servers' own answers.
        var previous: [UUID: [MailThread]] = [:]
        for job in jobs { previous[job.id] = shelves[job.id]?.threads }
        let revision = mutationRevision
        let results = await withTaskGroup(of: LoadedAccount?.self) { group in
            for job in jobs {
                guard let provider = job.provider else { continue }
                let before = previous[job.id]
                group.addTask { await Self.load(job.id, from: provider, limit: job.limit, previous: before, mutationRevision: revision) }
            }
            var all: [LoadedAccount] = []
            for await one in group { if let one { all.append(one) } }
            return all
        }
        var changed = false
        var saves: [(LoadedAccount, (changed: Bool, folders: Bool, mail: Bool))] = []
        for result in results where stillWanted(result.id) {
            let taken = take(result)
            changed = changed || taken.changed
            saves.append((result, taken))
        }
        // A server that couldn't be asked, with nothing more saved here: that's all there is
        // for now, and the other mailboxes in the list aren't held back by this one.
        let answered = Set(results.filter { $0.error == nil }.map(\.id))
        for job in jobs where stillWanted(job.id) && !answered.contains(job.id) && (shelves[job.id]?.count ?? 0) <= job.had {
            reachedOldest.insert(job.id)
            changed = true
        }
        if changed { inboxesChanged(order: true) }
        for (result, taken) in saves { await save(result, taken) }
    }

    /// Lets go of older mail that was scrolled to: every mailbox goes back to its newest page.
    func forgetOlderMail() {
        if listWindow != Self.listPage { listWindow = Self.listPage }
        folderLimit = Self.listPage
        reachedOldest.remove(nil)
        guard !inboxLimits.isEmpty else { return }
        var trimmed = false
        for (id, limit) in inboxLimits where limit > Self.listPage {
            guard let shelf = shelves[id], shelf.count > Self.listPage else { continue }
            shelves[id]!.trim(to: Self.listPage)
            reachedOldest.remove(id)
            trimmed = true
        }
        inboxLimits = [:]
        if trimmed { inboxesChanged(order: true) }
    }

    public var selectedThread: MailThread? {
        derived.selected.value {
            guard let id = selectedThreadID else { return nil }
            _ = inboxRevision
            if let shown = visibleThreads.first(where: { $0.id == id }) {
                selectedDate = (id, shown.date)
                return shown
            }
            // Not in the rows on screen (opened from a notification, or it just left the list):
            // where it was last seen says where to look, without going through the mailbox.
            if let seen = selectedDate, seen.id == id, let thread = inboxThread(id, date: seen.date) { return thread }
            let found = folder.first { $0.id == id } ?? inboxThread(id) ?? newsletterHistory.first { $0.id == id }
            if let found { selectedDate = (id, found.date) }
            return found
        }
    }
}

/// Conversations by the key their labels, pins and snoozes are kept under (`LabelStore.key`),
/// asked without building that key for each conversation.
struct KeyLookup: Sendable {
    private var byAccount: [UUID?: Set<String>] = [:]

    init<Keys: Sequence>(_ keys: Keys) where Keys.Element == String {
        for key in keys {
            guard let bar = key.firstIndex(of: "|") else { continue }
            byAccount[UUID(uuidString: String(key[..<bar])), default: []].insert(String(key[key.index(after: bar)...]))
        }
    }

    var isEmpty: Bool { byAccount.isEmpty }

    func contains(_ thread: MailThread) -> Bool {
        guard !byAccount.isEmpty, let keys = byAccount[thread.accountID] else { return false }
        return keys.contains(thread.messages.first?.messageID ?? thread.id)
    }
}
