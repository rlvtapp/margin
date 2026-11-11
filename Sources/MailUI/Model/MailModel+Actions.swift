import Foundation
import MailCore

/// A Done or Trash waiting out its undo window.
struct PendingChange {
    var action: MailAction
    var threads: [MailThread]
    var task: Task<Void, Never>
    var inboxes: [UUID: [MailThread]]
    var folder: [MailThread]
    var selection: MailThread.ID?
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
        inboxes = pending.inboxes
        folder = pending.folder
        selectedThreadID = pending.selection
        notice = nil
        focusRequest += 1
    }

    /// Changes local state first so the list answers instantly, then tells the server.
    func apply(_ action: MailAction, to threads: [MailThread], announce: Bool) async {
        let ids = Set(threads.map(\.id))
        let leaves: Bool = switch action {
        case .done, .trash: true
        case .move(let target): target != "INBOX"
        default: false
        }
        guard leaves else {
            inboxes = inboxes.mapValues { $0.map { ids.contains($0.id) ? Self.changed($0, by: action) : $0 } }
            folder = folder.map { ids.contains($0.id) ? Self.changed($0, by: action) : $0 }
            if announce, action == .markUnread { notice = Notice(text: String(localized: "Marked unread")) }
            await commit(action, threads)
            return
        }
        await flushPendingChange()
        let snapshot = (inboxes, folder, selectedThreadID)
        let visible = visibleThreads
        if let index = visible.firstIndex(where: { ids.contains($0.id) }), ids.contains(selectedThreadID ?? "") {
            let remaining = visible.filter { !ids.contains($0.id) }
            selectedThreadID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        inboxes = inboxes.mapValues { $0.filter { !ids.contains($0.id) } }
        folder.removeAll { ids.contains($0.id) }
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await self?.commitPending()
        }
        pendingChange = PendingChange(action: action, threads: threads, task: task, inboxes: snapshot.0, folder: snapshot.1, selection: snapshot.2)
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
        await commit(pending.action, pending.threads)
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
            do {
                try await provider(for: account).perform(action, on: group)
            } catch {
                show(error)
                await reload()
            }
        }
    }

    static func changed(_ thread: MailThread, by action: MailAction) -> MailThread {
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
        compose = ComposeState(account: currentAccount)
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
        compose = state
    }

    /// Replies go out from the account the conversation arrived in.
    public func startReply(all: Bool = false) {
        guard let thread = selectedThread, let account = account(thread.accountID) else { return }
        // Mail sent to an alias is answered from that alias.
        reply = ComposeState(account: account, draft: Draft.reply(to: withoutReactions(thread), from: account.replyAddress(for: thread), all: all),
                             isReply: true)
    }

    /// A reply to one message of the open conversation, not necessarily the latest.
    public func startReply(to message: MailMessage, all: Bool = false) {
        guard let thread = selectedThread, let account = account(thread.accountID) else { return }
        reply = ComposeState(account: account,
                             draft: Draft.reply(to: message, in: thread, from: account.replyAddress(for: thread), all: all),
                             isReply: true)
    }

    /// Forwards the latest message, or the one given.
    public func startForward(_ message: MailMessage? = nil) {
        guard let thread = selectedThread, let account = account(thread.accountID) else { return }
        let last = message ?? thread.latest
        let text = body(of: last, in: thread)?.text ?? last.snippet
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        let header = "\n\n---------- Forwarded message ----------\nFrom: \(last.from.headerValue)\nDate: \(last.date.formatted())\nSubject: \(last.subject)\n\n"
        let subject = "Fwd: " + (Subject.isReply(thread.subject) ? String(thread.subject.dropFirst(4)) : thread.subject)
        compose = ComposeState(account: account, draft: Draft(from: account.address, subject: subject, text: header + quoted))
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
            var draft = try state.validated()
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
            // The formatted signature replaces the plain one when the mailbox has one.
            if state.signature != nil, state.signature == ComposeState.signatureBlock(account) {
                draft = Self.withFormattedSignature(draft, plain: state.signature, html: account.signatureHTML)
            }
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
    public var draft: Draft
    public var to: String
    public var cc: String
    public var showsCc: Bool
    /// Hidden recipients: they get the message, nobody sees them.
    public var bcc: String = ""
    public var showsBcc: Bool = false
    /// Days after which to remind if nobody has replied; nil for no reminder.
    public var remindAfterDays: Int?

    public init(account: MailAccount, draft: Draft? = nil, isReply: Bool = false) {
        accountID = account.id
        self.draft = draft ?? Draft(from: account.address)
        to = self.draft.to.map(\.headerValue).joined(separator: ", ")
        cc = self.draft.cc.map(\.headerValue).joined(separator: ", ")
        showsCc = !self.draft.cc.isEmpty
        bcc = self.draft.bcc.map(\.headerValue).joined(separator: ", ")
        showsBcc = !self.draft.bcc.isEmpty
        signature = Self.block(account.signatureText(forReply: isReply))
        if self.draft.text.isEmpty, let signature {
            self.draft.text = signature
        }
    }

    /// Switches the sending account, keeping what was written and swapping the signature.
    /// `address` picks one of the account's aliases; the main address when nil.
    public mutating func send(from account: MailAccount, previous: MailAccount? = nil, as address: EmailAddress? = nil) {
        if previous?.id != account.id { use(signature: account.signature) }
        accountID = account.id
        draft.from = address ?? account.address
    }

    /// Swaps the signature at the end of the message, keeping what was written; nil for none.
    public mutating func use(signature text: String?) {
        if let old = signature, draft.text.hasSuffix(old) { draft.text.removeLast(old.count) }
        signature = Self.block(text)
        draft.text += signature ?? ""
    }

    static func signatureBlock(_ account: MailAccount) -> String? { block(account.signature) }

    /// Two blank lines for the message, then the signature.
    static func block(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return "\n\n" + text
    }

    /// Worth keeping as a draft: text beyond the signature, an attachment, or a subject on a
    /// new message. A reply with nothing typed isn't.
    public var hasContent: Bool {
        var text = draft.text
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

    func validated() throws -> Draft {
        var draft = self.draft
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
    /// Experimental: the full composers use Relevate's block editor, with `/` for blocks and
    /// handles to drag them. Off by default.
    public var usesBlockComposer: Bool {
        get { _ = contactSettingsRevision; return environment.defaults.bool(forKey: "usesBlockComposer") }
        set { environment.defaults.set(newValue, forKey: "usesBlockComposer"); contactSettingsRevision += 1 }
    }

    /// The draft with `document` as its body and `signature` after it: HTML and a plain-text part
    /// that keeps the structure, or just `plain` text when the document has no structure.
    nonisolated static func applying(_ document: MailDocument, plain: String?, to draft: Draft, signature: String) -> Draft {
        var draft = draft
        let signatureText = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard document.hasStructure else {
            draft.html = nil
            draft.text = (plain ?? document.plainText()) + (signatureText.isEmpty ? "" : "\n\n" + signatureText)
            return draft
        }
        var html = document.html()
        if !signatureText.isEmpty {
            let escaped = signatureText.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
            // Same text as the plain signature, so a formatted signature can take its place.
            html = html.replacingOccurrences(of: "\n</div>", with: "\n<p style=\"margin:16px 0 0\">\(escaped)</p>\n</div>")
        }
        draft.html = html
        draft.text = document.plainText() + (signatureText.isEmpty ? "" : "\n\n" + signatureText)
        return draft
    }
}
