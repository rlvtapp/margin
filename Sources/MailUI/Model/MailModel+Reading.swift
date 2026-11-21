import Foundation
import MailCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Things done from the reader: unsubscribing, clearing out a sender, sign-in codes,
/// attachments and signatures.
extension MailModel {
    // MARK: Unsubscribe

    public func unsubscribeMethod(for thread: MailThread) -> Unsubscribe? {
        if let method = thread.messages.reversed().lazy.compactMap({ Unsubscribe.method(from: $0.listHeaders) }).first { return method }
        // No header (plenty of senders leave it out): the link in the newest mail's own text,
        // once that text is here. Looked for once per mail.
        let latest = thread.latest
        guard let account = thread.accountID, let body = bodies[Self.bodyKey(account, latest.id)] else { return nil }
        if let known = unsubscribeLinks[latest.id] { return known }
        // Mail a person wrote only counts a link that says unsubscribe itself.
        let found = Unsubscribe.link(inHTML: body.html ?? "", text: body.text, loose: InboxSplit.classify(latest) != .people)
        if unsubscribeLinks.count > 500 { unsubscribeLinks.removeAll() }
        unsubscribeLinks[latest.id] = .some(found)
        return found
    }

    /// Leaves the list the standard way: a one-click POST, an email, or the sender's page.
    public func unsubscribe(_ thread: MailThread) {
        guard let method = unsubscribeMethod(for: thread) else { return }
        let sender = thread.latest.from.displayName
        // The sample mailboxes have no real lists to leave.
        if environment.isPreview {
            notice = Notice(text: String(localized: "Unsubscribed from \(sender)"))
            return
        }
        switch method {
        case .oneClick(let url):
            Task {
                if await Unsubscribe.confirmOneClick(url) {
                    notice = Notice(text: String(localized: "Unsubscribed from \(sender)"))
                } else {
                    // Not confirmed (refused, sent on to a page, or unreachable): never claim
                    // it worked. Their page is opened so it can be finished there.
                    HTMLWebCoordinator.openInBrowser(url)
                    notice = Notice(text: String(localized: "\(sender) didn't confirm. Their page is open so you can finish there."), isError: true)
                }
            }
        case .mail(let address, let subject):
            guard let account = account(thread.accountID) else { return }
            Task {
                do {
                    try await provider(for: account).send(Draft(from: account.address, to: [address], subject: subject, text: "unsubscribe"))
                    notice = Notice(text: String(localized: "Unsubscribe request sent to \(sender)"))
                } catch {
                    show(error, account: account.id)
                }
            }
        case .web(let url):
            HTMLWebCoordinator.openInBrowser(url)
        }
    }

    /// Conversations in the inbox from the same sender as this one.
    public func threadsFromSameSender(as thread: MailThread) -> [MailThread] {
        let sender = thread.messages.first?.from.address.lowercased()
        return inboxThreads(thread.accountID).filter { $0.messages.first?.from.address.lowercased() == sender }
    }

    /// How many conversations in the inbox the same sender started: asked on every redraw of
    /// the reader, so it's a lookup, not a walk through the mailbox.
    public func countFromSameSender(as thread: MailThread) -> Int {
        guard let account = thread.accountID, let sender = thread.messages.first?.from.address.lowercased() else { return 0 }
        return senderCounts(in: account)[sender] ?? 0
    }

    /// Marks every conversation from this sender done, with Undo.
    public func archiveAll(from thread: MailThread) {
        let threads = threadsFromSameSender(as: thread)
        guard !threads.isEmpty else { return }
        Task { await apply(.done, to: threads, announce: true) }
    }

    // MARK: Sign-in codes

    public func signInCode(in thread: MailThread) -> String? {
        let latest = thread.latest
        guard thread.split != .newsletters else { return nil }
        let body = body(of: latest, in: thread)
        // Asked on every redraw of the reader; the answer only changes when the body arrives.
        let key = Self.bodyKey(thread.accountID, latest.id) + (body == nil ? "|s" : "|b")
        if let known = signInCodes[key] { return known }
        let found = SignInCode.detect(subject: latest.subject, text: body?.text ?? latest.snippet)
        signInCodes[key] = .some(found)
        return found
    }

    /// How long a code shows on its row in the list: codes stop working within minutes, and an
    /// hour-old one in the list is only clutter.
    static let rowCodeWindow: TimeInterval = 60 * 60

    /// The code to show on a conversation's row, while it's new enough to still be wanted.
    public func rowSignInCode(in thread: MailThread, now: Date = Date()) -> String? {
        guard now.timeIntervalSince(thread.latest.date) < Self.rowCodeWindow else { return nil }
        return signInCode(in: thread)
    }

