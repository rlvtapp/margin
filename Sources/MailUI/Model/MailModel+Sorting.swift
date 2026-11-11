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

    /// Whether sorting still has to look at a conversation: not in a group, and new since it last
    /// looked (or never looked at).
    func needsSorting(_ thread: MailThread) -> Bool {
        group(of: thread) == nil && sortingChecked[LabelStore.key(for: thread)] != Self.sortingMark(thread)
    }

    /// Sorts every inbox conversation not in a group yet. Uses the assistant when it's on;
    /// otherwise only clear cases are sorted (invoices, receipts, travel, newsletters…). It can be
    /// stopped at any point and picks up where it left off: each conversation is remembered as
    /// soon as it's been looked at, sorted or not.
    public func sortNow() {
        guard sortingTask == nil, agentTask == nil else { return }
        let groups = emailGroups
        let todo = inboxThreads(nil).filter(needsSorting)
        sortingProgress = (0, todo.count)
        sortingTask = Task { [weak self] in
            guard let self else { return }
            var sorted = 0
            var looked = 0
            for (index, thread) in todo.enumerated() {
                guard !Task.isCancelled else { break }
                let group = await self.pickGroup(for: thread, among: groups)
                // Stopped while the assistant was answering: that answer still counts.
                if let group {
                    self.addLabel(group.name, to: thread)
                    sorted += 1
                }
                self.sortingChecked[LabelStore.key(for: thread)] = Self.sortingMark(thread)
                looked += 1
                if self.sortingTask != nil { self.sortingProgress = (index + 1, todo.count) }
            }
            let stopped = looked < todo.count
            self.sortingTask = nil
            self.sortingProgress = nil
            self.notice = Notice(text: stopped
                ? String(localized: "Sorting paused · \(todo.count - looked) left")
                : sorted == 1 ? String(localized: "Sorted 1 conversation") : String(localized: "Sorted \(sorted) conversations"))
            // Other devices pick up the sorting, and don't redo it.
            Task { await self.syncNow() }
        }
    }

    /// Stops after the conversation being looked at; Sort Now carries on from there.
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
        sortingChecked[LabelStore.key(for: thread)] = Self.sortingMark(thread)
    }

    func pickGroup(for thread: MailThread, among groups: [EmailGroup]) async -> EmailGroup? {
        if let intelligence {
            await loadAllBodies(of: thread)
            if let group = try? await intelligence.classify(thread, bodies: bodies(of: thread), groups: groups) { return group }
        }
        return EmailSorter.ruleGroup(for: thread, groups: groups)
    }

    /// New mail goes into its group as it arrives, when that's on.
    func sortNewMail(_ threads: [MailThread]) async {
        guard sortsNewMail, sortingTask == nil, agentTask == nil else { return }
        let groups = emailGroups
        for thread in threads.prefix(20) where needsSorting(thread) {
            if let group = await pickGroup(for: thread, among: groups) { addLabel(group.name, to: thread) }
            sortingChecked[LabelStore.key(for: thread)] = Self.sortingMark(thread)
        }
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
        allInboxesThreads(nil).filter { Calendar.current.isDateInToday($0.date) }.count
    }

    /// Bills that haven't been opened.
    public var unopenedBills: [MailThread] {
        guard let bills = emailGroups.first(where: { $0.name == EmailGroup.starters[3].name }) else { return [] }
        return allInboxesThreads(nil).filter { $0.isUnread && labels(for: $0).contains { $0.caseInsensitiveCompare(bills.name) == .orderedSame } }
    }

    /// Groups with something in the inbox, with how many.
    public var homeGroups: [(group: EmailGroup, count: Int)] {
        let threads = allInboxesThreads(nil).filter { !isSnoozed($0) }
        return emailGroups.compactMap { group in
            let count = threads.filter { thread in labels(for: thread).contains { $0.caseInsensitiveCompare(group.name) == .orderedSame } }.count
            return count > 0 ? (group, count) : nil
        }
    }
}
