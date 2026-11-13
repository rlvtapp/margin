import Foundation
import MailCore

/// Sorting the inbox into groups (Bills to Pay, Travel, Customers…), each a label, and Home:
/// a greeting, what not to forget today, and a tab per group.
extension MailModel {
    /// The groups mail is sorted into, in the person's order.
    public var emailGroups: [EmailGroup] {
        get {
            // Read on every row (Home's notes, sorting); decoded only when the groups change.
            if let cached = emailGroupsCache, cached.revision == sortingRevision { return cached.groups }
            let groups: [EmailGroup]
            if let data = environment.defaults.data(forKey: "emailGroups"), let saved = try? JSONDecoder().decode([EmailGroup].self, from: data) {
                groups = saved
            } else {
                groups = EmailGroup.starters
            }
            emailGroupsCache = (sortingRevision, groups)
            return groups
        }
        set {
            environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "emailGroups")
            sortingRevision += 1
        }
    }

    /// Sorts new mail into groups as it arrives.
    public var sortsNewMail: Bool {
        get { _ = sortingRevision; return environment.defaults.bool(forKey: "sortsNewMail") }
        set { environment.defaults.set(newValue, forKey: "sortsNewMail"); sortingRevision += 1 }
    }

    /// The group a conversation is in, if any.
    public func group(of thread: MailThread) -> EmailGroup? {
        let labels = Set(labels(for: thread).map { $0.lowercased() })
        return emailGroups.first { labels.contains($0.name.lowercased()) }
    }

    /// Conversations already looked at, whether or not a group fit, with the newest message
    /// seen then. Kept on disk and synced through iCloud, so sorting resumes where it stopped,
    /// on this device or another.
    var sortingChecked: [String: String] {
        get {
            if let sortingCheckedCache { return sortingCheckedCache }
            let loaded = environment.isPreview ? [:] : (sortingCheckedFile.load() ?? [:])
            sortingCheckedCache = loaded
            return loaded
        }
        set {
            sortingCheckedCache = newValue
            if !environment.isPreview { sortingCheckedFile.save(newValue) }
        }
    }

    var sortingCheckedFile: JSONFile<[String: String]> {
        JSONFile(url: environment.folder.appending(path: "sorting-checked.json"))
    }

    /// The newest message of a conversation, as sorting remembers it.
    static func sortingMark(_ thread: MailThread) -> String { thread.latest.messageID ?? thread.latest.id }

    /// Marks a conversation taken out of its group by hand ("Not in a group"): sorting leaves it
    /// alone, even when Sort Now looks again at the rest.
    static let keptOut = "out|"
    /// Marks a conversation Sort Now looked at a second time without finding a group: it isn't
    /// looked at again until something new arrives in it.
    static let lookedAgain = "again|"

    /// Whether sorting still has to look at a conversation: not in a group, and new since it last
    /// looked (or never looked at).
    func needsSorting(_ thread: MailThread) -> Bool {
        guard group(of: thread) == nil else { return false }
        guard let seen = sortingChecked[LabelStore.key(for: thread)] else { return true }
        return Self.plainMark(seen) != Self.sortingMark(thread)
    }

    /// Not in a group, and not taken out of one by hand: what Sort Now looks at again when
    /// there's nothing new.
    func canSortAgain(_ thread: MailThread) -> Bool {
        guard group(of: thread) == nil else { return false }
        let seen = sortingChecked[LabelStore.key(for: thread)] ?? ""
        return !seen.hasPrefix(Self.keptOut) && !seen.hasPrefix(Self.lookedAgain)
    }

    /// A remembered mark without what it says about how it was left.
    static func plainMark(_ seen: String) -> String {
        for prefix in [keptOut, lookedAgain] where seen.hasPrefix(prefix) { return String(seen.dropFirst(prefix.count)) }
        return seen
    }

    /// Sorts every inbox conversation not in a group yet; with nothing new, it looks again at
    /// the ones nothing fitted (not at ones taken out of a group by hand). Uses the assistant when it's on;
    /// otherwise only clear cases are sorted (invoices, receipts, travel, newsletters…). It can be
    /// stopped at any point and picks up where it left off: each batch is remembered as soon as
    /// it's been looked at, sorted or not.
    ///
    /// The assistant gets a batch of conversations per request, from what the list shows, as an
    /// AI app sorting over MCP does; a hosted model gets a few batches at once.
    public func sortNow() {
        guard sortingTask == nil, agentTask == nil else { return }
        let groups = emailGroups
        var todo = inboxThreads(nil).filter(needsSorting)
        // Nothing new: asked anyway, so look once more at what nothing fitted last time.
        let again = todo.isEmpty
        if again { todo = inboxThreads(nil).filter(canSortAgain) }
        guard !todo.isEmpty else {
            notice = Notice(text: String(localized: "Nothing new to sort"))
            return
        }
        let intelligence = sortIntelligence
        sortingProgress = (0, todo.count)
        sortingTask = Task { [weak self] in
            guard let self else { return }
            let size = intelligence?.sortingBatchSize ?? 50
            let batches = stride(from: 0, to: todo.count, by: size).map { Array(todo[$0..<min($0 + size, todo.count)]) }
            let lanes = intelligence?.sortsInParallel == true ? 3 : 1
            var sorted = 0
            var looked = 0
            for start in stride(from: 0, to: batches.count, by: lanes) {
                guard !Task.isCancelled else { break }
                let wave = Array(batches[start..<min(start + lanes, batches.count)])
                let picked = await withTaskGroup(of: [String: EmailGroup].self) { group in
                    for batch in wave { group.addTask { await Self.pickGroups(for: batch, among: groups, using: intelligence) } }
                    var all: [String: EmailGroup] = [:]
                    for await found in group { all.merge(found) { first, _ in first } }
                    return all
                }
                // Stopped while the assistant was answering: those answers still count.
                sorted += self.file(wave.flatMap(\.self), into: picked, prefix: again ? Self.lookedAgain : "")
                looked += wave.reduce(0) { $0 + $1.count }
                if self.sortingTask != nil { self.sortingProgress = (looked, todo.count) }
            }
            let stopped = looked < todo.count
            self.sortingTask = nil
            self.sortingProgress = nil
            self.notice = Notice(text: stopped
                ? String(localized: "Sorting paused · \(todo.count - looked) left")
                : sorted == 0 ? String(localized: "None of them fit a group")
                : sorted == 1 ? String(localized: "Sorted 1 conversation") : String(localized: "Sorted \(sorted) conversations"))
            // Other devices pick up the sorting, and don't redo it.
            Task { await self.syncNow() }
        }
    }

    /// Puts each conversation in the group picked for it, and remembers all of them as looked
    /// at, with one write. Returns how many went into a group.
    private func file(_ threads: [MailThread], into picked: [String: EmailGroup], prefix: String = "") -> Int {
        var checked = sortingChecked
        var sorted = 0
        for thread in threads {
            if let group = picked[thread.id] {
                addLabel(group.name, to: thread)
                sorted += 1
            }
            checked[LabelStore.key(for: thread)] = (picked[thread.id] == nil ? prefix : "") + Self.sortingMark(thread)
        }
        sortingChecked = checked
        return sorted
    }

    /// Stops after the batch being looked at; Sort Now carries on from there.
    public func stopSorting() {
        sortingTask?.cancel()
        sortingProgress = nil
        // "Sort my mail" with the assistant shows the same progress, and stops the same way.
        if agentRun?.kind == .sort { stopAgent() }
    }

    public var isSorting: Bool { sortingTask != nil || (agentRun?.kind == .sort && agentRun?.isWorking == true) }

    /// Puts a conversation in a group by hand (or in none), out of any other group; sorting
    /// leaves it alone afterwards.
    public func move(_ thread: MailThread, toGroup group: EmailGroup?) {
        if let current = self.group(of: thread), current.name.caseInsensitiveCompare(group?.name ?? "") != .orderedSame {
            removeLabel(current.name, from: thread)
        }
        if let group { addLabel(group.name, to: thread) }
        sortingChecked[LabelStore.key(for: thread)] = (group == nil ? Self.keptOut : "") + Self.sortingMark(thread)
    }

    /// The group for each conversation of a batch, by id: the assistant's pick, else the rules'.
    /// A batch the assistant can't answer (a refusal, too long) is split in half and tried
    /// again, so one odd message doesn't leave the rest to the rules.
    nonisolated static func pickGroups(for batch: [MailThread], among groups: [EmailGroup],
                                       using intelligence: MailIntelligence?) async -> [String: EmailGroup] {
        var picked: [String: EmailGroup] = [:]
        if let intelligence, !batch.isEmpty {
            do {
                picked = try await intelligence.classify(batch: batch, groups: groups)
            } catch where batch.count > 1 {
                let half = batch.count / 2
                async let first = pickGroups(for: Array(batch[..<half]), among: groups, using: intelligence)
                async let second = pickGroups(for: Array(batch[half...]), among: groups, using: intelligence)
                return await first.merging(second) { mine, _ in mine }
            } catch {}
        }
        for thread in batch where picked[thread.id] == nil {
            picked[thread.id] = EmailSorter.ruleGroup(for: thread, groups: groups)
        }
        return picked
    }

    /// New mail goes into its group as it arrives, when that's on.
    func sortNewMail(_ threads: [MailThread]) async {
        guard sortsNewMail, sortingTask == nil, agentTask == nil else { return }
        let todo = Array(threads.prefix(20).filter(needsSorting))
        guard !todo.isEmpty else { return }
        let picked = await Self.pickGroups(for: todo, among: emailGroups, using: sortIntelligence)
        // Sort Now may have started, or the person sorted some by hand, in the meantime.
        _ = file(todo.filter(needsSorting), into: picked)
    }

    // MARK: Home

    /// "Good morning, Noor".
    public var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = EmailAddress.firstName(of: accounts.first?.address ?? EmailAddress(name: nil, address: ""))
        let hello = switch hour {
        case 5..<12: String(localized: "Good morning")
        case 12..<18: String(localized: "Good afternoon")
        default: String(localized: "Good evening")
        }
        return name.isEmpty || name.contains("@") ? hello : "\(hello), \(name)"
    }

    /// Mail that arrived today.
    public var todaysMailCount: Int {
        _ = inboxOrder
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        let end = (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()).timeIntervalSinceReferenceDate
        return allInboxesAccounts.reduce(0) { sum, id in
            guard let shelf = shelves[id] else { return sum }
            return sum + shelf.countNotOlder(than: start) - shelf.countNotOlder(than: end)
        }
    }

    /// Bills that haven't been opened.
    public var unopenedBills: [MailThread] {
        guard let bills = emailGroups.first(where: { $0.name == EmailGroup.starters[3].name }) else { return [] }
        // Only ones that ask you to pay: invoices taken automatically and receipts ask nothing.
        return inboxThreads(labelled: bills.name)
            .filter { $0.isUnread && MailNotice.asksForPayment(subject: $0.latest.subject, text: latestText(of: $0)) }
            .sorted { $0.date > $1.date }
    }
}