    /// A link in the newest message that signs in or confirms an address.
    public func signInLink(in thread: MailThread) -> (url: URL, kind: SignInLink.Kind)? {
        let latest = thread.latest
        guard thread.split != .newsletters else { return nil }
        let body = body(of: latest, in: thread)
        let key = Self.bodyKey(thread.accountID, latest.id) + (body == nil ? "|s" : "|b")
        if let known = signInLinks[key] { return known.map { ($0.url, $0.kind) } }
        let found = SignInLink.detect(subject: latest.subject, text: body?.text ?? latest.snippet, html: body?.html)
        signInLinks[key] = .some(found.map { FoundLink(url: $0.url, kind: $0.kind) })
        return found
    }

    public func copy(_ text: String, announce: String.LocalizationValue) {
        Self.putOnPasteboard(text)
        notice = Notice(text: String(localized: announce))
    }

    nonisolated static func putOnPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// Copy sign-in codes as soon as they arrive, ready to paste.
    public var copiesSignInCodes: Bool {
        get { environment.defaults.object(forKey: "copiesSignInCodes") as? Bool ?? true }
        set { environment.defaults.set(newValue, forKey: "copiesSignInCodes") }
    }

    // MARK: Attachments

    /// The file on disk (a private temporary folder), fetched from the server when needed.
    public func attachmentFile(_ attachment: AttachmentInfo, of message: MailMessage, in thread: MailThread) async throws -> URL {
        guard let account = account(thread.accountID) else { throw MailError.missingCredentials }
        let data = try await provider(for: account).attachmentData(attachment, of: message)
        let folder = FileManager.default.temporaryDirectory.appending(path: "Margin Attachments", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = AttachmentSafety.safeFilename(attachment.filename)
        let url = folder.appending(path: safeName.isEmpty ? String(localized: "Attachment") : safeName)
        try data.write(to: url, options: .atomic)
        Self.markAsDownloaded(url)
        return url
    }

    /// Marks a file as downloaded from the internet, as a browser does, so macOS checks it
    /// (Gatekeeper) and asks before opening an app or script from it. Done by hand, so it holds
    /// with or without the sandbox.
    nonisolated static func markAsDownloaded(_ url: URL) {
        #if os(macOS)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Margin",
        ]
        var marked = url
        try? marked.setResourceValues(values)
        #endif
    }

    public func openAttachment(_ attachment: AttachmentInfo, of message: MailMessage, in thread: MailThread) {
        Task {
            do {
                let url = try await attachmentFile(attachment, of: message, in: thread)
                #if canImport(AppKit)
                if AttachmentSafety.isRisky(filename: attachment.filename) {
                    // Apps and scripts from mail are never opened straight away: Finder shows
                    // the file, for the person to decide.
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    notice = Notice(text: String(localized: "Margin doesn't open apps or scripts from email. It's shown in Finder."))
                } else {
                    NSWorkspace.shared.open(url)
                }
                #endif
            } catch {
                show(error)
            }
        }
    }

