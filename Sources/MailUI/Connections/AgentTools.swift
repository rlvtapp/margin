import Foundation
import MailCore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// The rest of what AI apps can do through the MCP connection, beyond finding, reading, labelling
/// and moving mail (MailToolbox.swift): the outbox, templates, newsletters, waiting for reply,
/// folders, invitations, attachments, opening things in Margin, settings, and undoing their own
/// last change.
enum AgentTools {
    private static let ids = #""ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."}"#
    private static let mailbox = #""mailbox":{"type":"string","description":"A mailbox name or address from list_mailboxes; the first when left out."}"#
    private static let empty = #"{"type":"object","properties":{},"additionalProperties":false}"#

    static func reading() -> [MCPTool] {
        [
            MCPTool(name: "list_outbox", description: "Lists messages scheduled to send later, with ids for reschedule, cancel_scheduled and send_now.", inputSchema: empty),
            MCPTool(name: "list_templates", description: "Lists saved templates (name, subject, body). Use one with create_draft's template_id.", inputSchema: empty),
            MCPTool(name: "list_newsletters", description: "Lists newsletters with how many issues arrived and how many were opened. rarely_read marks ones worth unsubscribing from.", inputSchema: empty),
            MCPTool(name: "list_waiting", description: "Lists sent conversations still waiting for a reply.", inputSchema: empty),
            MCPTool(name: "read_attachment",
                    description: "Reads an attachment of a conversation: text files and PDFs as text, pictures as pictures with the words in them.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"filename":{"type":"string"}},"required":["id","filename"],"additionalProperties":false}"#),
            MCPTool(name: "open_in_margin",
                    description: "Shows something in Margin's window: a conversation, a view, a folder or a search.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "conversation_id":{"type":"string"},
                      "view":{"type":"string","enum":["inbox","starred","snoozed","waiting","scheduled","subscriptions","sent","drafts","archive"]},
                      "folder":{"type":"string"},\#(mailbox),
                      "search":{"type":"string"}},"additionalProperties":false}
                    """#),
            MCPTool(name: "check_new_mail", description: "Checks every mailbox for new mail now.", inputSchema: empty),
            MCPTool(name: "get_settings", description: "Shows Margin's appearance, layout, Undo Send time, follow-up time and each mailbox's signature.", inputSchema: empty),
        ]
    }

    static func changing() -> [MCPTool] {
        [
            MCPTool(name: "trash", description: "Moves conversations to Trash. They can be brought back with undo_last.",
                    inputSchema: #"{"type":"object","properties":{\#(ids)},"required":["ids"],"additionalProperties":false}"#),
            MCPTool(name: "mark_spam", description: "Moves conversations to Junk.",
                    inputSchema: #"{"type":"object","properties":{\#(ids)},"required":["ids"],"additionalProperties":false}"#),
            MCPTool(name: "list_spam",
                    description: "Lists recent mail in Junk by sender and subject only (never the contents), so mail caught by mistake can be taken out with not_spam.",
                    inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
            MCPTool(name: "not_spam", description: "Takes conversations out of Junk and back to the inbox.",
                    inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":50,"description":"Ids from list_spam."}},"required":["ids"],"additionalProperties":false}"#),
            MCPTool(name: "stop_waiting", description: "Stops tracking sent conversations as waiting for a reply.",
                    inputSchema: #"{"type":"object","properties":{\#(ids)},"required":["ids"],"additionalProperties":false}"#),
            MCPTool(name: "unsubscribe",
                    description: "Leaves a newsletter the way it asks (a link or an email), archives its issues in the inbox and stops suggesting it. Can't be undone.",
                    inputSchema: #"{"type":"object","properties":{"newsletter":{"type":"string","description":"An id from list_newsletters."}},"required":["newsletter"],"additionalProperties":false}"#),
            MCPTool(name: "archive_newsletter", description: "Archives every issue of a newsletter that's in the inbox.",
                    inputSchema: #"{"type":"object","properties":{"newsletter":{"type":"string"}},"required":["newsletter"],"additionalProperties":false}"#),
            MCPTool(name: "create_folder", description: "Makes a new folder in a mailbox. Use a/b for a folder inside another.",
                    inputSchema: #"{"type":"object","properties":{"name":{"type":"string"},\#(mailbox)},"required":["name"],"additionalProperties":false}"#),
            MCPTool(name: "rename_folder", description: "Renames one of the person's own folders.",
                    inputSchema: #"{"type":"object","properties":{"folder":{"type":"string"},"new_name":{"type":"string"},\#(mailbox)},"required":["folder","new_name"],"additionalProperties":false}"#),
            MCPTool(name: "delete_folder", description: "Deletes one of the person's own folders. Only empty folders can be deleted, so no mail is lost.",
                    inputSchema: #"{"type":"object","properties":{"folder":{"type":"string"},\#(mailbox)},"required":["folder"],"additionalProperties":false}"#),
            MCPTool(name: "hide_folder", description: "Hides a folder from Margin's sidebar, or shows it again. The folder and its mail stay.",
                    inputSchema: #"{"type":"object","properties":{"folder":{"type":"string"},"hidden":{"type":"boolean"},\#(mailbox)},"required":["folder","hidden"],"additionalProperties":false}"#),
            MCPTool(name: "save_template", description: "Saves a new template. Use {first_name} or {name} for the recipient.",
                    inputSchema: #"{"type":"object","properties":{"name":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"}},"required":["name","body"],"additionalProperties":false}"#),
            MCPTool(name: "update_template", description: "Changes a saved template.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "delete_template", description: "Deletes a saved template.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "reschedule", description: "Changes when a scheduled message sends (ISO 8601).",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"send_at":{"type":"string"}},"required":["id","send_at"],"additionalProperties":false}"#),
            MCPTool(name: "cancel_scheduled", description: "Cancels a scheduled message so it isn't sent.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "add_to_calendar", description: "Adds the invitation in a conversation to the person's calendar.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "undo_last",
                    description: "Undoes the last change made through this connection (never one the person made). Sending, unsubscribing and answering invitations can't be undone.",
                    inputSchema: empty),
        ]
    }

    static func sending() -> [MCPTool] {
        [
            MCPTool(name: "send_now", description: "Sends a scheduled message right away.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "respond_to_invite", description: "Answers the invitation in a conversation; the organizer is told by email.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"response":{"type":"string","enum":["accept","maybe","decline"]}},"required":["id","response"],"additionalProperties":false}"#),
        ]
    }

    static func settings() -> [MCPTool] {
        [
            MCPTool(name: "change_settings", description: "Changes Margin's appearance, list layout, Undo Send time, follow-up time, new-mail sound or swipes.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "appearance":{"type":"string","enum":["system","light","dark","white","developer"]},
                      "layout":{"type":"string","enum":["panels","wide"]},
                      "undo_send_seconds":{"type":"integer","enum":[0,5,10,20,30]},
                      "follow_up_days":{"type":"integer","minimum":1,"maximum":30},
                      "sound":{"type":"string","description":"A new-mail sound by name (see get_settings), or none."},
                      "swipe_right":{"type":"string","enum":["done","star","read","snooze","trash","none"]},
                      "swipe_left":{"type":"string","enum":["done","star","read","snooze","trash","none"]}},"additionalProperties":false}
                    """#),
            MCPTool(name: "set_signature", description: "Sets a mailbox's default signature. Empty removes it.",
                    inputSchema: #"{"type":"object","properties":{"text":{"type":"string"},\#(mailbox)},"required":["text"],"additionalProperties":false}"#),
        ]
    }
}

/// One change an AI app made, with what's needed to put it back.
enum AgentChange {
    case labels([String: [String]])
    case snoozes([String: Date])
    case flags([(thread: MailThread, back: MailAction)])
    case moves([MovedConversation])
    case templates([MailTemplate])
    case outbox([ScheduledMessage])
    case waiting(Set<String>)
    case createdFolder(accountID: UUID, name: String)
    case renamedFolder(accountID: UUID, from: String, to: String)
    case deletedFolder(accountID: UUID, name: String)
    case hiddenFolder(accountID: UUID, mailbox: Mailbox, wasHidden: Bool)
    case settings(appearance: AppAppearance, layout: ListLayout, undoSend: Int, followUp: Int,
                  sound: AlertSound, leading: [SwipeAction], trailing: [SwipeAction])
    case signature(accountID: UUID, previous: String?)
}

/// A conversation moved out of where it was. After an IMAP move its messages have new ids,
/// so it's found again by Message-ID in the folder it went to.
struct MovedConversation {
    var accountID: UUID
    var messageIDs: Set<String>
    var to: Mailbox
    /// Where it came from; nil for the inbox.
    var back: Mailbox?
}

extension MailModel {
    // MARK: Recording

