import Foundation
import MailCore

/// Summaries, labels and reply drafts, from whichever model the person chose.
/// Nothing runs on its own: every request starts from something the person asked for.
extension MailModel {
    public var isAssistantOn: Bool { intelligence != nil }

    /// "on this Mac", "by Claude": shown wherever the assistant's words appear.
    public var assistantAttribution: String { intelligence?.model.attribution ?? "" }

    public func isWorking(_ task: String, on thread: MailThread? = nil) -> Bool {
        assistantWork.contains(thread.map { "\(task)|\($0.id)" } ?? task)
    }

    /// Saves the choice (and a new API key, if one was typed) and switches models.
    public func applyAssistant(_ settings: AssistantSettings, apiKey: String?) {
        if let apiKey {
            if apiKey.isEmpty {
                environment.keychain.delete(key: settings.provider.keychainKey)
            } else {
                try? environment.keychain.save(apiKey, key: settings.provider.keychainKey)
            }
        }
        assistantSettings = settings
        environment.defaults.set(try? JSONEncoder().encode(settings), forKey: "assistantSettings")
        rebuildIntelligence()
        // Kept for actions after switching to another provider.
        rememberAssistantProfile(settings)
    }

    public func savedAPIKey(for provider: AssistantProvider) -> String? {
        environment.keychain.read(key: provider.keychainKey)
    }

    func rebuildIntelligence() {
        guard usesAI else {
            intelligence = nil
            return
        }
        let key = environment.keychain.read(key: assistantSettings.provider.keychainKey)
        intelligence = assistantSettings.makeModel(apiKey: key).map(MailIntelligence.init(model:))
    }

    // MARK: Summaries

    public func summarizeSelected() {
        guard let thread = selectedThread, let intelligence, let account = account(thread.accountID) else { return }
        let key = "summary|\(thread.id)"
        guard !assistantWork.contains(key) else { return }
        assistantWork.insert(key)
        Task {
            defer { assistantWork.remove(key) }
            do {
                summaries[thread.id] = try await intelligence.summarize(thread, bodies: bodies(of: thread), me: account.address)
                saveSummaries()
            } catch {
                show(error)
            }
        }
    }

    public func dismissSummary(of thread: MailThread) {
        summaries[thread.id] = nil
        saveSummaries()
    }

    // Kept across launches, so a conversation is never summarised twice, but only while its
    // newest email is still the one the summary read.

    private struct SavedSummary: Codable {
        var threadID: String
        var latestMessageID: String
        var summary: ThreadSummary
    }

    private var summariesFile: JSONFile<[SavedSummary]> { JSONFile(url: environment.folder.appending(path: "summaries.json")) }

