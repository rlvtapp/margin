import Foundation
import MailCore

/// A Done or Trash waiting out its undo window.
struct PendingChange {
    var action: MailAction
    var threads: [MailThread]
    var task: Task<Void, Never>
    /// The conversations it took out of the inboxes; Undo puts these back where they were.
    var removed: [MailThread]
    var folder: [MailThread]
    var selection: MailThread.ID?
    /// Several changes at once (what rules did to new mail), each sent with its own action;
    /// empty for one `action` on all of `threads`.
    var batches: [(action: MailAction, threads: [MailThread])] = []
    /// The rules run these came from, so Undo can mark them undone in Recent activity.
    var ruleBatch: UUID?
}

extension MailModel {
    /// Done and Trash wait this long before reaching the server, so Undo is just a cancel.
    /// (After an IMAP move the messages have new ids, so undoing later would be guesswork.)
    static let undoWindow: Duration = .seconds(5)

    /// Acts on the selected conversations, or on the open one when nothing is selected.
    public func perform(_ action: MailAction) {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        selection = []
        Task { await apply(action, to: targets, announce: true) }
    }

    /// Acts on one conversation without opening it: a swipe or a long press on a row.
    public func perform(_ action: MailAction, on thread: MailThread) {
        Task { await apply(action, to: [thread], announce: true) }
    }

    public func toggleStar() {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        perform(targets.allSatisfy(\.isStarred) ? .unstar : .star)
    }

    public func toggleRead() {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        perform(targets.contains(where: \.isUnread) ? .markRead : .markUnread)
    }

    public func undo() {
        switch notice?.undo {
        case .send: undoSend(); return
        case .snooze: undoSnooze(); return
        default: break
        }
        guard let pending = pendingChange else { return }
        pending.task.cancel()
        pendingChange = nil
        mutationRevision += 1
        restoreToInboxes(pending.removed)
        folder = pending.folder
        selectedThreadID = pending.selection
        if let batch = pending.ruleBatch { markRuleActivityUndone(batch) }
        notice = nil
        focusRequest += 1
    }

    /// Changes local state first so the list answers instantly, then tells the server.
    func apply(_ action: MailAction, to threads: [MailThread], announce: Bool) async {
        let ids = Set(threads.map(\.id))
        // Filing by hand, for the rule Settings → Rules offers once it's a habit.
        if announce, case .move(let target) = action { noteFiling(threads, into: target) }
        let leaves: Bool = switch action {
        case .done, .trash: true
        case .move(let target): target != "INBOX"
        default: false
        }
        guard leaves else {
            // Only these conversations are touched: a read mark costs the same in a mailbox of
            // two hundred and of two hundred thousand.
            changeInInboxes(threads) { Self.changed($0, by: action) }
            if folder.contains(where: { ids.contains($0.id) }) {
                folder = folder.map { ids.contains($0.id) ? Self.changed($0, by: action) : $0 }
            }
            if announce, action == .markUnread { notice = Notice(text: String(localized: "Marked unread")) }
            await commit(action, threads)
            return
        }
        await flushPendingChange()
        let snapshot = (folder, selectedThreadID)
        let visible = visibleThreads
        if let index = visible.firstIndex(where: { ids.contains($0.id) }), ids.contains(selectedThreadID ?? "") {
            let remaining = visible.filter { !ids.contains($0.id) }
            selectedThreadID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        mutationRevision += 1
        let removed = removeFromInboxes(threads)
        if folder.contains(where: { ids.contains($0.id) }) { folder.removeAll { ids.contains($0.id) } }
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await self?.commitPending()
        }
        pendingChange = PendingChange(action: action, threads: threads, task: task, removed: removed, folder: snapshot.0, selection: snapshot.1)
        let count = threads.count
        let text = switch (action == .trash, count == 1) {
        case (true, true): String(localized: "Conversation moved to Trash")
        case (true, false): String(localized: "\(count) conversations moved to Trash")
        case (false, true): String(localized: "Conversation marked done")
        case (false, false): String(localized: "\(count) conversations marked done")
        }
        notice = Notice(text: text, undo: .change)
        if selectedThreadID != nil { await loadBodies() }
    }

    private func commitPending() async {
        guard let pending = pendingChange else { return }
        pendingChange = nil
        if notice?.canUndo == true { notice = nil }
        if pending.batches.isEmpty {
            await commit(pending.action, pending.threads)
        } else {
            for batch in pending.batches { await commit(batch.action, batch.threads) }
        }
    }