    #if canImport(AppKit)
    public func saveAttachment(_ attachment: AttachmentInfo, of message: MailMessage, in thread: MailThread) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentSafety.safeFilename(attachment.filename)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let url = try await attachmentFile(attachment, of: message, in: thread)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
                Self.markAsDownloaded(destination)
                notice = Notice(text: String(localized: "Saved \(attachment.filename)"))
            } catch {
                show(error)
            }
        }
    }

    /// Saves every file of a message into a folder picked once; names that are taken get a
    /// number, as Finder does.
    public func saveAttachments(_ files: [AttachmentInfo], of message: MailMessage, in thread: MailThread) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            var saved = 0
            for file in files {
                do {
                    let url = try await attachmentFile(file, of: message, in: thread)
                    let destination = Self.freeName(for: AttachmentSafety.safeFilename(file.filename), in: folder)
                    try FileManager.default.copyItem(at: url, to: destination)
                    Self.markAsDownloaded(destination)
                    saved += 1
                } catch {
                    show(error)
                }
            }
            notice = Notice(text: String(localized: "Saved \(saved) files to \(folder.lastPathComponent)"))
        }
    }

    /// "report.pdf", then "report 2.pdf", "report 3.pdf"… for a name already in the folder.
    nonisolated static func freeName(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
    #else
    public func saveAttachments(_ files: [AttachmentInfo], of message: MailMessage, in thread: MailThread) {}

    /// No save panel on iPhone and iPad: open the file, where the share sheet can save it.
    public func saveAttachment(_ attachment: AttachmentInfo, of message: MailMessage, in thread: MailThread) {
        openAttachment(attachment, of: message, in: thread)
    }
    #endif

    // MARK: Invitations

    /// The newest invitation in the conversation, if any.
    public func invite(in thread: MailThread) -> (invite: CalendarInvite, message: MailMessage)? {
        for message in thread.messages.reversed() {
            if let invite = body(of: message, in: thread)?.invite { return (invite, message) }
        }
        return nil
    }

    /// Answers the organizer with an iTIP reply that their calendar understands.
    ///
    /// Sent once per invitation and answer: a tap while an answer is still on its way does
    /// nothing, and the same answer to the same version of the invitation isn't sent again.
    /// The buttons show the answer at once; the notice says when the organizer has been told.
    @discardableResult
    public func respond(to invite: CalendarInvite, in thread: MailThread, with response: CalendarInvite.Response) -> Task<Void, Never>? {
        guard answering[invite.uid] == nil else { return nil }
        answering[invite.uid] = response
        return sendAnswer(to: invite, in: thread, with: response, key: invite.uid)
    }

    /// Sends the reply for an answer already marked in `answering[key]`, and clears the mark
    /// when it's done. Every path that answers by email ends here.
    func sendAnswer(to invite: CalendarInvite, in thread: MailThread, with response: CalendarInvite.Response,
                    key: String) -> Task<Void, Never>? {
        func finish() {
            answering[key] = nil
            answering[invite.uid] = nil
        }
        if let sent = sentAnswers[invite.uid], sent.response == response, sent.sequence >= invite.sequence {
            finish()
            rsvps[invite.uid] = response
            notice = Notice(text: String(localized: "\(response.verb) · already sent for “\(invite.summary)”"), isSent: true)
            return nil
        }
        guard let account = account(thread.accountID), let organizer = invite.organizer else {
            finish()
            notice = Notice(text: String(localized: "This invitation has no organizer to answer."), isError: true)
            return nil
        }
        // Answer as the address that was invited (an alias, say): the organizer's calendar
        // matches the reply to its guest by that address.
        let me = account.sendAddresses.first { address in
            invite.attendees.contains { $0.id == address.address.lowercased() }
        } ?? account.address
        let name = account.address.displayName
        let title = invite.summary
        let (subject, sentence) = switch response {
        case .accepted:
            (String(localized: "Accepted: \(title)"), String(localized: "\(name) accepted this invitation."))
        case .tentative:
            (String(localized: "Tentatively accepted: \(title)"), String(localized: "\(name) tentatively accepted this invitation."))
        case .declined:
            (String(localized: "Declined: \(title)"), String(localized: "\(name) declined this invitation."))
        }
        var draft = Draft(from: me, to: [organizer], subject: subject, text: sentence)
        draft.calendar = invite.reply(from: me, status: response)
        let sending = Notice(text: String(localized: "Sending your answer to \(organizer.displayName)…"))
        notice = sending
        return Task {
            defer { finish() }
            do {
                try await provider(for: account).send(withSenderName(draft, account: account))
                rsvps[invite.uid] = response
                rsvps[key] = response
                sentAnswers[invite.uid] = SentAnswer(response: response, sequence: invite.sequence, at: Date())
                saveSentAnswers()
                noteOwnAnswer(response, as: me, to: invite.uid)
                notice = Notice(text: String(localized: "\(response.verb) · \(organizer.displayName) has been told"), isSent: true)
            } catch {
                if notice?.id == sending.id { notice = nil }
                show(error)
            }
        }
    }

    /// The answer the buttons show: the one being sent, else the one given to this version of
    /// the invitation. After an update (a higher SEQUENCE) an answer sent earlier no longer counts.
    public func answer(to invite: CalendarInvite) -> CalendarInvite.Response? {
        if let sending = answering[invite.uid] { return sending }
        if let sent = sentAnswers[invite.uid], sent.sequence < invite.sequence { return nil }
        return rsvps[invite.uid]
    }

    /// Where your answer to an invitation stands, for the line above its buttons.
    public enum AnswerState: Equatable {
        /// Not answered yet.
        case open
        /// On its way to the organizer.
        case sending(CalendarInvite.Response)
        /// Sent from Margin to this version of the invitation.
        case sent(CalendarInvite.Response)
        /// Known from elsewhere (your calendar, or a reply sent from another app).
        case answered(CalendarInvite.Response)
        /// Answered, then the organizer changed the invitation: it waits for a new answer.
        case changed(CalendarInvite.Response)
    }

    public func answerState(of invite: CalendarInvite) -> AnswerState {
        if let sending = answering[invite.uid] { return .sending(sending) }
        if let sent = sentAnswers[invite.uid] {
            return sent.sequence < invite.sequence ? .changed(sent.response) : .sent(sent.response)
        }
        return rsvps[invite.uid].map(AnswerState.answered) ?? .open
    }

    /// Your answer, kept with the meeting as your entry in its guest list.
    private func noteOwnAnswer(_ response: CalendarInvite.Response, as me: EmailAddress, to uid: String) {
        var entries = calendarEntries
        guard let index = entries.firstIndex(where: { $0.id == uid }) else { return }
        if let at = entries[index].attendees.firstIndex(where: { $0.id == me.address.lowercased() }) {
            guard entries[index].attendees[at].response != response else { return }
            entries[index].attendees[at].response = response
        } else {
            entries[index].attendees.append(MeetingAttendee(address: me, kind: .required, response: response))
        }
        saveCalendar(entries)
    }

    func saveSentAnswers() {
        JSONFile<[String: SentAnswer]>(url: environment.folder.appending(path: "sent-answers.json")).save(sentAnswers)
    }

    /// Hands the invitation to the calendar app.
    public func addToCalendar(_ invite: CalendarInvite) {
        let url = FileManager.default.temporaryDirectory.appending(path: "Margin Invitations", directoryHint: .isDirectory)
            .appending(path: "\(UUID().uuidString).ics")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try invite.raw.write(to: url, atomically: true, encoding: .utf8)
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
        } catch {
            show(error)
        }
    }

    // MARK: Templates

    /// Fills the template in for the first recipient, keeping the signature under it.
    public func insert(_ template: MailTemplate, into state: inout ComposeState) {
        guard let account = account(state.accountID) else { return }
        let recipient = EmailAddress.parseList(state.to)?.first
        let filled = template.filled(to: recipient, from: account.address)
        if state.draft.subject.isEmpty, !filled.subject.isEmpty { state.draft.subject = filled.subject }
        let signature = state.signature ?? ""
        var written = state.draft.text
        if !signature.isEmpty, written.hasSuffix(signature) { written.removeLast(signature.count) }
        let keep = written.trimmingCharacters(in: .whitespacesAndNewlines)
        state.draft.text = (keep.isEmpty ? "" : keep + "\n\n") + filled.body + signature
    }

    /// Inserts into the open reply, or a new message when none is open.
    public func insertTemplate(_ template: MailTemplate) {
        if var state = reply { insert(template, into: &state); reply = state; return }
        if compose == nil { startCompose() }
        if var state = compose { insert(template, into: &state); compose = state }
    }

    public func saveTemplate(from state: ComposeState) {
        var body = state.draft.text
        if let signature = state.signature, body.hasSuffix(signature) { body.removeLast(signature.count) }
        let name = state.draft.subject.isEmpty ? String(localized: "Template \(templates.count + 1)") : state.draft.subject
        templates.append(MailTemplate(name: name, subject: state.draft.inReplyTo == nil ? state.draft.subject : "", body: body.trimmingCharacters(in: .whitespacesAndNewlines)))
        saveTemplates()
        notice = Notice(text: String(localized: "Saved “\(name)” as a template"))
    }

    public func updateTemplate(_ template: MailTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) { templates[index] = template } else { templates.append(template) }
        saveTemplates()
    }

    public func deleteTemplate(_ id: MailTemplate.ID) {
        templates.removeAll { $0.id == id }
        saveTemplates()
    }

    func saveTemplates() {
        JSONFile<[MailTemplate]>(url: environment.folder.appending(path: "templates.json")).save(templates)
    }

    // MARK: Signatures

    /// Saves a mailbox's sender name, aliases and signatures.
    public func update(_ account: MailAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        providers[account.id] = nil
        try? environment.accounts.save(accounts)
    }

    public func setSignature(_ signature: String, for accountID: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        // New words replace the formatted version too, so what's sent matches them.
        accounts[index].setSignature(NamedSignature(name: NamedSignature.defaultName, text: signature))
        try? environment.accounts.save(accounts)
    }
}

/// An answer emailed to an invitation, and the invitation's SEQUENCE it answered.
struct SentAnswer: Codable, Equatable, Sendable {
    var response: CalendarInvite.Response
    var sequence: Int
    /// When it was given, so an older answer read later (a reply in Sent) doesn't undo a newer one.
    var at: Date?
}