    private func saveSummaries() {
        guard !environment.isPreview else { return }
        let threads = Dictionary((inboxThreads(nil) + folder).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = summaries.compactMap { id, summary in threads[id].map { SavedSummary(threadID: id, latestMessageID: $0.latest.id, summary: summary) } }
        summariesFile.save(Array(saved.suffix(300)))
    }

    /// Puts back saved summaries whose conversation hasn't had new mail since.
    func restoreSummariesIfNeeded() {
        guard !summariesRestored, !environment.isPreview else { return }
        summariesRestored = true
        let latest = Dictionary(inboxThreads(nil).map { ($0.id, $0.latest.id) }, uniquingKeysWith: { first, _ in first })
        for saved in summariesFile.load() ?? [] where latest[saved.threadID] == saved.latestMessageID && summaries[saved.threadID] == nil {
            summaries[saved.threadID] = saved.summary
        }
    }

    // MARK: Labels

    /// The conversation's labels: the server's, where the account keeps labels, then Margin's own.
    public func labels(for thread: MailThread) -> [String] {
        let own = labelStore.labels(for: thread)
        let server = serverLabels(for: thread)
        guard !server.isEmpty else { return own }
        return server + own.filter { label in !server.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
    }

    public var allLabels: [String] { labelStore.allLabels }

    /// `onServer`: a label the person gave, which goes on the server where the account keeps
    /// labels. Ones Margin gives itself (groups, reminders) stay on this device.
    public func addLabel(_ label: String, to thread: MailThread, onServer: Bool = false) {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if onServer, keepsLabels(thread.accountID), !emailGroups.contains(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            // The name as the server already has it, so "projects" joins "Projects".
            let known = mailboxes[thread.accountID!]?.compactMap(\.label).first { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
            changeServerLabel(known ?? cleaned, adding: true, on: thread)
        } else {
            labelStore.add(cleaned, to: thread)
        }
        labelSuggestions[thread.id]?.removeAll { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
    }

    /// `onServer`: the person took the label off (a chip's ✕), so a server label of that name
    /// comes off on the server too. Margin's own removals (groups) only touch its own labels.
    public func removeLabel(_ label: String, from thread: MailThread, onServer: Bool = false) {
        if onServer, let server = serverLabels(for: thread).first(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
            changeServerLabel(server, adding: false, on: thread)
        }
        labelStore.remove(label, from: thread)
        // Taking a conversation out of its group this way (the label's ✕) lets Sort Now look at
        // it again; "Not in a group" (`move(_:toGroup:)`) marks it to stay out afterwards.
        if emailGroups.contains(where: { $0.name.caseInsensitiveCompare(label) == .orderedSame }),
           sortingChecked[LabelStore.key(for: thread)] != nil {
            sortingChecked[LabelStore.key(for: thread)] = nil
        }
    }

    /// How many conversations carry each label.
    public var labelCounts: [String: Int] { labelStore.counts }

    /// Renames a label on every conversation. Returns how many changed.
    @discardableResult
    public func renameLabel(_ label: String, to newName: String) -> Int {
        labelStore.rename(label, to: newName)
    }

    /// Takes a label off every conversation. Returns how many changed.
    @discardableResult
    public func deleteLabel(_ label: String) -> Int {
        labelStore.delete(label)
    }

    public func suggestLabelsForSelected() {
        guard let thread = selectedThread, let intelligence = quickIntelligence else { return }
        let key = "labels|\(thread.id)"
        guard !assistantWork.contains(key) else { return }
        assistantWork.insert(key)
        let existing = allLabels
        let current = labels(for: thread)
        Task {
            defer { assistantWork.remove(key) }
            do {
                let suggested = try await intelligence.suggestLabels(thread, bodies: bodies(of: thread), existing: existing, current: current)
                labelSuggestions[thread.id] = suggested
                if suggested.isEmpty { notice = Notice(text: String(localized: "No label fits this conversation well")) }
            } catch {
                show(error)
            }
        }
    }

    // MARK: Writing

    /// Drafts or rewrites the open reply. A short note typed in the reply box ("yes, ask
    /// about Tuesday") becomes what the draft says.
    public func writeReply(_ instruction: WriteInstruction) {
        guard let thread = selectedThread, let intelligence, let account = account(thread.accountID) else { return }
        if reply == nil { startReply() }
        guard !assistantWork.contains("reply") else { return }
        let typed = reply?.draft.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A note passed in wins; otherwise whatever is typed in the reply box is the note.
        let resolved: WriteInstruction = if case .draft(let note) = instruction {
            .draft(note: note ?? (typed.isEmpty ? nil : typed))
        } else {
            instruction
        }
        if case .draft = resolved {} else if typed.isEmpty { return }
        assistantWork.insert("reply")
        Task {
            defer { assistantWork.remove("reply") }
            do {
                let recipient = reply.flatMap { EmailAddress.parseList($0.to)?.first }
                let style = writingStyle(for: recipient, account: account, language: languageOf(thread), theirText: theirLatestText(in: thread))
                // The draft fills in as it's written, instead of appearing all at once at the end.
                let text = try await intelligence.write(resolved, thread: thread, bodies: bodies(of: thread), me: account.address,
                                                        draft: typed, style: style) { [weak self] written in
                    await MainActor.run {
                        guard let self, self.reply != nil, !written.isEmpty else { return }
                        // "Sent from Margin" stays under what's written.
                        self.reply?.draft.text = written + (self.reply?.sentFrom ?? "")
                    }
                }
                if reply != nil { reply?.draft.text = text + (reply?.sentFrom ?? "") }
            } catch {
                show(error)
            }
        }
    }

    /// The loaded bodies of a thread's messages, keyed by message id.
    func bodies(of thread: MailThread) -> [String: MessageBody] {
        var result: [String: MessageBody] = [:]
        for message in thread.messages {
            if let body = body(of: message, in: thread) { result[message.id] = body }
        }
        return result
    }

    // MARK: Ask

    /// Finds the conversations most likely to hold the answer (offline index, any word),
    /// reads them, and asks the model to answer from those alone.
    /// What Margin knows that isn't in any one email: the day, upcoming meetings, bills not
    /// opened, mail that needs a reply and mail waiting on others. Given to Ask with each question.
    /// `calendar`: the calendar as the assistant looked it up for this question, in place of the
    /// meetings already loaded. `offered`: changes waiting for the person to confirm.
    /// `showsEvents`: the events read are shown under the answer, so the answer needn't list them.
    func askFacts(now: Date = Date(), numbers: [String: Int] = [:], calendar: [String]? = nil, offered: [AskCalendarAction] = [],
                  showsEvents: Bool = false) -> String {
        func cite(_ thread: MailThread) -> String { numbers[thread.id].map { " [\($0)]" } ?? "" }
        var lines = ["Today is \(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))."]
        let soonEnd = now.addingTimeInterval(14 * 86_400)
        let all = agenda(from: now, to: soonEnd).filter { $0.response != .declined }
        let soon = all.prefix(20)
        let from = readsAccountCalendars ? "from the calendar and invitations" : "from invitations in the mail; Margin can't see the rest of the calendar"
        // Not loaded isn't the same as empty: an empty list would be read as a free fortnight.
        let loaded = !readsAccountCalendars || environment.isPreview
            || (calendarEventsRange.map { $0.contains(now) && $0.contains(soonEnd) } ?? false)
        if let calendar {
            lines += calendar
            if showsEvents {
                lines.append("The person sees these events as a list right under your answer, with their days, times and places. Don't list them again: answer the question in one or two sentences with what matters most for it.")
            }
        } else if soon.isEmpty && !loaded {
            lines.append("Upcoming meetings: not known, the calendar hasn't finished loading.")
        } else if soon.isEmpty {
            lines.append("Upcoming meetings (next two weeks, \(from)): none.")
        } else {
            lines.append("Upcoming meetings (next two weeks, \(from)\(all.count > soon.count ? ", the first \(soon.count) of \(all.count)" : "")):")
            for event in soon {
                let when = event.isAllDay ? event.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
                    : event.start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
                let place = (event.location ?? "").isEmpty ? "" : " at \(event.location!)"
                lines.append("- \(event.title), \(when)\(place)")
            }
        }
        // Every heading is always there, with "none" when it's empty: a model that isn't told
        // nothing needs a reply answers the question with whatever else it was given.
        let bills = unopenedBills.prefix(5)
        if bills.isEmpty {
            lines.append("Bills not opened yet: none.")
        } else {
            lines.append("Bills not opened yet:")
            for bill in bills { lines.append("- \(bill.subject) from \(bill.latest.from.displayName), \(bill.date.formatted(date: .abbreviated, time: .omitted))\(cite(bill))") }
        }
        let owed = allInboxesThreads(nil).filter { !isSnoozed($0) && owesReply($0, now: now) }.prefix(8)
        if owed.isEmpty {
            lines.append("Mail that needs a reply: none.")
        } else {
            lines.append("Mail that needs a reply:")
            for thread in owed { lines.append("- \(thread.latest.from.displayName) <\(thread.latest.from.address)>: \(thread.subject)\(cite(thread))") }
        }
        lines.append(waitingCount > 0 ? "Sent mail still waiting for an answer: \(waitingCount)." : "Sent mail still waiting for an answer: none.")
        if !offered.isEmpty {
            lines.append("Calendar changes offered to the person, not made yet: say what's ready and that they confirm it below the answer.")
            for action in offered { lines.append("- " + Self.describe(action)) }
        }
        return lines.joined(separator: "\n")
    }

    public func ask(_ question: String) {
        ask(question, lookup: askLookupAgent())
    }

    /// `lookup`: the assistant, ready to look things up with tools (mail search, the calendar);
    /// nil when it can't call tools, and a plan of what to look up stands in.
    func ask(_ question: String, lookup agent: (any MailAgentModel)?) {
        guard let intelligence, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let files = askAttachments
        askAttachments = []
        askAnswer = nil
        askSources = []
        assistantWork.insert("ask")
        askProgress = agent == nil ? .searching : .lookingUp
        Task {
            defer { assistantWork.remove("ask"); askProgress = nil }
            let prompt = AskAttachment.prompt(question, with: files)
            var threads: [MailThread] = []
            var calendar: [String]?
            var offered: [AskCalendarAction] = []
            var events: [AskEvent] = []
            var searched = false
            var looked: AskLookup?
            if let agent {
                // The loaded months refresh in the background for later; the tools read what
                // the question needs themselves, whatever the dates.
                Task { await refreshCalendar() }
                do {
                    looked = try await lookUp(prompt, with: agent)
                    // A server that might not support tools and called none most likely ignored
                    // them: Ask plans instead, as it would without tools. Once one is used,
                    // that's remembered.
                    if assistantSettings.provider.actionSupport == .dependsOnModel, let calls = looked?.toolCalls {
                        if calls > 0 {
                            rememberActionSupport(true, key: assistantSettings.actionKey)
                        } else if canTakeActions(assistantSettings) != true {
                            looked = nil
                        }
                    }
                } catch AssistantError.toolsUnsupported {
                    if assistantSettings.provider.actionSupport == .dependsOnModel { rememberActionSupport(false, key: assistantSettings.actionKey) }
                } catch {
                    if Task.isCancelled { return }
                }
            }
            if let looked {
                threads = looked.threads
                searched = !threads.isEmpty
                calendar = looked.readCalendar ? looked.facts : nil
                offered = looked.actions
                events = looked.events
                // A question the calendar answered gets no conversations; otherwise what Home
                // knows needs you comes after what was searched for.
                if !(looked.readCalendar && threads.isEmpty) {
                    for thread in await askConversations(for: "", searches: false)
                    where !threads.contains(where: { $0.id == thread.id }) { threads.append(thread) }
                }
            } else {
                // The calendar gets a moment to catch up; after that the answer uses what's known,
                // and the refresh finishes for next time.
                let refresh = Task { await refreshCalendar() }
                await Self.wait(for: refresh, upTo: .milliseconds(1500))
                // The model decides what to look up: words to search for, or nothing when the facts
                // (the calendar, bills, replies owed) answer it, which skips the search and the
                // download of whole conversations. Quick assistant, a couple of seconds at most.
                let plan = await askPlan(for: question)
                if plan.calendar {
                    askProgress = .calendar
                    if let read = await askPlannedCalendar(plan) {
                        calendar = [read.facts]
                        events = read.events
                    }
                }
                threads = plan.calendar ? scheduleConversations() : []
                for thread in await askConversations(for: plan.search, searches: !plan.search.isEmpty)
                where !threads.contains(where: { $0.id == thread.id }) { threads.append(thread) }
                searched = !plan.search.isEmpty
            }
            threads = askScope(Array(threads.prefix(10)))
            askProgress = .reading(threads.count)
            let context = await askContext(threads, fetchMissing: searched)
            let numbers = Dictionary(threads.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
            let me = accounts.first?.address ?? EmailAddress(address: "me@example.com")
            do {
                let answer = try await intelligence.ask(prompt, about: context, me: me,
                                                        facts: askFacts(numbers: numbers, calendar: calendar, offered: offered, showsEvents: !events.isEmpty),
                                                        style: askPreferences.style) { [weak self] text in
                    await MainActor.run { self?.askProgress = .writing(text) }
                }
                askAnswer = answer
                askSources = answer.sources.compactMap { threads.indices.contains($0 - 1) ? threads[$0 - 1] : nil }
                recordAsk(question, answer: answer.text, sources: askSources, actions: offered, events: events)
            } catch {
                recordAsk(question, answer: error.localizedDescription, sources: [], isError: true)
            }
        }
    }

    /// The conversations an answer may draw on, numbered in this order: what Home already
    /// knows needs you (replies owed, bills, today's mail from people), then saved mail that
    /// matches the question. Junk, Trash and accounts no longer here are left out.
    func askConversations(for question: String, now: Date = Date(), limit: Int = 10, searches: Bool = true) async -> [MailThread] {
        var threads: [MailThread] = []
        var seen = Set<String>()
        func add(_ thread: MailThread) {
            let key = "\(thread.accountID?.uuidString ?? "-")|\(Subject.normalized(thread.subject))"
            guard threads.count < limit, seen.insert(key).inserted else { return }
            threads.append(thread)
        }
        let inbox = allInboxesThreads(nil).filter { !isSnoozed($0) }
        for thread in inbox.filter({ owesReply($0, now: now) }).prefix(4) { add(thread) }
        for thread in unopenedBills.prefix(2) { add(thread) }
        let today = Calendar.current.startOfDay(for: now)
        for thread in inbox.filter({ $0.date >= today && InboxSplit.classify($0.latest) == .people }).prefix(3) {
            add(thread)
        }
        let terms = searches ? question : ""
        var hits = terms.isEmpty ? [] : await environment.cache.search(terms, limit: 80, anyWord: true)
        let current = Set(accounts.map(\.id))
        hits = hits.filter { hit in
            guard current.contains(hit.account) else { return false }
            let role = mailboxes[hit.account]?.first { $0.id == hit.message.mailboxID }?.role
            return role != .junk && role != .trash
        }
        // Recent mail first: an answer from this year beats a match from years ago.
        let recent = hits.filter { $0.message.date > now.addingTimeInterval(-400 * 86_400) }
        if recent.count >= 3 { hits = recent }
        for (accountID, message) in hits {
            let subject = Subject.normalized(message.subject)
            let related = hits.filter { $0.account == accountID && Subject.normalized($0.message.subject) == subject }.map(\.message)
            add(Self.tag(MailThread(id: message.id, messages: related), account: accountID))
        }
        return threads
    }

    /// Each conversation with its message bodies: from memory or this device first, and the
    /// rest fetched from the server all at once rather than one after another.
    func askContext(_ threads: [MailThread], fetchMissing: Bool = true) async -> [(MailThread, [String: MessageBody])] {
        var context: [(MailThread, [String: MessageBody])] = []
        for thread in threads {
            var found = bodies(of: thread)
            for message in thread.messages where found[message.id] == nil {
                if let saved = message.body { found[message.id] = saved; continue }
                if let account = thread.accountID, let cached = await environment.cache.body(of: message.id, account: account) {
                    found[message.id] = cached
                }
            }
            context.append((thread, found))
        }
        // Without the download, a message not on this device is read from its preview.
        guard fetchMissing else { return context }
        struct Missing: Sendable { var index: Int; var message: MailMessage; var account: UUID; var provider: any MailProvider }
        var missing: [Missing] = []
        for (index, item) in context.enumerated() {
            guard let account = account(item.0.accountID), let provider = try? provider(for: account) else { continue }
            for message in item.0.messages where item.1[message.id] == nil {
                missing.append(Missing(index: index, message: message, account: account.id, provider: provider))
            }
        }
        let cache = environment.cache
        // What the servers send within two seconds is used; the rest is read from its preview,
        // and arrives in the cache for the next question.
        let collected = FetchedBodies()
        let download = Task {
            await withTaskGroup(of: Void.self) { group in
                for item in missing.prefix(24) {
                    group.addTask {
                        guard let body = try? await item.provider.body(of: item.message) else { return }
                        await cache.saveBody(body, of: item.message, account: item.account)
                        await collected.add(item.index, item.message.id, body)
                    }
                }
            }
        }
        await Self.wait(for: download, upTo: .seconds(2))
        for (index, id, body) in await collected.all { context[index].1[id] = body }
        return context
    }

    /// Bodies as they arrive from the servers, read when Ask stops waiting.
    actor FetchedBodies {
        private(set) var all: [(Int, String, MessageBody)] = []
        func add(_ index: Int, _ id: String, _ body: MessageBody) { all.append((index, id, body)) }
    }

    /// What the model says to look up for a question. If it doesn't answer in time, the whole
    /// question is searched.
    func askPlan(for question: String, now: Date = Date()) async -> AskPlan {
        guard let intelligence = quickIntelligence ?? intelligence else { return AskPlan(search: question, calendar: false) }
        let today = "\(Self.iso(now)), time zone \(TimeZone.current.identifier)"
        let planned = await withTaskGroup(of: AskPlan?.self) { group in
            group.addTask { try? await intelligence.plan(question, now: today) }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return planned ?? AskPlan(search: question, calendar: false)
    }

    /// For a calendar question: the conversations behind the meetings coming up, from what's
    /// already loaded.
    func scheduleConversations(now: Date = Date()) -> [MailThread] {
        let soon = Set(calendarEntries.filter { !$0.cancelled && $0.finish > now && $0.start < now.addingTimeInterval(14 * 86_400) }
            .map(\.threadID))
        return allInboxesThreads(nil).filter { soon.contains($0.id) }.prefix(4).map { $0 }
    }

    /// Waits for a task, but no longer than `limit`; it carries on after that. (A task group
    /// can't do this: it waits for every child, and waiting on a task can't be cut short.)
    static func wait(for task: Task<Void, Never>, upTo limit: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            // Off the main thread, so a busy window can't hold the limit up.
            Task.detached { await task.value; once.resume() }
            Task.detached { try? await Task.sleep(for: limit); once.resume() }
        }
    }

    /// Resumes a continuation the first time it's asked, and ignores the rest.
    final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }

    /// Opens conversations from an answer in the list.
    public func showSources(_ threads: [MailThread], selecting thread: MailThread) {
        isAsking = false
        place = .search(String(localized: "Sources"))
        folder = threads
        selectedThreadID = thread.id
        Task { await loadBodies() }
    }
}