    func record(_ change: AgentChange) {
        agentChanges.append(change)
        if agentChanges.count > 20 { agentChanges.removeFirst(agentChanges.count - 20) }
    }

    func recordLabels() { record(.labels(labelStore.labelsByThread)) }
    func recordSnoozes() { record(.snoozes(snoozes)) }

    /// Remembers how to undo read or star changes, per conversation.
    func recordFlags(_ threads: [MailThread], read: Bool?, starred: Bool?) {
        record(.flags(threads.map { thread in
            if read != nil { return (thread, thread.isUnread ? .markUnread : .markRead) }
            return (thread, thread.isStarred ? .star : .unstar)
        }))
    }

    /// Remembers where conversations were before `action` moves them.
    func recordMoves(_ threads: [MailThread], _ action: MailAction) {
        let moves = threads.compactMap { thread -> MovedConversation? in
            guard let accountID = thread.accountID, let to = destination(of: action, accountID: accountID) else { return nil }
            return MovedConversation(accountID: accountID, messageIDs: Set(thread.messages.compactMap(\.messageID)), to: to, back: origin(of: thread))
        }
        if !moves.isEmpty { record(.moves(moves)) }
    }

    private func destination(of action: MailAction, accountID: UUID) -> Mailbox? {
        let boxes = mailboxes[accountID] ?? []
        switch action {
        case .done: return boxes.first { $0.role == .archive } ?? boxes.first { $0.role == .all }
        case .trash: return boxes.first { $0.role == .trash }
        case .move(let id): return boxes.first { $0.id == id }
        default: return nil
        }
    }