    /// Holds several moves for the undo window, like `apply` does for one: what rules did to new
    /// mail. The conversations are already out of the inboxes; `removed` is what Undo puts back.
    func holdForUndo(_ batches: [(action: MailAction, threads: [MailThread])], removed: [MailThread],
                     notice text: String, ruleBatch: UUID?) async {
        guard let first = batches.first else { return }
        await flushPendingChange()
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await self?.commitPending()
        }
        pendingChange = PendingChange(action: first.action, threads: batches.flatMap(\.threads), task: task, removed: removed,
                                      folder: folder, selection: selectedThreadID, batches: batches, ruleBatch: ruleBatch)
        notice = Notice(text: text, undo: .change)
    }

    /// Sends a waiting Done or Trash now, before another change or when the app quits.
    public func flushPendingChange() async {
        guard let pending = pendingChange else { return }
        pending.task.cancel()
        await commitPending()
    }

    /// Sends the change to each account's own server.
    private func commit(_ action: MailAction, _ threads: [MailThread]) async {
        for (accountID, group) in Dictionary(grouping: threads, by: \.accountID) {
            guard let account = account(accountID) else { continue }
            committingChanges[account.id, default: 0] += 1
            mutationRevision += 1
            var failure: Error?
            do {
                try await provider(for: account).perform(action, on: group)
            } catch {
                failure = error
            }
            committingChanges[account.id, default: 1] -= 1
            if committingChanges[account.id] == 0 { committingChanges[account.id] = nil }
            mutationRevision += 1
            if let failure {
                show(failure)
                await reload(only: account)
            }
        }
    }

    nonisolated static func changed(_ thread: MailThread, by action: MailAction) -> MailThread {
        var copy = thread
        for index in copy.messages.indices {
            switch action {
            case .markRead: copy.messages[index].flags.insert(.seen)
            case .markUnread: copy.messages[index].flags.remove(.seen)
            case .star: copy.messages[index].flags.insert(.flagged)
            case .unstar: copy.messages[index].flags.remove(.flagged)
            default: break
            }
        }
        return copy
    }

    // MARK: Writing

    public func startCompose() {
        compose = withSentFrom(ComposeState(account: currentAccount))
    }

    /// A mailto: link clicked inside a mail: compose from the account that mail came in on.
    public func startCompose(mailto url: URL) {
        let account = account(selectedThread?.accountID) ?? currentAccount
        var state = ComposeState(account: account)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        state.to = components?.path ?? ""
        for item in components?.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": state.draft.subject = item.value ?? ""
            case "body": state.draft.text = item.value ?? ""
            case "cc": state.cc = item.value ?? ""; state.showsCc = true
            case "to":
                let more = item.value ?? ""
                state.to = [state.to, more].filter { !$0.isEmpty }.joined(separator: ", ")
            default: break
            }
        }
        compose = withSentFrom(state)
    }

    /// Replies go out from the account the conversation arrived in.
    public func startReply(all: Bool = false) {
        guard let thread = selectedThread, let account = account(thread.accountID) else { return }
        // Mail sent to an alias is answered from that alias.
        reply = withSentFrom(ComposeState(account: account, draft: Draft.reply(to: withoutReactions(thread), from: account.replyAddress(for: thread), all: all),
                                          isReply: true))
    }

    /// A reply to one message of the open conversation, not necessarily the latest.
    public func startReply(to message: MailMessage, all: Bool = false) {
        guard let thread = selectedThread, let account = account(thread.accountID) else { return }
        var state = ComposeState(account: account,
                                 draft: Draft.reply(to: message, in: thread, from: account.replyAddress(for: thread), all: all),
                                 isReply: true)
        state.answersOneMessage = true
        reply = withSentFrom(state)
    }

    /// Forwards the latest message, or the one given.
    public func startForward(_ message: MailMessage? = nil) {
        guard let thread = selectedThread, let account = account(thread.accountID) else { return }
        let last = message ?? thread.latest
        let original = ForwardedOriginal(message: last, body: body(of: last, in: thread))
        let subject = "Fwd: " + (Subject.isReply(thread.subject) ? String(thread.subject.dropFirst(4)) : thread.subject)
        if original.html.isEmpty {
            // Plain mail is quoted as text in the message, as before.
            // The line goes above the quoted original, where the message ends.
            var state = withSentFrom(ComposeState(account: account, draft: Draft(from: account.address, subject: subject)))
            state.draft.text += original.quotedText
            compose = state
        } else {
            // HTML mail goes along underneath with its formatting; the cursor starts above it.
            var state = ComposeState(account: account, draft: Draft(from: account.address, subject: subject))
            state.forwarded = original
            compose = withSentFrom(state)
        }
    }

    /// Sends from the draft's account; on failure the draft stays open with the error.
    public func send(_ state: ComposeState) async -> Bool {
        if let error = await attemptSend(state) {
            show(error)
            return false
        }
        return true
    }

    /// Sends, and on failure returns why instead of showing it.
    func attemptSend(_ state: ComposeState) async -> Error? {
        do {
            var draft = try state.validated(includingForward: false)
            // Very large photos are made smaller first, as most mail apps do.
            draft.attachments = draft.attachments.map { attachment in
                let sized = ImageResizer.forSending(attachment.data, mimeType: attachment.mimeType)
                var copy = attachment
                copy.data = sized.data
                copy.mimeType = sized.mimeType
                if sized.mimeType == "image/jpeg", !["jpg", "jpeg"].contains((copy.filename as NSString).pathExtension.lowercased()) {
                    copy.filename = (copy.filename as NSString).deletingPathExtension + ".jpg"
                }
                return copy
            }
            guard let account = account(state.accountID) else { throw MailError.missingCredentials }
            // A formatted signature goes out formatted. The Mac's editor already shows it that way
            // and its HTML has it; otherwise it takes the plain one's place now.
            if let used = state.signatureInUse, used.isFormatted, !(draft.html ?? "").contains(Self.signatureMark) {
                draft = Self.withFormattedSignature(draft, plain: state.signature, html: used.html,
                                                    pictures: used.pictures ?? [], after: state.sentFrom)
            }
            if let forwarded = state.forwarded { draft = forwarded.appended(to: draft) }
            try await provider(for: account).send(withSenderName(draft, account: account))
            noteSent(draft, account: account)
            learnWriting(from: draft, account: account)
            if let days = state.remindAfterDays { remindIfNoReply(draft, accountID: account.id, after: days) }
            notice = Notice(text: String(localized: "Sent from \(account.label)"))
            return nil
        } catch {
            return error
        }
    }
}

