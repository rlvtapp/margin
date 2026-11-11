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
        thread.messages.reversed().lazy.compactMap { Unsubscribe.method(from: $0.listHeaders) }.first
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
                do {
                    let (_, response) = try await URLSession.shared.data(for: Unsubscribe.oneClickRequest(url))
                    let ok = ((response as? HTTPURLResponse)?.statusCode ?? 500) < 400
                    notice = ok
                        ? Notice(text: String(localized: "Unsubscribed from \(sender)"))
                        : Notice(text: String(localized: "\(sender) didn't accept the request."), isError: true)
                } catch {
                    show(error)
                }
            }
        case .mail(let address, let subject):
            guard let account = account(thread.accountID) else { return }
            Task {
                do {
                    try await provider(for: account).send(Draft(from: account.address, to: [address], subject: subject, text: "unsubscribe"))
                    notice = Notice(text: String(localized: "Unsubscribe request sent to \(sender)"))
                } catch {
                    show(error)
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
        let safeName = attachment.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appending(path: safeName.isEmpty ? String(localized: "Attachment") : safeName)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func openAttachment(_ attachment: AttachmentInfo, of message: MailMessage, in thread: MailThread) {
        Task {
            do {
                let url = try await attachmentFile(attachment, of: message, in: thread)
                #if canImport(AppKit)
                NSWorkspace.shared.open(url)
                #endif
            } catch {
                show(error)
            }
        }
    }

    #if canImport(AppKit)
    public func saveAttachment(_ attachment: AttachmentInfo, of message: MailMessage, in thread: MailThread) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let url = try await attachmentFile(attachment, of: message, in: thread)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
                notice = Notice(text: String(localized: "Saved \(attachment.filename)"))
            } catch {
                show(error)
            }
        }
    }
    #else
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
    public func respond(to invite: CalendarInvite, in thread: MailThread, with response: CalendarInvite.Response) {
        guard let account = account(thread.accountID), let organizer = invite.organizer else { return }
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
        var draft = Draft(from: account.address, to: [organizer], subject: subject, text: sentence)
        draft.calendar = invite.reply(from: account.address, status: response)
        Task {
            do {
                try await provider(for: account).send(withSenderName(draft, account: account))
                rsvps[invite.uid] = response
                notice = Notice(text: String(localized: "\(response.verb) · \(organizer.displayName) has been told"))
            } catch {
                show(error)
            }
        }
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
        accounts[index].signature = signature.isEmpty ? nil : signature
        try? environment.accounts.save(accounts)
    }
}