    private func origin(of thread: MailThread) -> Mailbox? {
        if inboxThreads(nil).contains(where: { $0.id == thread.id }) { return nil }
        switch place {
        case .mailbox(_, let mailbox): return mailbox
        case .combined(let role): return thread.accountID.flatMap { combinedMailbox(role, of: $0) }
        default: return nil
        }
    }

    // MARK: Undo

    func undoLastAgentChange() async throws -> String {
        guard let change = agentChanges.popLast() else { throw MCPToolError("There's nothing to undo from this connection.") }
        switch change {
        case .labels(let snapshot):
            labelStore.restore(snapshot)
            return "Labels are back as they were."
        case .snoozes(let snapshot):
            snoozes = snapshot
            saveSnoozes()
            return "Snoozes are back as they were."
        case .flags(let items):
            for (back, group) in Dictionary(grouping: items, by: { $0.back }) {
                await apply(back, to: group.map(\.thread), announce: false)
            }
            return "Changed back."
        case .moves(let moves):
            await flushPendingChange()
            var missing = 0
            for move in moves {
                guard let account = account(move.accountID), let provider = try? provider(for: account) else { missing += 1; continue }
                let found = ((try? await provider.threads(in: move.to, limit: 300)) ?? []).map { Self.tag($0, account: move.accountID) }
                let matches = found.filter { thread in thread.messages.contains { $0.messageID.map(move.messageIDs.contains) ?? false } }
                guard !matches.isEmpty else { missing += 1; continue }
                await apply(move.back.map { .move(toMailboxID: $0.id) } ?? .moveToInbox, to: matches, announce: false)
                await flushPendingChange()
            }
            await reload()
            return missing == 0 ? "Moved back." : "Moved back, except \(Self.count(missing)) that couldn't be found anymore."
        case .templates(let snapshot):
            templates = snapshot
            saveTemplates()
            return "Templates are back as they were."
        case .outbox(let snapshot):
            outbox = snapshot
            saveOutbox()
            return "Scheduled messages are back as they were."
        case .waiting(let snapshot):
            dismissedWaitingKeys = snapshot
            return "Waiting for reply is back as it was."
        case .createdFolder(let accountID, let name):
            guard let mailbox = folders(of: accountID).first(where: { $0.name == name }) else { throw MCPToolError("The new folder isn't there anymore.") }
            deleteFolder(mailbox, in: accountID)
            return "Removed the folder “\(name)” again."
        case .renamedFolder(let accountID, let from, let to):
            guard let mailbox = folders(of: accountID).first(where: { $0.name == to }) else { throw MCPToolError("The folder “\(to)” isn't there anymore.") }
            renameFolder(mailbox, in: accountID, to: from)
            return "Renamed it back to “\(from)”."
        case .deletedFolder(let accountID, let name):
            createFolder(named: name, in: accountID)
            return "Made the folder “\(name)” again."
        case .hiddenFolder(let accountID, let mailbox, let wasHidden):
            setHidden(wasHidden, mailbox, in: accountID)
            return wasHidden ? "Hidden again." : "Shown again."
        case .settings(let appearance, let layout, let undoSend, let followUp, let sound, let leading, let trailing):
            self.appearance = appearance
            self.layout = layout
            undoSendDelay = undoSend
            followUpDays = followUp
            environment.defaults.set(sound.name, forKey: "alertSound")
            alertRevision += 1
            leadingSwipes = leading
            trailingSwipes = trailing
            return "Settings are back as they were."
        case .signature(let accountID, let previous):
            setSignature(previous ?? "", for: accountID)
            return "The signature is back as it was."
        }
    }

