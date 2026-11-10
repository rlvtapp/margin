import Foundation
import MailCore

/// Drafting from AI apps: drafts saved in the mailbox's own Drafts folder (so they wait on every
/// device and in other mail apps too), changed or thrown away on request, and the person's
/// writing style, so a draft sounds like them. Margin never sends these; the person does.
enum DraftTools {
    static let empty = #"{"type":"object","properties":{},"additionalProperties":false}"#

    static func tools(allowChanges: Bool) -> [MCPTool] {
        var tools = [
            MCPTool(name: "save_draft",
                    description: "Saves a draft in the mailbox's Drafts folder, where the person reviews and sends it themselves, on any device. Use reply_to_id to answer a conversation. Call get_writing_style first so it sounds like them. The mailbox's signature is added.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "to":{"type":"string"},"cc":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string","description":"Plain text, without a signature."},
                      "reply_to_id":{"type":"string","description":"A conversation id to reply to."},
                      "from":{"type":"string","description":"A mailbox or one of its send-as addresses."}},
                     "required":["body"],"additionalProperties":false}
                    """#),
            MCPTool(name: "list_drafts", description: "Lists the drafts waiting in each mailbox's Drafts folder, newest first, with ids for update_draft.",
                    inputSchema: empty),
            MCPTool(name: "update_draft",
                    description: "Replaces a saved draft with a new version (the old one goes to Trash). Pass only what changes.",
                    inputSchema: #"""
                    {"type":"object","properties":{
                      "id":{"type":"string","description":"A draft id from list_drafts."},
                      "to":{"type":"string"},"cc":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"}},
                     "required":["id"],"additionalProperties":false}
                    """#),
            MCPTool(name: "get_writing_style",
                    description: "How the person writes, learned from their sent mail (greetings, sign-offs, length, tone, per language), plus their own rules for anything written for them. Pass reply_to_id (or to and language) to get the habits for that person in that conversation's language.",
                    inputSchema: #"{"type":"object","properties":{"to":{"type":"string","description":"An address, for how they write to that person."},"language":{"type":"string","description":"An ISO 639-1 code like en or nl; taken from the conversation when reply_to_id is given."},"reply_to_id":{"type":"string","description":"The conversation being answered."},"from":{"type":"string","description":"A mailbox."}},"additionalProperties":false}"#),
        ]
        if allowChanges {
            tools.append(MCPTool(name: "delete_draft", description: "Moves a saved draft to Trash.",
                                 inputSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#))
        }
        return tools
    }
}

extension MailModel {
    /// Answers the drafting tools; nil for any other tool.
    func runDraftTool(_ name: String, _ arguments: [String: MCPValue]) async throws -> String? {
        switch name {
        case "save_draft":
            let state = try composeState(arguments)
            try await saveForReview(state)
            return "Saved in \(account(state.accountID)?.label ?? "the mailbox")’s Drafts for the person to review and send."
        case "list_drafts":
            return json(await draftThreads().map { thread -> [String: Any] in
                var item = summaryJSON(thread)
                item["to"] = thread.latest.to.map(\.headerValue).joined(separator: ", ")
                return item
            })
        case "update_draft":
            let old = try await draftThread(arguments["id"]?.string)
            guard let account = account(old.accountID) else { throw MCPToolError("That draft's mailbox isn't available.") }
            await loadAllBodies(of: old)
            let message = old.latest
            var draft = Draft(from: message.from, to: message.to, cc: message.cc, subject: message.subject,
                              text: body(of: message, in: old)?.text ?? message.snippet)
            draft.inReplyTo = message.inReplyTo
            draft.references = message.references
            var state = ComposeState(account: account, draft: draft)
            state.to = arguments["to"]?.string ?? message.to.map(\.headerValue).joined(separator: ", ")
            state.cc = arguments["cc"]?.string ?? message.cc.map(\.headerValue).joined(separator: ", ")
            if let subject = arguments["subject"]?.string { state.draft.subject = subject }
            if let body = arguments["body"]?.string { state.draft.text = withSignature(body, of: account, isReply: message.inReplyTo != nil) }
            state.editedDraft = old
            try await saveForReview(state, signed: true)
            return "Updated the draft."
        case "delete_draft":
            let old = try await draftThread(arguments["id"]?.string)
            await apply(.trash, to: [old], announce: false)
            await flushPendingChange()
            return "Moved the draft to Trash."
        case "get_writing_style":
            var account = arguments["from"]?.string.flatMap(matchAccount) ?? currentAccount
            var recipient = arguments["to"]?.string.flatMap { EmailAddress.parseList($0)?.first }
            var language = arguments["language"]?.string?.lowercased()
            if let id = arguments["reply_to_id"]?.string {
                let thread = try await toolThread(id)
                await loadAllBodies(of: thread)
                if let owner = self.account(thread.accountID) { account = owner }
                recipient = recipient ?? thread.messages.last { !isMine($0) }?.from
                language = language ?? languageOf(thread)
            }
            return writingStyle(for: recipient, account: account, language: language)
                ?? "Nothing learned yet. Write plainly and briefly, and match the language of the conversation."
        default:
            return nil
        }
    }

    /// Saves a draft to the mailbox's Drafts folder, replacing the one it was made from.
    private func saveForReview(_ state: ComposeState, signed: Bool = false) async throws {
        guard let account = account(state.accountID) else { throw MCPToolError("No mailbox to save the draft in.") }
        var draft = state.draft
        if !signed {
            draft.text = withSignature(inYourStyle(draft.text, language: WritingProfile.language(of: draft.text)), of: account,
                                       isReply: draft.inReplyTo != nil)
        }
        draft.to = EmailAddress.parseList(state.to) ?? []
        draft.cc = EmailAddress.parseList(state.cc) ?? []
        do {
            try await provider(for: account).saveDraft(draft)
        } catch {
            throw MCPToolError("Couldn't save the draft: \(error.localizedDescription)")
        }
        if let old = state.editedDraft {
            await apply(.trash, to: [old], announce: false)
            await flushPendingChange()
        }
        notice = Notice(text: String(localized: "Draft saved by an AI app"))
    }

    /// The text with the mailbox's signature after it, unless it's already there.
    private func withSignature(_ text: String, of account: MailAccount, isReply: Bool) -> String {
        guard let signature = account.signatureText(forReply: isReply)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signature.isEmpty, !text.contains(signature) else { return text }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + signature
    }

    /// Every mailbox's drafts, newest first.
    func draftThreads() async -> [MailThread] {
        var found: [MailThread] = []
        for account in visibleAccounts {
            guard let drafts = combinedMailbox(.drafts, of: account.id), let provider = try? provider(for: account),
                  let threads = try? await provider.threads(in: drafts, limit: 50) else { continue }
            found += threads.map { Self.tag($0, account: account.id) }
        }
        return found.sorted { $0.date > $1.date }
    }

    private func draftThread(_ id: String?) async throws -> MailThread {
        guard let id, !id.isEmpty else { throw MCPToolError("A draft id is needed. Use list_drafts.") }
        guard let thread = await draftThreads().first(where: { $0.id == id }) else { throw MCPToolError("No draft with that id. Use list_drafts.") }
        return thread
    }
}
