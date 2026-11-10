import Foundation
import MailCore

/// Saved mail, search across everything, folders, and drafts.
extension MailModel {
    /// The thread as the provider knows it: without the account prefix on its id.
    nonisolated static func untagged(_ thread: MailThread) -> MailThread {
        var copy = thread
        if let accountID = thread.accountID { copy.id = String(thread.id.dropFirst(accountID.uuidString.count + 1)) }
        copy.accountID = nil
        return copy
    }

    /// Fills the window from mail kept on this device, before any server answers.
    func loadSavedMail() async {
        for account in accounts {
            guard let saved = await environment.cache.mailboxes(account: account.id),
                  let inbox = saved.first(where: { $0.role == .inbox }) else { continue }
            mailboxes[account.id] = saved
            inboxes[account.id] = await environment.cache.threads(account: account.id, mailbox: inbox.id).map { Self.tag($0, account: account.id) }
        }
        if selectedThread == nil { selectedThreadID = firstConversation }
    }

    /// True when every account failed to refresh and saved mail is showing.
    public var isOffline: Bool {
        !accounts.isEmpty && accounts.allSatisfy { loadErrors[$0.id] != nil && !(inboxes[$0.id] ?? []).isEmpty }
    }

    // MARK: Search

    /// Searches saved mail at once, then every server for older mail.
    public func runSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        place = .search(trimmed)
        selection = []
        let query = SearchQuery(trimmed)
        var operators = query
        operators.words = []
        isSearchingServers = true
        Task {
            // Saved mail first, so results show while servers are asked.
            let local = await environment.cache.search(trimmed)
            var found = Dictionary(grouping: local, by: \.account).flatMap { account, rows in
                Threader.threads(from: rows.map(\.message)).map { Self.tag($0, account: account) }
            }
            found += inboxThreads(nil).filter { query.matches($0) }
            show(found, for: trimmed, operators: operators)

            let jobs = accounts.compactMap { account in (try? provider(for: account)).map { (account.id, $0) } }
            let remote = await withTaskGroup(of: [MailThread].self) { group in
                for (accountID, provider) in jobs {
                    group.addTask {
                        ((try? await provider.search(trimmed, limit: 50)) ?? []).map { Self.tag($0, account: accountID) }
                    }
                }
                var all: [MailThread] = []
                for await threads in group { all += threads }
                return all
            }
            found += remote
            show(found, for: trimmed, operators: operators)
            if place == .search(trimmed) { isSearchingServers = false }
        }
    }

    private func show(_ threads: [MailThread], for text: String, operators: SearchQuery) {
        guard place == .search(text) else { return }
        // The same message can come from saved mail and a server: keep one, by Message-ID.
        var seen = Set<String>()
        folder = threads.sorted { $0.date > $1.date }.filter { thread in
            let key = "\(thread.accountID?.uuidString ?? "")|\(thread.messages.first?.messageID ?? thread.id)"
            return seen.insert(key).inserted && operators.matches(thread)
        }
        if selectedThread == nil, opensFirstConversation { selectedThreadID = folder.first?.id }
    }

    // MARK: Folders

    public func createFolder(named name: String, in accountID: UUID) {
        folderChange(accountID) { try await $0.createMailbox(named: name) }
    }

    public func renameFolder(_ mailbox: Mailbox, in accountID: UUID, to name: String) {
        folderChange(accountID) { try await $0.renameMailbox(mailbox, to: name) }
    }

    public func deleteFolder(_ mailbox: Mailbox, in accountID: UUID) {
        if case .mailbox(let current, let open) = place, current == accountID, open.id == mailbox.id { go(to: .inbox(account: accountID, split: nil)) }
        folderChange(accountID) { try await $0.deleteMailbox(mailbox) }
    }

    private func folderChange(_ accountID: UUID, _ change: @escaping @Sendable (any MailProvider) async throws -> Void) {
        guard let account = account(accountID), let provider = try? provider(for: account) else { return }
        Task {
            do {
                try await change(provider)
                let boxes = try await provider.mailboxes()
                mailboxes[accountID] = boxes
                await environment.cache.saveMailboxes(boxes, account: accountID)
            } catch {
                show(error)
            }
        }
    }

    /// Moves the selected conversations (or the open one) into a folder of their account.
    public func move(to mailbox: Mailbox) {
        perform(.move(toMailboxID: mailbox.id))
        notice = Notice(text: String(localized: "Moved to \(mailbox.name)"))
    }

    // MARK: Drafts

    /// Closing a message with something in it keeps it in Drafts instead of losing it.
    public func closeComposer(_ state: ComposeState, isReply: Bool) {
        if isReply { reply = nil } else { compose = nil }
        focusRequest += 1
        saveToDrafts(state)
    }

    /// Keeps a message that's being closed in Drafts, if anything was written.
    func saveToDrafts(_ state: ComposeState) {
        guard state.hasContent, let account = account(state.accountID), let provider = try? provider(for: account) else { return }
        var draft = state.draft
        draft.to = EmailAddress.parseList(state.to) ?? []
        draft.cc = EmailAddress.parseList(state.cc) ?? []
        Task {
            do {
                try await provider.saveDraft(draft)
                if let old = state.editedDraft { await apply(.trash, to: [old], announce: false); await flushPendingChange() }
                notice = Notice(text: String(localized: "Saved to Drafts"))
            } catch {
                show(error)
            }
        }
    }

    /// Opens a saved draft in the composer; sending it removes the saved copy.
    public func editDraft(_ thread: MailThread) {
        guard let account = account(thread.accountID) else { return }
        let message = thread.latest
        var draft = Draft(from: account.address, to: message.to, cc: message.cc, subject: message.subject,
                          text: body(of: message, in: thread)?.text ?? message.snippet)
        draft.inReplyTo = message.inReplyTo
        draft.references = message.references
        var state = ComposeState(account: account, draft: draft)
        state.editedDraft = thread
        compose = state
    }

    // MARK: Folder order and hiding (kept on this device)

    /// The person's own folders in tree order, with how deep each sits; hidden ones left out
    /// unless asked for.
    public func ownFolders(of accountID: UUID, includingHidden: Bool = false) -> [(mailbox: Mailbox, depth: Int)] {
        let own = (mailboxes[accountID] ?? []).filter { $0.role == .other }
        let hidden = Set(hiddenFolderIDs(accountID))
        let tree = Mailbox.tree(own, order: folderOrder(accountID))
        guard !includingHidden else { return tree }
        // A hidden folder hides the folders inside it too.
        var skipping: Int?
        return tree.filter { item in
            if let depth = skipping, item.depth > depth { return false }
            skipping = nil
            if hidden.contains(item.mailbox.id) { skipping = item.depth; return false }
            return true
        }
    }

    public func hiddenFolders(of accountID: UUID) -> [Mailbox] {
        let hidden = Set(hiddenFolderIDs(accountID))
        return (mailboxes[accountID] ?? []).filter { hidden.contains($0.id) }
    }

    public func isHidden(_ mailbox: Mailbox, in accountID: UUID) -> Bool {
        hiddenFolderIDs(accountID).contains(mailbox.id)
    }

    public func setHidden(_ hidden: Bool, _ mailbox: Mailbox, in accountID: UUID) {
        var ids = hiddenFolderIDs(accountID).filter { $0 != mailbox.id }
        if hidden { ids.append(mailbox.id) }
        environment.defaults.set(ids, forKey: "hiddenFolders.\(accountID.uuidString)")
        folderRevision += 1
    }

    /// Puts folder `id` just before `target` among its siblings.
    public func moveFolder(_ id: String, before target: String, in accountID: UUID) {
        let siblings = ownFolders(of: accountID, includingHidden: true).map(\.mailbox.id)
        var order = siblings.filter { $0 != id }
        order.insert(id, at: order.firstIndex(of: target) ?? order.endIndex)
        environment.defaults.set(order, forKey: "folderOrder.\(accountID.uuidString)")
        folderRevision += 1
    }

    private func hiddenFolderIDs(_ accountID: UUID) -> [String] {
        _ = folderRevision
        return environment.defaults.stringArray(forKey: "hiddenFolders.\(accountID.uuidString)") ?? []
    }

    private func folderOrder(_ accountID: UUID) -> [String] {
        _ = folderRevision
        return environment.defaults.stringArray(forKey: "folderOrder.\(accountID.uuidString)") ?? []
    }
}