    // MARK: Running the tools

    /// Runs a tool from AgentTools, or returns nil when `name` isn't one of them.
    func runAgentTool(_ name: String, _ arguments: [String: MCPValue]) async throws -> String? {
        switch name {
        case "list_outbox":
            return json(outbox.map { item -> [String: Any] in
                [
                    "id": item.id.uuidString, "mailbox": account(item.accountID)?.label ?? "",
                    "to": item.draft.to.map(\.headerValue).joined(separator: ", "), "subject": item.draft.subject,
                    "send_at": ISO8601DateFormatter().string(from: item.sendAt),
                ]
            })
        case "list_templates":
            return json(templates.map { ["id": $0.id.uuidString, "name": $0.name, "subject": $0.subject, "body": $0.body] })
        case "list_newsletters":
            if newsletterHistory.isEmpty { await refreshNewsletterHistory() }
            loadNewsletterStateIfNeeded()
            return json(newsletterSenders.filter { sender in isVisible(sender.latest) }.map { sender -> [String: Any] in
                [
                    "id": sender.id, "name": sender.name, "address": sender.address, "received": sender.received,
                    "opened": sender.opened, "rarely_read": sender.isRarelyRead,
                    "last_received": ISO8601DateFormatter().string(from: sender.lastReceived),
                ]
            })
        case "list_waiting":
            return json(await waitingThreads(nil).filter(isVisible).map(summaryJSON))
        case "read_attachment":
            return try await readAttachment(arguments)
        case "open_in_margin":
            return try await openInMargin(arguments)
        case "check_new_mail":
            return await checkForNewMail() ? "New mail arrived." : "No new mail."
        case "get_settings":
            return json([
                "appearance": appearance.rawValue, "layout": layout.rawValue,
                "undo_send_seconds": undoSendDelay, "follow_up_days": followUpDays,
                "sound": alertSound.name, "sounds": AlertSound.choices.map(\.name),
                "swipe_right": leadingSwipes.first?.rawValue ?? "none", "swipe_left": trailingSwipes.first?.rawValue ?? "none",
                "signatures": visibleAccounts.map { ["mailbox": $0.label, "signature": $0.signature ?? ""] },
            ] as [String: Any])

        case "trash", "mark_spam":
            let threads = try await toolThreads(arguments)
            let action: MailAction
            if name == "trash" {
                action = .trash
            } else {
                // Every conversation must have a Junk folder in its own mailbox.
                guard let accountID = threads.first?.accountID,
                      let junk = mailboxes[accountID]?.first(where: { $0.role == .junk }),
                      threads.allSatisfy({ $0.accountID == accountID }) else {
                    throw MCPToolError("Mark spam one mailbox at a time, in a mailbox with a Junk folder.")
                }
                action = .move(toMailboxID: junk.id)
            }
            recordMoves(threads, action)
            await apply(action, to: threads, announce: false)
            await flushPendingChange()
            return name == "trash" ? "Moved \(Self.count(threads)) to Trash." : "Moved \(Self.count(threads)) to Junk."
        case "list_spam":
            var found: [MailThread] = []
            for account in visibleAccounts {
                guard let junk = mailboxes[account.id]?.first(where: { $0.role == .junk }), let provider = try? provider(for: account) else { continue }
                let threads = ((try? await provider.threads(in: junk, limit: 50)) ?? []).map { Self.tag($0, account: account.id) }
                found += threads
            }
            agentJunk = found
            // Senders and subjects only: what's inside Junk never goes to AI apps.
            return json(found.sorted { $0.date > $1.date }.map { thread -> [String: Any] in
                ["id": thread.id, "mailbox": account(thread.accountID)?.label ?? "", "from": thread.latest.from.headerValue,
                 "subject": thread.subject, "date": ISO8601DateFormatter().string(from: thread.date)]
            })
        case "not_spam":
            guard case .array(let values)? = arguments["ids"] else { throw MCPToolError("“ids” is needed: ids from list_spam.") }
            let ids = Set(values.compactMap(\.string))
            let threads = agentJunk.filter { ids.contains($0.id) }
            guard threads.count == ids.count, !threads.isEmpty else { throw MCPToolError("Some of those aren't in Junk. Use list_spam first.") }
            await apply(.moveToInbox, to: threads, announce: false)
            agentJunk.removeAll { ids.contains($0.id) }
            await reload()
            return "Moved \(Self.count(threads)) back to the inbox."
        case "stop_waiting":
            let threads = try await toolThreads(arguments)
            record(.waiting(dismissedWaitingKeys))
            dismissedWaitingKeys.formUnion(threads.map(LabelStore.key(for:)))
            return "No longer waiting on \(Self.count(threads))."
        case "unsubscribe", "archive_newsletter":
            if newsletterHistory.isEmpty { await refreshNewsletterHistory() }
            guard let id = arguments["newsletter"]?.string, let sender = newsletterSenders.first(where: { $0.id == id }), isVisible(sender.latest) else {
                throw MCPToolError("No newsletter with that id. Use list_newsletters.")
            }
            if name == "unsubscribe" {
                unsubscribe(from: sender)
                return "Unsubscribed from \(sender.name) and archived its issues in the inbox."
            }
            let issues = inboxThreads(nil).filter { thread in
                thread.messages.contains { $0.from.address.caseInsensitiveCompare(sender.address) == .orderedSame }
            }
            guard !issues.isEmpty else { return "No issues of \(sender.name) are in the inbox." }
            recordMoves(issues, .done)
            await apply(.done, to: issues, announce: false)
            await flushPendingChange()
            return "Archived \(Self.count(issues)) from \(sender.name)."
        case "create_folder":
            let account = try toolAccount(arguments)
            let name = try Self.folderName(arguments["name"]?.string)
            guard !folders(of: account.id).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw MCPToolError("“\(name)” already exists in \(account.label).")
            }
            createFolder(named: name, in: account.id)
            record(.createdFolder(accountID: account.id, name: name))
            return "Making “\(name)” in \(account.label)."
        case "rename_folder":
            let account = try toolAccount(arguments)
            let mailbox = try ownFolder(arguments["folder"]?.string, in: account)
            let name = try Self.folderName(arguments["new_name"]?.string)
            renameFolder(mailbox, in: account.id, to: name)
            record(.renamedFolder(accountID: account.id, from: mailbox.name, to: name))
            return "Renaming “\(mailbox.name)” to “\(name)”."
        case "delete_folder":
            let account = try toolAccount(arguments)
            let mailbox = try ownFolder(arguments["folder"]?.string, in: account)
            let inside = (try? await provider(for: account).threads(in: mailbox, limit: 1)) ?? [MailThread]()
            guard inside.isEmpty else { throw MCPToolError("“\(mailbox.name)” still has mail in it. Move it out first; only empty folders can be deleted.") }
            deleteFolder(mailbox, in: account.id)
            record(.deletedFolder(accountID: account.id, name: mailbox.name))
            return "Deleting the empty folder “\(mailbox.name)”."
        case "hide_folder":
            let account = try toolAccount(arguments)
            let mailbox = try ownFolder(arguments["folder"]?.string, in: account)
            let hidden = arguments["hidden"]?.bool ?? true
            record(.hiddenFolder(accountID: account.id, mailbox: mailbox, wasHidden: isHidden(mailbox, in: account.id)))
            setHidden(hidden, mailbox, in: account.id)
            return hidden ? "“\(mailbox.name)” is hidden from the sidebar." : "“\(mailbox.name)” shows in the sidebar again."
        case "save_template":
            guard let name = arguments["name"]?.string, !name.isEmpty, let body = arguments["body"]?.string else { throw MCPToolError("A name and a body are needed.") }
            record(.templates(templates))
            templates.append(MailTemplate(name: name, subject: arguments["subject"]?.string ?? "", body: body))
            saveTemplates()
            return "Saved the template “\(name)”."
        case "update_template":
            guard var template = templates.first(where: { $0.id.uuidString == arguments["id"]?.string }) else { throw MCPToolError("No template with that id. Use list_templates.") }
            record(.templates(templates))
            if let name = arguments["name"]?.string, !name.isEmpty { template.name = name }
            if let subject = arguments["subject"]?.string { template.subject = subject }
            if let body = arguments["body"]?.string { template.body = body }
            updateTemplate(template)
            return "Updated “\(template.name)”."
        case "delete_template":
            guard let template = templates.first(where: { $0.id.uuidString == arguments["id"]?.string }) else { throw MCPToolError("No template with that id. Use list_templates.") }
            record(.templates(templates))
            deleteTemplate(template.id)
            return "Deleted “\(template.name)”."
        case "reschedule":
            let item = try scheduled(arguments)
            guard let text = arguments["send_at"]?.string, let date = ISO8601DateFormatter().date(from: text) ?? Self.looseDate(text), date > Date() else {
                throw MCPToolError("“send_at” must be a future ISO 8601 date and time.")
            }
            record(.outbox(outbox))
            if let index = outbox.firstIndex(where: { $0.id == item.id }) { outbox[index].sendAt = date }
            outbox.sort { $0.sendAt < $1.sendAt }
            saveOutbox()
            return "It now sends \(date.formatted())."
        case "cancel_scheduled":
            let item = try scheduled(arguments)
            record(.outbox(outbox))
            cancelScheduled(item.id)
            return "Cancelled “\(item.draft.subject)”. It won't be sent."
        case "add_to_calendar":
            let found = try await toolInvite(arguments)
            addToCalendar(found.invite)
            return "Opened “\(found.invite.summary)” in Calendar to add."
        case "undo_last":
            return try await undoLastAgentChange()

        case "send_now":
            let item = try scheduled(arguments)
            sendScheduledNow(item.id)
            return "Sending “\(item.draft.subject)” now."
        case "respond_to_invite":
            let found = try await toolInvite(arguments)
            let response: CalendarInvite.Response = switch arguments["response"]?.string {
            case "accept": .accepted
            case "maybe": .tentative
            case "decline": .declined
            default: throw MCPToolError("“response” must be accept, maybe or decline.")
            }
            guard found.invite.organizer != nil else { throw MCPToolError("This invitation has no organizer to answer.") }
            respond(to: found.invite, in: found.thread, with: response)
            return "\(response.verb) “\(found.invite.summary)”. The organizer is being told."

        case "change_settings":
            // Check everything first, so a refused change leaves nothing behind.
            let newAppearance = try arguments["appearance"]?.string.map { text in
                guard let value = AppAppearance(rawValue: text) else { throw MCPToolError("appearance is system, light, dark, white or developer.") }
                return value
            }
            let newLayout = try arguments["layout"]?.string.map { text in
                guard let value = ListLayout(rawValue: text) else { throw MCPToolError("layout is panels or wide.") }
                return value
            }
            let seconds = arguments["undo_send_seconds"]?.int
            if let seconds, ![0, 5, 10, 20, 30].contains(seconds) { throw MCPToolError("undo_send_seconds is 0, 5, 10, 20 or 30.") }
            let days = arguments["follow_up_days"]?.int
            if let days, !(1...30).contains(days) { throw MCPToolError("follow_up_days is 1 to 30.") }
            let sound = try arguments["sound"]?.string.map { name in
                guard let found = AlertSound.choices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw MCPToolError("No sound called “\(name)”. get_settings lists them.")
                }
                return found
            }
            let right = try arguments["swipe_right"]?.string.map { text in
                guard let value = SwipeAction(rawValue: text) else { throw MCPToolError("swipe_right is done, star, read, snooze, trash or none.") }
                return value
            }
            let left = try arguments["swipe_left"]?.string.map { text in
                guard let value = SwipeAction(rawValue: text) else { throw MCPToolError("swipe_left is done, star, read, snooze, trash or none.") }
                return value
            }
            guard newAppearance != nil || newLayout != nil || seconds != nil || days != nil || sound != nil || right != nil || left != nil else {
                throw MCPToolError("Nothing to change.")
            }

