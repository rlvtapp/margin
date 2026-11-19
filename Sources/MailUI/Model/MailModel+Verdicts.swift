import Foundation
import MailCore

/// The assistant reads inbox mail in batches and says what it is (`MailVerdict`): sent by a
/// system, waiting on your answer, asking you to pay. The Other tab (for automated mail without
/// list headers), "reply owed" and "bill" come from that. With AI off, or no assistant, nothing
/// is read and those simply aren't offered.
extension MailModel {
    private var verdictsFile: JSONFile<[String: MailVerdict]> {
        JSONFile(url: environment.folder.appending(path: "verdicts.json"))
    }

    /// Read once at start, before the inbox is sorted into its tabs.
    func loadVerdicts() {
        guard !environment.isPreview, let saved = verdictsFile.load() else { return }
        MailVerdicts.shared.replaceAll(saved)
    }

    /// Whether the assistant still has to read a conversation: no verdict on its newest message,
    /// not one it already gave up on, and somewhere a verdict changes something (what headers
    /// alone call People, or the Bills group).
    func needsVerdict(_ thread: MailThread) -> Bool {
        guard MailVerdicts.shared[thread.latest] == nil, !verdictSkipped.contains(MailVerdicts.key(thread.latest)) else { return false }
        return thread.split == .people || group(of: thread)?.name == Self.billsGroupName
    }

    /// Works through the inbox, newest first, a batch at a time, until every conversation that
    /// needs one has a verdict. Runs on the quick assistant (Apple's model on this Mac by default).
    func judgeInbox() {
        // Previews and tests have no real mail to read, and shouldn't wait on a model.
        guard !environment.isPreview, verdictTask == nil, let intelligence = quickIntelligence else { return }
        verdictTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let todo = Array(self.inboxThreads(nil).filter(self.needsVerdict).prefix(intelligence.verdictBatchSize))
                guard !todo.isEmpty else { break }
                await self.judge(todo, using: intelligence)
            }
            self?.verdictTask = nil
        }
    }

    /// Mail that just arrived is read before it's announced, so it lands in the right tab and a
    /// system's mail doesn't alert as a person's.
    func judgeThenNotify() {
        let seen = seenUnread ?? []
        // A few at most, so an alert waits a few seconds at worst; the rest are read after.
        let fresh = Array(unreadInInboxes(limit: 40).filter { !seen.contains($0.id) && needsVerdict($0) }.prefix(5))
        guard !environment.isPreview, !fresh.isEmpty, let intelligence = quickIntelligence else {
            notifyAboutNewMail()
            judgeInbox()
            return
        }
        Task { [weak self] in
            for start in stride(from: 0, to: fresh.count, by: intelligence.verdictBatchSize) {
                await self?.judge(Array(fresh[start..<min(start + intelligence.verdictBatchSize, fresh.count)]), using: intelligence)
            }
            self?.notifyAboutNewMail()
            self?.judgeInbox()
        }
    }

    /// One batch. A batch the model can't answer is split in half and tried again; a single
    /// conversation it can't answer, or leaves out, is given up on until something new arrives
    /// in it, so the same mail isn't asked about forever.
    func judge(_ threads: [MailThread], using intelligence: MailIntelligence) async {
        let me = accounts.flatMap { [$0.address] + ($0.aliases ?? []) }
        do {
            let found = try await intelligence.judge(batch: threads, me: me)
            record(found, for: threads)
            let missing = threads.filter { found[$0.id] == nil }
            // Left out of a batch: asked again on their own, a few at a time.
            if missing.count < threads.count, !missing.isEmpty {
                await judge(missing, using: intelligence)
            } else if threads.count > 1, !missing.isEmpty {
                let half = threads.count / 2
                await judge(Array(threads[..<half]), using: intelligence)
                await judge(Array(threads[half...]), using: intelligence)
            } else {
                for thread in missing { verdictSkipped.insert(MailVerdicts.key(thread.latest)) }
            }
        } catch where threads.count > 1 {
            let half = threads.count / 2
            await judge(Array(threads[..<half]), using: intelligence)
            await judge(Array(threads[half...]), using: intelligence)
        } catch {
            verdictSkipped.insert(MailVerdicts.key(threads[0].latest))
        }
    }

    /// Remembers what the assistant read, and moves each conversation to the tab it now belongs in.
    func record(_ found: [String: MailVerdict], for threads: [MailThread]) {
        guard !found.isEmpty else { return }
        var keyed: [String: MailVerdict] = [:]
        for thread in threads {
            guard let verdict = found[thread.id] else { continue }
            keyed[MailVerdicts.key(thread.latest)] = verdict
            // The tab follows the conversation's first message: a system's mail that started it
            // counts as the system's.
            let first = thread.messages[0]
            if MailVerdicts.shared[first] == nil { keyed[MailVerdicts.key(first)] = verdict }
        }
        MailVerdicts.shared.set(keyed)
        if !environment.isPreview { verdictsFile.save(MailVerdicts.shared.all) }
        var moved = false
        for thread in threads where found[thread.id] != nil {
            guard let account = thread.accountID ?? Self.accountID(inThreadID: thread.id),
                  let index = shelves[account]?.position(of: thread) else { continue }
            let current = shelves[account]!.threads[index]
            if shelves[account]!.replace(at: index, with: current) { moved = true }
        }
        inboxesChanged(order: moved)
    }
}
