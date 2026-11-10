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
    public func ask(_ question: String) {
        guard let intelligence, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let files = askAttachments
        askAttachments = []
        askAnswer = nil
        askSources = []
        assistantWork.insert("ask")
        Task {
            defer { assistantWork.remove("ask") }
            let hits = await environment.cache.search(question, limit: 60, anyWord: true)
            var threads: [MailThread] = []
            var seen = Set<String>()
            for (accountID, message) in hits {
                let subject = "\(accountID)|\(Subject.normalized(message.subject))"
                guard seen.insert(subject).inserted else { continue }
                let related = hits.filter { $0.account == accountID && Subject.normalized($0.message.subject) == Subject.normalized(message.subject) }.map(\.message)
                threads.append(Self.tag(MailThread(id: message.id, messages: related), account: accountID))
                if threads.count == 8 { break }
            }
            var context: [(MailThread, [String: MessageBody])] = []
            for thread in threads {
                var found = bodies(of: thread)
                if let account = account(thread.accountID), let provider = try? provider(for: account) {
                    for message in thread.messages where found[message.id] == nil {
                        let cached = await environment.cache.body(of: message.id, account: account.id)
                        if let saved = message.body ?? cached {
                            found[message.id] = saved
                        } else if let body = try? await provider.body(of: message) {
                            found[message.id] = body
                            await environment.cache.saveBody(body, of: message, account: account.id)
                        }
                    }
                }
                context.append((thread, found))
            }
            let me = accounts.first?.address ?? EmailAddress(address: "me@example.com")
            do {
                let answer = try await intelligence.ask(AskAttachment.prompt(question, with: files), about: context, me: me)
                askAnswer = answer
                askSources = answer.sources.compactMap { threads.indices.contains($0 - 1) ? threads[$0 - 1] : nil }
                recordAsk(question, answer: answer.text, sources: askSources)
            } catch {
                recordAsk(question, answer: error.localizedDescription, sources: [], isError: true)
            }
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