            record(.settings(appearance: appearance, layout: layout, undoSend: undoSendDelay, followUp: followUpDays,
                             sound: alertSound, leading: leadingSwipes, trailing: trailingSwipes))
            var changed: [String] = []
            if let newAppearance { appearance = newAppearance; changed.append("appearance") }
            if let newLayout { layout = newLayout; changed.append("layout") }
            if let seconds { undoSendDelay = seconds; changed.append("Undo Send") }
            if let days { followUpDays = days; changed.append("follow-up time") }
            if let sound { alertSound = sound; changed.append("sound") }
            if let right { leadingSwipes = [right] + leadingSwipes.dropFirst(); changed.append("swipe right") }
            if let left { trailingSwipes = [left] + trailingSwipes.dropFirst(); changed.append("swipe left") }
            return "Changed \(changed.joined(separator: ", "))."
        case "set_signature":
            let account = try toolAccount(arguments)
            record(.signature(accountID: account.id, previous: account.signature))
            setSignature(arguments["text"]?.string ?? "", for: account.id)
            return "Updated the signature for \(account.label)."
        default:
            return nil
        }
    }

    // MARK: Helpers

    private func toolAccount(_ arguments: [String: MCPValue]) throws -> MailAccount {
        if let text = arguments["mailbox"]?.string {
            guard let account = matchAccount(text) else { throw MCPToolError("No mailbox by that name. Use list_mailboxes.") }
            return account
        }
        guard let first = visibleAccounts.first else { throw MCPToolError("No mailboxes are shared with AI apps.") }
        return first
    }

    private func ownFolder(_ name: String?, in account: MailAccount) throws -> Mailbox {
        let wanted = (name ?? "").lowercased()
        guard let mailbox = ownFolders(of: account.id, includingHidden: true).map(\.mailbox).first(where: { $0.name.lowercased() == wanted }) else {
            throw MCPToolError("No folder of yours called “\(name ?? "")” in \(account.label). Use list_folders.")
        }
        return mailbox
    }

    private static func folderName(_ text: String?) throws -> String {
        let name = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw MCPToolError("A folder name is needed.") }
        return name
    }

    private func scheduled(_ arguments: [String: MCPValue]) throws -> ScheduledMessage {
        guard let item = outbox.first(where: { $0.id.uuidString == arguments["id"]?.string }), visibleAccounts.contains(where: { $0.id == item.accountID }) else {
            throw MCPToolError("No scheduled message with that id. Use list_outbox.")
        }
        return item
    }

    private func toolInvite(_ arguments: [String: MCPValue]) async throws -> (invite: CalendarInvite, thread: MailThread) {
        let thread = try await toolThread(arguments["id"]?.string)
        await loadAllBodies(of: thread)
        guard let found = invite(in: thread) else { throw MCPToolError("There's no invitation in this conversation.") }
        return (found.invite, thread)
    }

    private func readAttachment(_ arguments: [String: MCPValue]) async throws -> String {
        let thread = try await toolThread(arguments["id"]?.string)
        await loadAllBodies(of: thread)
        let wanted = arguments["filename"]?.string ?? ""
        for message in thread.messages {
            guard let attachment = body(of: message, in: thread)?.attachments.first(where: { $0.filename == wanted }) else { continue }
            let url = try await attachmentFile(attachment, of: message, in: thread)
            let type = attachment.mimeType.lowercased()
            var text: String?
            if type.hasPrefix("text/") || type.contains("json") || type.contains("csv") || type.contains("xml") {
                text = try? String(contentsOf: url, encoding: .utf8)
            } else if type == "application/pdf" || wanted.lowercased().hasSuffix(".pdf") {
                #if canImport(PDFKit)
                text = PDFDocument(url: url)?.string
                #endif
            }
            guard var text, !text.isEmpty else {
                throw MCPToolError("“\(wanted)” (\(attachment.mimeType)) can't be read as text.")
            }
            if let code = signInCode(in: thread) { text = Self.hidingCode(code, in: text) }
            return String(text.prefix(50_000))
        }
        throw MCPToolError("No attachment called “\(wanted)” in this conversation. read_conversation lists them.")
    }

    private func openInMargin(_ arguments: [String: MCPValue]) async throws -> String {
        let account = try arguments["mailbox"]?.string.map { text -> MailAccount in
            guard let account = matchAccount(text) else { throw MCPToolError("No mailbox by that name. Use list_mailboxes.") }
            return account
        }
        if let id = arguments["conversation_id"]?.string {
            let thread = try await toolThread(id)
            if !visibleThreads.contains(where: { $0.id == thread.id }), inboxThreads(nil).contains(where: { $0.id == thread.id }) {
                go(to: .allInboxes)
            }
            selectedThreadID = thread.id
        } else if let text = arguments["search"]?.string, !text.isEmpty {
            runSearch(text)
        } else if let name = arguments["folder"]?.string {
            let owner = try account ?? toolAccount([:])
            guard let mailbox = folders(of: owner.id).first(where: { $0.name.lowercased() == name.lowercased() && $0.role != .junk && $0.role != .trash }) else {
                throw MCPToolError("No folder “\(name)” in \(owner.label). Use list_folders.")
            }
            go(to: .mailbox(account: owner.id, mailbox))
        } else if let view = arguments["view"]?.string {
            switch view {
            case "inbox": go(to: .inbox(account: account?.id, split: nil))
            case "starred": go(to: .starred(account: account?.id))
            case "snoozed": go(to: .snoozed(account: account?.id))
            case "waiting": go(to: .waiting(account: account?.id))
            case "scheduled": go(to: .scheduled)
            case "subscriptions": go(to: .subscriptions)
            case "sent": go(to: .combined(.sent))
            case "drafts": go(to: .combined(.drafts))
            case "archive": go(to: .combined(.archive))
            default: throw MCPToolError("Unknown view “\(view)”.")
            }
        } else {
            throw MCPToolError("Say what to open: conversation_id, view, folder or search.")
        }
        #if canImport(AppKit)
        NSApplication.shared.activate()
        #endif
        return "Open in Margin."
    }
}

extension MailModel {
    /// An image attachment, made small enough to send to an AI app, and the words read from it.
    func attachmentPicture(_ arguments: [String: MCPValue]) async throws -> (data: Data, mimeType: String, words: String)? {
        let thread = try await toolThread(arguments["id"]?.string)
        await loadAllBodies(of: thread)
        let wanted = arguments["filename"]?.string ?? ""
        for message in thread.messages {
            guard let attachment = body(of: message, in: thread)?.attachments.first(where: { $0.filename == wanted }),
                  attachment.mimeType.lowercased().hasPrefix("image/") else { continue }
            // A picture can show a sign-in code, and those never go to AI apps.
            guard signInCode(in: thread) == nil else { throw MCPToolError("This conversation has a sign-in code, so its pictures aren't shared.") }
            let url = try await attachmentFile(attachment, of: message, in: thread)
            guard let original = try? Data(contentsOf: url), let small = ImageResizer.resized(original, maxPixels: 1568, asJPEG: true) else { return nil }
            var words = await AskAttachment.recognizeText(url) ?? ""
            if let code = signInCode(in: thread) { words = Self.hidingCode(code, in: words) }
            return (small, "image/jpeg", words)
        }
        return nil
    }
}