/// A message being written in the composer or the reply bar.
public struct ComposeState: Equatable {
    public var accountID: UUID
    /// The saved draft this message came from, removed once it's sent or saved again.
    public var editedDraft: MailThread?
    /// The signature block added at the start, so it can be told apart from what was written.
    var signature: String?
    /// The signature that block came from, with its formatting and pictures.
    var signatureInUse: NamedSignature?
    /// "Sent from Margin" under the signature ("\n\n" and the line), when it was added.
    var sentFrom: String?
    public var draft: Draft
    public var to: String
    public var cc: String
    public var showsCc: Bool
    /// Hidden recipients: they get the message, nobody sees them.
    public var bcc: String = ""
    public var showsBcc: Bool = false
    /// Days after which to remind if nobody has replied; nil for no reminder.
    public var remindAfterDays: Int?
    /// A forwarded email carried underneath with its formatting; nil once it's made text.
    public var forwarded: ForwardedOriginal?
    /// Started from one message's own Reply: the reply box opens under that message.
    public var answersOneMessage = false

    /// Edit as Text: the forwarded email becomes quoted text in the message, to trim it.
    public mutating func forwardAsText() {
        guard let forwarded else { return }
        draft.text += forwarded.quotedText
        self.forwarded = nil
    }

    public init(account: MailAccount, draft: Draft? = nil, isReply: Bool = false) {
        accountID = account.id
        self.draft = draft ?? Draft(from: account.address)
        to = self.draft.to.map(\.headerValue).joined(separator: ", ")
        cc = self.draft.cc.map(\.headerValue).joined(separator: ", ")
        showsCc = !self.draft.cc.isEmpty
        bcc = self.draft.bcc.map(\.headerValue).joined(separator: ", ")
        showsBcc = !self.draft.bcc.isEmpty
        let chosen = account.signatureChoice(sendingAs: self.draft.from, forReply: isReply)
        signature = Self.block(of: chosen)
        signatureInUse = signature == nil ? nil : chosen
        if self.draft.text.isEmpty, let signature {
            self.draft.text = signature
        }
    }

    /// Switches the sending account, keeping what was written and swapping the signature.
    /// `address` picks one of the account's aliases; the main address when nil.
    public mutating func send(from account: MailAccount, previous: MailAccount? = nil, as address: EmailAddress? = nil) {
        let newAddress = address ?? account.address
        // A send-as address with its own signature brings it along; leaving one puts the
        // mailbox's back.
        let leavingOwn = previous?.hasOwnSignature(draft.from) == true
        if previous?.id != account.id || leavingOwn || account.hasOwnSignature(newAddress) {
            useSignature(account.signatureChoice(sendingAs: newAddress, forReply: false))
        }
        accountID = account.id
        draft.from = newAddress
    }

