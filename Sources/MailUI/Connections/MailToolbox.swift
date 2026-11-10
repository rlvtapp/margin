import Foundation
import MailCore
#if canImport(AppKit)
import AppKit
#endif

/// What AI apps may do through the MCP connection. Reading is always on while the connection
/// is; changing and sending each need their own switch in Settings. Junk and Trash are never shown.
public struct ConnectionSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var allowChanges = false
    public var allowSending = false
    /// Appearance, layout, Undo Send, follow-up time and signatures.
    public var allowSettings = false
    public var port: UInt16 = 47_901
    /// Mailboxes AI apps can't see at all.
    public var hiddenAccounts: [UUID] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        allowChanges = try values.decodeIfPresent(Bool.self, forKey: .allowChanges) ?? false
        allowSending = try values.decodeIfPresent(Bool.self, forKey: .allowSending) ?? false
        allowSettings = try values.decodeIfPresent(Bool.self, forKey: .allowSettings) ?? false
        port = try values.decodeIfPresent(UInt16.self, forKey: .port) ?? 47_901
        hiddenAccounts = try values.decodeIfPresent([UUID].self, forKey: .hiddenAccounts) ?? []
    }
}

public struct MCPActivity: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var date: Date
    public var tool: String
}

struct MailToolbox: MCPToolbox {
    let model: MailModel

