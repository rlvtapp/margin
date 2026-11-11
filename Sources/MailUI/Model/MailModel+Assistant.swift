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
            } catch {
                show(error)
            }
        }
    }

    public func dismissSummary(of thread: MailThread) {
        summaries[thread.id] = nil
    }

    // MARK: Labels

    public func labels(for thread: MailThread) -> [String] {
        labelStore.labels(for: thread)
    }

    public var allLabels: [String] { labelStore.allLabels }

    public func addLabel(_ label: String, to thread: MailThread) {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        labelStore.add(cleaned, to: thread)
        labelSuggestions[thread.id]?.removeAll { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
    }

    public func removeLabel(_ label: String, from thread: MailThread) {
        labelStore.remove(label, from: thread)
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
        guard let thread = selectedThread, let intelligence else { return }
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
                let style = writingStyle(for: recipient, account: account, language: languageOf(thread))
                let text = try await intelligence.write(resolved, thread: thread, bodies: bodies(of: thread), me: account.address,
                                                        draft: typed, style: style)
                if reply != nil { reply?.draft.text = inYourStyle(text, language: languageOf(thread)) }
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
    /// The question without filler words ("do I have…", "wanneer is…"), for searching saved mail.
    static func searchTerms(in question: String) -> String {
        let filler: Set<String> = [
            "a", "an", "the", "do", "does", "did", "i", "me", "my", "you", "your", "we", "our", "is", "are", "was", "were",
            "have", "has", "had", "any", "anything", "something", "what", "when", "where", "who", "why", "how", "which",
            "to", "of", "in", "on", "at", "for", "from", "with", "about", "and", "or", "can", "could", "should", "will",
            "would", "there", "this", "that", "it", "be", "show", "find", "tell", "give", "list", "please", "soon", "some",
            "de", "het", "een", "ik", "mijn", "heb", "is", "er", "wat", "wanneer", "waar", "wie", "hoe", "van", "voor", "met",
            "der", "die", "das", "ein", "eine", "ich", "mein", "habe", "ist", "was", "wann", "wo", "wer", "wie", "für", "mit",
            "le", "la", "les", "un", "une", "je", "mon", "ma", "est", "quand", "où", "qui", "quoi", "pour", "avec",
            "el", "los", "las", "una", "yo", "mi", "es", "qué", "cuándo", "dónde", "quién", "para", "con",
        ]
        return question.split(whereSeparator: { $0.isWhitespace || "?!.,;:¿¡“”\"'".contains($0) })
            .map(String.init)
            .filter { !filler.contains($0.lowercased()) }
            .joined(separator: " ")
    }

    /// What Margin knows that isn't in any one email: the day, upcoming meetings, bills not
    /// opened, mail that needs a reply and mail waiting on others. Given to Ask with each question.
    func askFacts(now: Date = Date(), numbers: [String: Int] = [:]) -> String {
        func cite(_ thread: MailThread) -> String { numbers[thread.id].map { " [\($0)]" } ?? "" }
        var lines = ["Today is \(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))."]
        let soon = agenda(from: now, to: now.addingTimeInterval(14 * 86_400)).filter { $0.response != .declined }.prefix(12)
        let from = readsAccountCalendars ? "from the calendar and invitations" : "from invitations in the mail; Margin can't see the rest of the calendar"
        if soon.isEmpty {
            lines.append("Upcoming meetings (next two weeks, \(from)): none.")
        } else {
            lines.append("Upcoming meetings (next two weeks, \(from)):")
            for event in soon {
                let when = event.isAllDay ? event.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
                    : event.start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
                let place = (event.location ?? "").isEmpty ? "" : " at \(event.location!)"
                lines.append("- \(event.title), \(when)\(place)")
            }
        }
        let bills = unopenedBills.prefix(5)
        if !bills.isEmpty {
            lines.append("Bills not opened yet:")
            for bill in bills { lines.append("- \(bill.subject) from \(bill.latest.from.displayName), \(bill.date.formatted(date: .abbreviated, time: .omitted))\(cite(bill))") }
        }
        let owed = allInboxesThreads(nil).filter { !isSnoozed($0) && owesReply($0, now: now) }.prefix(8)
        if !owed.isEmpty {
            lines.append("Mail that needs a reply:")
            for thread in owed { lines.append("- \(thread.latest.from.displayName) <\(thread.latest.from.address)>: \(thread.subject)\(cite(thread))") }
        }
        if waitingCount > 0 { lines.append("Sent mail still waiting for an answer: \(waitingCount).") }
        return lines.joined(separator: "\n")
    }

    public func ask(_ question: String) {
        guard let intelligence, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let files = askAttachments
        askAttachments = []
        askAnswer = nil
        askSources = []
        assistantWork.insert("ask")
        askProgress = .searching
        Task {
            defer { assistantWork.remove("ask"); askProgress = nil }
            await refreshCalendar()
            let threads = await askConversations(for: question)
            askProgress = .reading(threads.count)
            let context = await askContext(threads)
            let numbers = Dictionary(threads.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
            let me = accounts.first?.address ?? EmailAddress(address: "me@example.com")
            do {
                let answer = try await intelligence.ask(AskAttachment.prompt(question, with: files), about: context, me: me,
                                                        facts: askFacts(numbers: numbers)) { [weak self] text in
                    await MainActor.run { self?.askProgress = .writing(text) }
                }
                askAnswer = answer
                askSources = answer.sources.compactMap { threads.indices.contains($0 - 1) ? threads[$0 - 1] : nil }
                recordAsk(question, answer: answer.text, sources: askSources)
            } catch {
                recordAsk(question, answer: error.localizedDescription, sources: [], isError: true)
            }
        }
    }

    /// The conversations an answer may draw on, numbered in this order: what Home already
    /// knows needs you (replies owed, bills, today's mail from people), then saved mail that
    /// matches the question. Junk, Trash and accounts no longer here are left out.
    func askConversations(for question: String, now: Date = Date(), limit: Int = 10) async -> [MailThread] {
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
        let terms = Self.searchTerms(in: question)
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
    func askContext(_ threads: [MailThread]) async -> [(MailThread, [String: MessageBody])] {
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
        struct Missing: Sendable { var index: Int; var message: MailMessage; var account: UUID; var provider: any MailProvider }
        var missing: [Missing] = []
        for (index, item) in context.enumerated() {
            guard let account = account(item.0.accountID), let provider = try? provider(for: account) else { continue }
            for message in item.0.messages where item.1[message.id] == nil {
                missing.append(Missing(index: index, message: message, account: account.id, provider: provider))
            }
        }
        let cache = environment.cache
        let fetched = await withTaskGroup(of: (Int, String, MessageBody?).self) { group in
            for item in missing.prefix(24) {
                group.addTask {
                    let body = try? await item.provider.body(of: item.message)
                    if let body { await cache.saveBody(body, of: item.message, account: item.account) }
                    return (item.index, item.message.id, body)
                }
            }
            var results: [(Int, String, MessageBody?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (index, id, body) in fetched { if let body { context[index].1[id] = body } }
        return context
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