    /// Swaps the signature at the end of the message, keeping what was written; nil for none.
    public mutating func use(signature text: String?) {
        useSignature(text.map { NamedSignature(name: "", text: $0) })
    }

    /// Swaps in one of the mailbox's signatures, formatting and pictures included; nil for none.
    public mutating func useSignature(_ new: NamedSignature?) {
        // "Sent from Margin" stays last.
        let keepsSentFrom = sentFrom.map { draft.text.hasSuffix($0) } ?? false
        if keepsSentFrom, let sentFrom { draft.text.removeLast(sentFrom.count) }
        if let old = signature, draft.text.hasSuffix(old) { draft.text.removeLast(old.count) }
        signature = Self.block(of: new)
        signatureInUse = signature == nil ? nil : new
        draft.text += signature ?? ""
        if keepsSentFrom, let sentFrom { draft.text += sentFrom }
    }

    /// The block a signature adds. The Mac's editor shows a formatted one as it's sent, pictures
    /// and all, so it gets the text with the pictures' places in it; elsewhere it's the words.
    static func block(of signature: NamedSignature?) -> String? {
        #if os(macOS)
        block(signature?.rich != nil ? signature?.text : signature?.plainText)
        #else
        block(signature?.plainText)
        #endif
    }

    /// Adds "Sent from Margin" under what's there, once.
    mutating func addSentFrom(_ line: String) {
        guard sentFrom == nil, let block = Self.block(line) else { return }
        sentFrom = block
        draft.text += block
    }

    /// Two blank lines for the message, then the signature.
    static func block(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return "\n\n" + text
    }

    /// Worth keeping as a draft: text beyond the signature, an attachment, or a subject on a
    /// new message. A reply with nothing typed isn't.
    public var hasContent: Bool {
        var text = draft.text
        if let sentFrom, text.hasSuffix(sentFrom) { text.removeLast(sentFrom.count) }
        if let signature, text.hasSuffix(signature) { text.removeLast(signature.count) }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty { return true }
        return draft.inReplyTo == nil && !draft.subject.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Words that suggest a file should be attached, in a few common languages.
    static let attachmentWords = ["attached", "attachment", "enclosed", "bijlage", "bijgevoegd", "anbei", "anhang", "angehängt",
                                  "ci-joint", "pièce jointe", "adjunto", "allegato"]

    /// True when the text mentions an attachment but none is attached.
    public var forgotAttachment: Bool {
        guard draft.attachments.isEmpty else { return false }
        let lower = draft.text.lowercased()
        // Quoted text and signatures can mention attachments from earlier mail; check what was written.
        let written = lower.components(separatedBy: "\n>").first ?? lower
        return Self.attachmentWords.contains { written.contains($0) }
    }

    /// The message as it goes out. `includingForward` false leaves the forwarded email off, for
    /// sending, which adds it after the formatted signature is in place.
    func validated(includingForward: Bool = true) throws -> Draft {
        var draft = self.draft
        if includingForward, let forwarded { draft = forwarded.appended(to: draft) }
        guard let to = EmailAddress.parseList(to) else { throw MailError.invalidAddress(self.to) }
        guard let cc = EmailAddress.parseList(cc) else { throw MailError.invalidAddress(self.cc) }
        guard let bcc = EmailAddress.parseList(bcc) else { throw MailError.invalidAddress(self.bcc) }
        guard !(to + cc + bcc).isEmpty else { throw MailError.notSupported(String(localized: "Add at least one recipient.")) }
        draft.to = to
        draft.cc = cc
        draft.bcc = bcc
        return draft
    }
}

extension MailModel {
    /// The formatting tools above the text in the composer and the reply: on until hidden with Aa.
    public var showsFormattingBar: Bool {
        get { _ = contactSettingsRevision; return environment.defaults.object(forKey: "showsFormattingBar") as? Bool ?? true }
        set { environment.defaults.set(newValue, forKey: "showsFormattingBar"); contactSettingsRevision += 1 }
    }

    /// Experimental: hold the space bar to dictate while writing. Off by default.
    public var holdSpaceDictates: Bool {
        get { _ = contactSettingsRevision; return environment.defaults.bool(forKey: "holdSpaceDictates") }
        set { environment.defaults.set(newValue, forKey: "holdSpaceDictates"); contactSettingsRevision += 1 }
    }

}