    func tools() async -> [MCPTool] {
        let settings = await model.connectionSettings
        var tools = [
            MCPTool(name: "list_mailboxes", description: "Lists the person's mailboxes (accounts) with their unread counts.",
                    inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
            MCPTool(name: "search_mail",
                    description: "Finds email conversations. Supports words and operators like from:, to:, subject:, is:unread, is:starred, has:attachment. Returns ids for read_conversation, the total that matched, and next_offset when there are more (pass it as offset). To sort the inbox, use list_to_sort instead.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "query":{"type":"string","description":"Words and operators; empty lists the newest."},
                      "folder":{"type":"string","enum":["inbox","sent","archive","drafts"],"description":"Defaults to inbox."},
                      "mailbox":{"type":"string","description":"A mailbox name or address from list_mailboxes; all mailboxes when left out."},
                      "limit":{"type":"integer","minimum":1,"maximum":100,"description":"Defaults to 20."},
                      "offset":{"type":"integer","minimum":0,"description":"Skip this many, for the next page."}},"additionalProperties":false}
                    """#),
            MCPTool(name: "list_folders", description: "Lists each mailbox's folders, for search_mail and move_to_folder.",
                    inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
            MCPTool(name: "read_conversation", description: "Reads a whole conversation as plain text, oldest message first.",
                    inputSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
            MCPTool(name: "create_draft",
                    description: "Opens a new message in Margin for the person to review and send themselves. Use reply_to_id to answer a conversation.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "to":{"type":"string"},"cc":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"},
                      "reply_to_id":{"type":"string","description":"A conversation id to reply to."},
                      "template_id":{"type":"string","description":"A template from list_templates to start from."},
                      "attachments":{"type":"array","maxItems":10,"items":{"type":"object","properties":{"filename":{"type":"string"},"content_base64":{"type":"string"},"mime_type":{"type":"string"}},"required":["filename","content_base64"]}},
                      "from":{"type":"string","description":"A mailbox or one of its send-as addresses."}},
                     "required":[],"additionalProperties":false}
                    """#),
            MCPTool(name: "list_labels", description: "Lists the labels in use in Margin, with how many conversations carry each. Reuse these names rather than inventing near-duplicates.",
                    inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
            MCPTool(name: "get_selection",
                    description: "The conversations the person has open or selected in Margin right now, for requests like \"label this\" or \"archive these\".",
                    inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
        ] + AgentTools.reading()
        if settings.allowChanges {
            tools += [
                MCPTool(name: "archive", description: "Marks conversations done: moves them out of the inbox to the archive.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."}},"required":["ids"],"additionalProperties":false}"#),
                MCPTool(name: "set_read", description: "Marks conversations read or unread.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."},"read":{"type":"boolean"}},"required":["ids","read"],"additionalProperties":false}"#),
                MCPTool(name: "set_starred", description: "Stars or unstars conversations.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."},"starred":{"type":"boolean"}},"required":["ids","starred"],"additionalProperties":false}"#),
                MCPTool(name: "snooze", description: "Hides conversations from the inbox until a time (ISO 8601), when they come back.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."},"until":{"type":"string","description":"ISO 8601 date and time"}},"required":["ids","until"],"additionalProperties":false}"#),
                MCPTool(name: "unsnooze", description: "Brings snoozed conversations back to the inbox now.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."}},"required":["ids"],"additionalProperties":false}"#),
                MCPTool(name: "move_to_folder", description: "Moves conversations to one of their mailbox's folders, by name (see list_folders).",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."},"folder":{"type":"string"}},"required":["ids","folder"],"additionalProperties":false}"#),
                MCPTool(name: "add_label", description: "Adds a label (one or two words) to conversations. To sort mail so it shows on Home, use sort_into_group instead. Prefer names from list_labels.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."},"label":{"type":"string"}},"required":["ids","label"],"additionalProperties":false}"#),
                MCPTool(name: "remove_label", description: "Takes a label off conversations.",
                        inputSchema: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":100,"description":"Conversation ids from search_mail or get_selection."},"label":{"type":"string"}},"required":["ids","label"],"additionalProperties":false}"#),
                MCPTool(name: "rename_label", description: "Renames a label on every conversation that has it.",
                        inputSchema: #"{"type":"object","properties":{"label":{"type":"string"},"new_name":{"type":"string"}},"required":["label","new_name"],"additionalProperties":false}"#),
                MCPTool(name: "delete_label", description: "Removes a label from every conversation. The mail itself is untouched.",
                        inputSchema: #"{"type":"object","properties":{"label":{"type":"string"}},"required":["label"],"additionalProperties":false}"#),
            ]
        }
        tools += DraftTools.tools(allowChanges: settings.allowChanges)
        tools += GroupTools.tools(allowChanges: settings.allowChanges)
        if settings.allowChanges { tools += AgentTools.changing() }
        if settings.allowSettings { tools += AgentTools.settings() }
        if settings.allowSending {
            tools += AgentTools.sending()
            tools.append(MCPTool(
                name: "send_email",
                description: "Sends an email right away, or at send_at. Only use this when the person explicitly asked to send.",
                inputSchema: #"""
                {"type":"object","properties":{
                  "to":{"type":"string"},"cc":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"},
                  "reply_to_id":{"type":"string"},"from":{"type":"string","description":"A mailbox name or address, or one of its send-as addresses; defaults to the first."},
                  "template_id":{"type":"string","description":"A template from list_templates to start from."},
                  "attachments":{"type":"array","maxItems":10,"items":{"type":"object","properties":{"filename":{"type":"string"},"content_base64":{"type":"string"},"mime_type":{"type":"string"}},"required":["filename","content_base64"]}},
                  "send_at":{"type":"string","description":"ISO 8601; schedules the message instead of sending now. It goes out with Undo Send and the mailbox's signature like any other."}},
                 "required":["to"],"additionalProperties":false}
                """#
            ))
        }
        return tools
    }

    /// Pictures in attachments go back as pictures, with any words in them as text.
    func content(_ name: String, arguments: [String: MCPValue]) async throws -> [MCPContent] {
        if name == "read_attachment", await tools().contains(where: { $0.name == name }),
           let picture = try await model.attachmentPicture(arguments) {
            return [.image(picture.data, mimeType: picture.mimeType), .text(picture.words.isEmpty ? "A picture with no text in it." : "Text in the picture:\n" + picture.words)]
        }
        return [.text(try await call(name, arguments: arguments))]
    }

    func call(_ name: String, arguments: [String: MCPValue]) async throws -> String {
        let allowed = await tools().contains { $0.name == name }
        guard allowed else { throw MCPToolError("“\(name)” isn't available. The person can allow it in Margin's settings.") }
        return try await model.runTool(name, arguments)
    }
}

extension MailModel {
    func runTool(_ name: String, _ arguments: [String: MCPValue]) async throws -> String {
        if let answer = try await runDraftTool(name, arguments) { return answer }
        if let answer = try await runGroupTool(name, arguments) { return answer }
        switch name {
        case "list_mailboxes":
            return json(visibleAccounts.map { ["name": $0.label, "address": $0.address.address, "unread": unreadCount(account: $0.id)] })
        case "list_folders":
            return json(visibleAccounts.map { account in
                ["mailbox": account.label, "folders": folders(of: account.id).filter { $0.role != .junk && $0.role != .trash }.map(\.name)] as [String: Any]
            })
        case "snooze":
            let threads = try await toolThreads(arguments)
            guard let text = arguments["until"]?.string, let date = ISO8601DateFormatter().date(from: text) ?? Self.looseDate(text), date > Date() else {
                throw MCPToolError("“until” must be a future ISO 8601 date and time.")
            }
            recordSnoozes()
            for thread in threads { snoozes[LabelStore.key(for: thread)] = date }
            saveSnoozes()
            return "Snoozed \(Self.count(threads)) until \(date.formatted())."
        case "unsnooze":
            let threads = try await toolThreads(arguments)
            recordSnoozes()
            for thread in threads { snoozes[LabelStore.key(for: thread)] = nil }
            saveSnoozes()
            return "Brought back \(Self.count(threads))."
        case "move_to_folder":
            let threads = try await toolThreads(arguments)
            guard let name = arguments["folder"]?.string?.lowercased() else { throw MCPToolError("A folder is needed.") }
            var moved: [String] = []
            for thread in threads {
                guard let mailbox = folders(of: thread.accountID ?? UUID()).first(where: { $0.name.lowercased() == name && $0.role != .junk && $0.role != .trash }) else {
                    throw MCPToolError("No folder “\(name)” in \(account(thread.accountID)?.label ?? "this mailbox"). Use list_folders.")
                }
                recordMoves([thread], .move(toMailboxID: mailbox.id))
                await apply(.move(toMailboxID: mailbox.id), to: [thread], announce: false)
                moved.append(mailbox.name)
            }
            await flushPendingChange()
            return "Moved \(Self.count(threads)) to \(moved.first ?? name)."
        case "search_mail":
            let page = try await toolSearch(arguments)
            var result: [String: Any] = ["conversations": page.threads.map(summaryJSON), "total": page.total]
            if let next = page.next { result["next_offset"] = next }
            return json(result)
        case "read_conversation":
            let thread = try await toolThread(arguments["id"]?.string)
            await loadAllBodies(of: thread)
            return json(conversationJSON(thread))
        case "create_draft":
            try openDraft(arguments)
            return "A new message is open in Margin for the person to review and send."
        case "list_labels":
            return json(labelCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { ["label": $0.key, "conversations": $0.value] as [String: Any] })
        case "get_selection":
            let ids = selection.isEmpty ? Set([selectedThreadID].compactMap { $0 }) : selection
            let threads = (visibleThreads + folder + inboxThreads(nil)).reduce(into: [MailThread]()) { found, thread in
                if ids.contains(thread.id), isVisible(thread), !found.contains(where: { $0.id == thread.id }) { found.append(thread) }
            }
            return json(threads.map(summaryJSON))
        case "archive":
            let threads = try await toolThreads(arguments)
            recordMoves(threads, .done)
            await apply(.done, to: threads, announce: false)
            await flushPendingChange()
            return "Archived \(Self.count(threads))."
        case "set_read":
            let threads = try await toolThreads(arguments)
            recordFlags(threads, read: arguments["read"]?.bool ?? true, starred: nil)
            await apply(arguments["read"]?.bool == false ? .markUnread : .markRead, to: threads, announce: false)
            return "Done."
        case "set_starred":
            let threads = try await toolThreads(arguments)
            recordFlags(threads, read: nil, starred: arguments["starred"]?.bool ?? true)
            await apply(arguments["starred"]?.bool == false ? .unstar : .star, to: threads, announce: false)
            return "Done."
        case "add_label":
            let threads = try await toolThreads(arguments)
            let label = try Self.labelName(arguments["label"]?.string)
            // Reuse the existing spelling of a label, so "invoices" lands on "Invoices".
            let name = allLabels.first { $0.caseInsensitiveCompare(label) == .orderedSame } ?? label
            recordLabels()
            for thread in threads { addLabel(name, to: thread) }
            return "Labelled \(Self.count(threads)) “\(name)”."
        case "remove_label":
            let threads = try await toolThreads(arguments)
            let label = try Self.labelName(arguments["label"]?.string)
            recordLabels()
            for thread in threads { removeLabel(label, from: thread) }
            return "Removed “\(label)” from \(Self.count(threads))."
        case "rename_label":
            let label = try Self.labelName(arguments["label"]?.string)
            let newName = try Self.labelName(arguments["new_name"]?.string)
            recordLabels()
            let changed = renameLabel(label, to: newName)
            guard changed > 0 else { throw MCPToolError("No conversation has the label “\(label)”. Use list_labels.") }
            return "Renamed “\(label)” to “\(newName)” on \(Self.count(changed))."
        case "delete_label":
            let label = try Self.labelName(arguments["label"]?.string)
            recordLabels()
            let changed = deleteLabel(label)
            guard changed > 0 else { throw MCPToolError("No conversation has the label “\(label)”. Use list_labels.") }
            return "Removed “\(label)” from \(Self.count(changed))."
        case "send_email":
            let state = try composeState(arguments)
            if let text = arguments["send_at"]?.string {
                guard let date = ISO8601DateFormatter().date(from: text) ?? Self.looseDate(text), date > Date() else {
                    throw MCPToolError("“send_at” must be a future ISO 8601 date and time.")
                }
                schedule(state, at: date, isReply: arguments["reply_to_id"]?.string != nil)
                return "Scheduled for \(date.formatted()). It's in list_outbox."
            }
            guard await send(state) else { throw MCPToolError(notice?.text ?? "Sending failed.") }
            return "Sent from \(state.draft.from.address)."
        default:
            if let result = try await runAgentTool(name, arguments) { return result }
            throw MCPToolError("Unknown tool \(name).")
        }
    }

    // MARK: Finding mail

    private func toolSearch(_ arguments: [String: MCPValue]) async throws -> (threads: [MailThread], total: Int, next: Int?) {
        let limit = min(max(arguments["limit"]?.int ?? 20, 1), 100)
        let offset = max(arguments["offset"]?.int ?? 0, 0)
        let scope = arguments["mailbox"]?.string.flatMap(matchAccount)
        if arguments["mailbox"]?.string != nil && scope == nil { throw MCPToolError("No mailbox by that name. Use list_mailboxes.") }
        let role: MailboxRole = switch arguments["folder"]?.string {
        case "sent": .sent
        case "archive": .archive
        case "drafts": .drafts
        default: .inbox
        }
        var threads: [MailThread]
        if role == .inbox {
            threads = inboxThreads(scope?.id)
        } else {
            threads = []
            for account in accounts where scope == nil || account.id == scope?.id {
                guard let mailbox = combinedMailbox(role, of: account.id) else { continue }
                let found = (try? await provider(for: account).threads(in: mailbox, limit: 200)) ?? []
                threads += found.map { Self.tag($0, account: account.id) }
            }
            threads.sort { $0.date > $1.date }
        }
        let query = SearchQuery(arguments["query"]?.string ?? "")
        let matched = threads.filter { isVisible($0) && (query.isEmpty || query.matches($0)) }
        let page = Array(matched.dropFirst(offset).prefix(limit))
        let next = offset + page.count < matched.count ? offset + page.count : nil
        return (page, matched.count, next)
    }

    /// The conversations named in `ids`; every one must be found.
    func toolThreads(_ arguments: [String: MCPValue]) async throws -> [MailThread] {
        guard case .array(let values)? = arguments["ids"] else { throw MCPToolError("“ids” is needed: conversation ids from search_mail or get_selection.") }
        let ids = values.compactMap(\.string)
        guard !ids.isEmpty, ids.count <= 200 else { throw MCPToolError("Give between 1 and 200 conversation ids.") }
        var threads: [MailThread] = []
        for id in ids where !threads.contains(where: { $0.id == id }) { threads.append(try await toolThread(id)) }
        return threads
    }

    static func labelName(_ text: String?) throws -> String {
        let name = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw MCPToolError("A label of 1 to 40 characters is needed.") }
        return name
    }

    static func count(_ threads: [MailThread]) -> String { count(threads.count) }
    static func count(_ number: Int) -> String { number == 1 ? "1 conversation" : "\(number) conversations" }

    func toolThread(_ id: String?) async throws -> MailThread {
        guard let id, !id.isEmpty else { throw MCPToolError("A conversation id is needed.") }
        if let thread = (inboxThreads(nil) + folder + visibleThreads).first(where: { $0.id == id }), isVisible(thread) { return thread }
        throw MCPToolError("No conversation with that id is loaded. Find it with search_mail first.")
    }

    func matchAccount(_ text: String) -> MailAccount? {
        let lower = text.lowercased()
        return visibleAccounts.first { $0.label.lowercased() == lower || $0.address.address.lowercased() == lower }
    }

    /// Mailboxes AI apps may see.
    var visibleAccounts: [MailAccount] {
        accounts.filter { !connectionSettings.hiddenAccounts.contains($0.id) }
    }

    func isVisible(_ thread: MailThread) -> Bool {
        thread.accountID.map { !connectionSettings.hiddenAccounts.contains($0) } ?? true
    }

    static func looseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter.date(from: text)
    }

    public func loadAllBodies(of thread: MailThread) async {
        guard let account = account(thread.accountID), let provider = try? provider(for: account) else { return }
        for message in thread.messages {
            let key = Self.bodyKey(thread.accountID, message.id)
            guard bodies[key] == nil else { continue }
            if let body = message.body { bodies[key] = body } else if let body = try? await provider.body(of: message) { bodies[key] = body }
        }
    }

    // MARK: Writing

    func composeState(_ arguments: [String: MCPValue]) throws -> ComposeState {
        var state: ComposeState
        if let id = arguments["reply_to_id"]?.string, let thread = (inboxThreads(nil) + folder).first(where: { $0.id == id }),
           let account = account(thread.accountID) {
            state = ComposeState(account: account, draft: Draft.reply(to: thread, from: account.address))
        } else {
            state = ComposeState(account: currentAccount)
        }
        // From a mailbox, or one of its send-as addresses.
        if let from = arguments["from"]?.string {
            let wanted = from.lowercased()
            if let account = matchAccount(from) {
                state.send(from: account)
            } else if let account = visibleAccounts.first(where: { $0.sendAddresses.contains { $0.address.lowercased() == wanted } }),
                      let address = account.sendAddresses.first(where: { $0.address.lowercased() == wanted }) {
                state.send(from: account, as: address)
            } else {
                throw MCPToolError("“\(from)” isn't one of the person's mailboxes or send-as addresses.")
            }
        }
        if let to = arguments["to"]?.string { state.to = to }
        if let cc = arguments["cc"]?.string { state.cc = cc; state.showsCc = !cc.isEmpty }
        if let id = arguments["template_id"]?.string {
            guard let template = templates.first(where: { $0.id.uuidString == id }) else { throw MCPToolError("No template with that id. Use list_templates.") }
            insert(template, into: &state)
        }
        if let subject = arguments["subject"]?.string { state.draft.subject = subject }
        if let body = arguments["body"]?.string { state.draft.text = body }
        if case .array(let files)? = arguments["attachments"] {
            var total = 0
            for file in files {
                guard case .object(let fields) = file, let name = fields["filename"]?.string, !name.isEmpty,
                      let encoded = fields["content_base64"]?.string, let data = Data(base64Encoded: encoded) else {
                    throw MCPToolError("Each attachment needs a filename and content_base64.")
                }
                total += data.count
                guard total <= 20_000_000 else { throw MCPToolError("Attachments can be 20 MB in all.") }
                state.draft.attachments.append(OutgoingAttachment(filename: name, mimeType: fields["mime_type"]?.string ?? "application/octet-stream", data: data))
            }
        }
        guard !state.draft.text.isEmpty || arguments["template_id"] != nil || !state.draft.attachments.isEmpty else {
            throw MCPToolError("A body, a template or an attachment is needed.")
        }
        return state
    }

    private func openDraft(_ arguments: [String: MCPValue]) throws {
        compose = try composeState(arguments)
        #if canImport(AppKit)
        NSApplication.shared.activate()
        #endif
    }

    // MARK: JSON

    func summaryJSON(_ thread: MailThread) -> [String: Any] {
        [
            "id": thread.id,
            "mailbox": account(thread.accountID)?.label ?? "",
            "subject": thread.subject,
            "from": thread.latest.from.headerValue,
            "date": ISO8601DateFormatter().string(from: thread.date),
            "messages": thread.messages.count,
            "unread": thread.isUnread,
            "starred": thread.isStarred,
            "labels": labels(for: thread),
            "preview": thread.latest.snippet,
        ]
    }

    func conversationJSON(_ thread: MailThread) -> [String: Any] {
        var result = summaryJSON(thread)
        result["preview"] = nil
        let code = signInCode(in: thread)
        if let found = invite(in: thread) {
            let invite = found.invite
            result["invitation"] = [
                "title": invite.summary,
                "start": invite.start.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "end": invite.end.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "all_day": invite.isAllDay, "location": invite.location ?? "",
                "organizer": invite.organizer?.headerValue ?? "", "cancelled": invite.isCancelled,
                "answered": rsvps[invite.uid]?.rawValue.lowercased() ?? "",
            ] as [String: Any]
        }
                result["thread"] = thread.messages.map { message -> [String: Any] in
            var text = String((body(of: message, in: thread)?.text ?? message.snippet).prefix(20_000))
            // Sign-in codes never go to AI apps.
            if let code { text = Self.hidingCode(code, in: text) }
            return [
                "from": message.from.headerValue,
                "to": message.to.map(\.headerValue).joined(separator: ", "),
                "cc": message.cc.map(\.headerValue).joined(separator: ", "),
                "date": ISO8601DateFormatter().string(from: message.date),
                "text": text,
                "attachments": (body(of: message, in: thread)?.attachments ?? []).map(\.filename),
            ]
        }
        return result
    }

    /// Replaces the code, including spaced or dashed forms ("482 913"), with a placeholder.
    static func hidingCode(_ code: String, in text: String) -> String {
        let pattern = code.map(String.init).joined(separator: "[ -]?")
        return text.replacingOccurrences(of: pattern, with: "[sign-in code hidden]", options: .regularExpression)
    }

    func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
